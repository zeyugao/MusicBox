import AVFoundation
import AppKit
import Foundation
import Observation

enum PlaybackPhase: String, Codable {
    case idle
    case preparing
    case paused
    case playing
    case failed
}

struct PlaybackState {
    var phase: PlaybackPhase = .idle
    var currentEntry: PlaybackQueueEntry?
    var visibleEntries: [PlaybackQueueEntry] = []
    var sourceCount = 0
    var upcomingCount = 0
    var mode: PlaybackMode = .repeatAll
    var position: Double = 0
    var duration: Double = 0
    var volume: Float = 1
    var bufferingProgress: Double?
    var errorMessage: String?
    var isSeeking = false

    var currentItem: PlaylistItem? { currentEntry?.item }
    var isPlaying: Bool { phase == .playing }
    var isLoading: Bool { phase == .preparing }
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }
}

struct PlaybackSessionSnapshot: Codable, Equatable {
    let queue: PlaybackQueueSnapshot
    let position: Double
    let volume: Float
}

enum PlaybackEndReason {
    case finished
    case stopped
    case switched
    case failed

    var dawnValue: String {
        switch self {
        case .finished, .stopped: return "playend"
        case .switched: return "ui"
        case .failed: return "exception"
        }
    }
}

enum PlaybackEvent {
    case queueChanged(PlaybackQueueSnapshot)
    case modeChanged(PlaybackMode)
    case itemChanged(PlaylistItem?)
    case playbackChanged(isPlaying: Bool)
    case positionChanged(position: Double, duration: Double)
    case didStart(PlaylistItem)
    case didEnd(item: PlaylistItem?, position: Double, reason: PlaybackEndReason)
    case failed(PlaylistItem?, message: String)
}

enum PlaybackEngineEvent {
    case ready(duration: Double)
    case position(position: Double, duration: Double)
    case playbackChanged(Bool)
    case buffering(Double?)
    case ended
    case failed(String)
}

@MainActor
protocol PlaybackEngineControlling: AnyObject {
    var volume: Float { get set }
    var onEvent: ((PlaybackEngineEvent, Int) -> Void)? { get set }
    func load(source: ResolvedAudioSource, generation: Int, position: Double, autoplay: Bool)
    func play()
    func pause()
    func seek(to seconds: Double, completion: @escaping () -> Void)
    func stop()
}

@MainActor
private final class AVPlaybackEngine: NSObject, PlaybackEngineControlling, @preconcurrency CachingPlayerItemDelegate {
    var onEvent: ((PlaybackEngineEvent, Int) -> Void)?

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    private let player = AVPlayer()
    private var activeGeneration = 0
    private var timeObserver: Any?
    private var rateObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var activeCachingItem: CachingPlayerItem?
    private var pendingAutoplay = false

    override init() {
        super.init()
        player.automaticallyWaitsToMinimizeStalling = false
        rateObservation = player.observe(\.rate, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onEvent?(.playbackChanged(player.rate > 0), self.activeGeneration)
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 1_000),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem != nil else { return }
                let itemDuration = self.player.currentItem?.duration.seconds ?? 0
                let duration = itemDuration.isFinite && itemDuration > 0 ? itemDuration : 0
                self.onEvent?(.position(position: max(0, time.seconds), duration: duration), self.activeGeneration)
            }
        }
    }

    func load(source: ResolvedAudioSource, generation: Int, position: Double, autoplay: Bool) {
        detachCurrentItem()
        activeGeneration = generation
        pendingAutoplay = autoplay

        let item: AVPlayerItem
        switch source {
        case .local(let url):
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            item = AVPlayerItem(asset: asset)
        case let .remote(url, cacheURL, fileExtension):
            let cachingItem = CachingPlayerItem(
                url: url,
                saveFilePath: cacheURL.path,
                customFileExtension: fileExtension
            )
            cachingItem.delegate = self
            activeCachingItem = cachingItem
            item = cachingItem
        }

        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            Task { @MainActor [weak self] in
                guard let self, generation == self.activeGeneration else { return }
                switch observedItem.status {
                case .readyToPlay:
                    let duration = observedItem.duration.seconds
                    self.onEvent?(.ready(duration: duration.isFinite ? max(0, duration) : 0), generation)
                    if position > 0 {
                        self.seek(to: position) { [weak self] in
                            guard let self, generation == self.activeGeneration, self.pendingAutoplay else { return }
                            self.player.play()
                        }
                    } else if self.pendingAutoplay {
                        self.player.play()
                    }
                case .failed:
                    self.onEvent?(.failed(observedItem.error?.localizedDescription ?? String(localized: "playback.failed")), generation)
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onEvent?(.ended, self.activeGeneration)
            }
        }
        player.replaceCurrentItem(with: item)
    }

    func play() {
        pendingAutoplay = true
        guard player.currentItem != nil else { return }
        player.play()
    }

    func pause() {
        pendingAutoplay = false
        player.pause()
    }

    func seek(to seconds: Double, completion: @escaping () -> Void) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 1_000)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            Task { @MainActor in completion() }
        }
    }

    func stop() {
        pendingAutoplay = false
        player.pause()
        detachCurrentItem()
        player.replaceCurrentItem(with: nil)
    }

    func playerItemReadyToPlay(_ playerItem: CachingPlayerItem) {
        guard playerItem === activeCachingItem else { return }
        onEvent?(.buffering(nil), activeGeneration)
    }

    func playerItem(_ playerItem: CachingPlayerItem, didDownloadBytesSoFar bytesDownloaded: Int, outOf bytesExpected: Int) {
        guard playerItem === activeCachingItem, bytesExpected > 0 else { return }
        onEvent?(.buffering(Double(bytesDownloaded) / Double(bytesExpected)), activeGeneration)
    }

    func playerItem(_ playerItem: CachingPlayerItem, downloadingFailedWith error: Error) {
        guard playerItem === activeCachingItem else { return }
        onEvent?(.failed(error.localizedDescription), activeGeneration)
    }

    func playerItemDidFailToPlay(_ playerItem: CachingPlayerItem, withError error: Error?) {
        guard playerItem === activeCachingItem else { return }
        onEvent?(.failed(error?.localizedDescription ?? String(localized: "playback.failed")), activeGeneration)
    }

    private func detachCurrentItem() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        itemObservation?.invalidate()
        itemObservation = nil
        activeCachingItem?.delegate = nil
        activeCachingItem = nil
    }

}

@MainActor
@Observable
final class PlaybackStore {
    static let sessionKey = "PlaybackSession.v2"
    private let resolver: AudioSourceResolver
    private let engine: any PlaybackEngineControlling
    private let defaults: UserDefaults
    private var generation = 0
    private var wantsPlayback = false
    private var loadTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    private var eventListeners: [UUID: (PlaybackEvent) -> Void] = [:]
    private var terminationObserver: NSObjectProtocol?

    private(set) var queue = PlaybackQueue()
    private(set) var state = PlaybackState()
    let lyrics: LyricsController

    convenience init() {
        self.init(repository: NeteaseMusicRepository())
    }

    init(repository: any MusicRepository, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        resolver = AudioSourceResolver(repository: repository)
        lyrics = LyricsController(repository: repository)
        let engine = AVPlaybackEngine()
        self.engine = engine
        engine.onEvent = { [weak self] event, generation in
            self?.receive(event, generation: generation)
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.saveSession() }
        }
    }

    init(
        resolver: AudioSourceResolver,
        lyrics: LyricsController,
        engine: some PlaybackEngineControlling,
        defaults: UserDefaults = .standard
    ) {
        self.resolver = resolver
        self.lyrics = lyrics
        self.engine = engine
        self.defaults = defaults
        engine.onEvent = { [weak self] event, generation in
            self?.receive(event, generation: generation)
        }
    }

    var currentItem: PlaylistItem? { state.currentItem }

    @discardableResult
    func addEventListener(_ listener: @escaping (PlaybackEvent) -> Void) -> UUID {
        let token = UUID()
        eventListeners[token] = listener
        return token
    }

    func removeEventListener(_ token: UUID) {
        eventListeners.removeValue(forKey: token)
    }

    func restore() {
        if let data = defaults.data(forKey: Self.sessionKey),
            let snapshot = try? JSONDecoder().decode(PlaybackSessionSnapshot.self, from: data)
        {
            queue = PlaybackQueue(snapshot: snapshot.queue)
            engine.volume = snapshot.volume
            refreshState(position: snapshot.position, volume: snapshot.volume)
            if let entry = queue.current {
                load(entry, autoplay: false, position: snapshot.position, reportPrevious: false)
            }
            return
        }
        migrateLegacySession()
    }

    func play() {
        guard state.currentEntry != nil else { return }
        wantsPlayback = true
        engine.play()
    }

    func pause() {
        wantsPlayback = false
        engine.pause()
    }

    func toggle() {
        state.isPlaying ? pause() : play()
    }

    func seek(to seconds: Double) {
        guard state.currentEntry != nil else { return }
        state.isSeeking = true
        state.position = max(0, min(seconds, state.duration > 0 ? state.duration : seconds))
        lyrics.synchronize(at: state.position)
        engine.seek(to: state.position) { [weak self] in
            guard let self else { return }
            self.state.isSeeking = false
            self.emit(.positionChanged(position: self.state.position, duration: self.state.duration))
            self.schedulePersistence()
        }
    }

    func next() {
        guard let entry = queue.next(isNaturalCompletion: false) else {
            clearQueue()
            return
        }
        refreshQueue()
        load(entry, autoplay: true)
    }

    func previous() {
        guard let entry = queue.previous() else { return }
        refreshQueue()
        load(entry, autoplay: true)
    }

    func replaceSource(
        _ items: [PlaylistItem],
        startIndex: Int = 0,
        autoplay: Bool = true,
        startPosition: Double = 0,
        mode: PlaybackMode? = nil
    ) {
        let entry = queue.replaceSource(items, startIndex: startIndex, mode: mode)
        refreshQueue()
        guard let entry else {
            stopPlayback(reason: .stopped)
            return
        }
        load(entry, autoplay: autoplay, position: startPosition)
    }

    func appendSource(_ items: [PlaylistItem]) {
        queue.appendToSource(items)
        refreshQueue()
    }

    func playNow(_ item: PlaylistItem) {
        let entry: PlaybackQueueEntry
        if let sourceEntry = queue.source.first(where: { $0.item == item }) {
            entry = sourceEntry
        } else {
            queue.appendToSource([item])
            guard let appended = queue.source.last else { return }
            entry = appended
        }
        guard let target = queue.playNow(entry) else { return }
        refreshQueue()
        load(target, autoplay: true)
    }

    func play(entryID: UUID) {
        guard let entry = queue.playEntry(id: entryID) else { return }
        refreshQueue()
        load(entry, autoplay: true)
    }

    func enqueueNext(_ items: [PlaylistItem]) {
        _ = queue.enqueueNext(items)
        refreshQueue()
    }

    func enqueueNext(_ item: PlaylistItem) {
        enqueueNext([item])
    }

    func removeEntry(_ id: UUID) {
        let wasCurrent = queue.current?.id == id
        let nextEntry = queue.removeEntry(id: id)
        refreshQueue()
        if wasCurrent {
            if let nextEntry {
                load(nextEntry, autoplay: true)
            } else {
                stopPlayback(reason: .stopped)
            }
        }
    }

    func clearQueue() {
        queue.clear()
        stopPlayback(reason: .stopped)
        refreshQueue()
    }

    func cycleMode() {
        let mode = queue.cycleMode()
        refreshQueue()
        emit(.modeChanged(mode))
    }

    func setVolume(_ value: Float) {
        let volume = min(max(value, 0), 1)
        engine.volume = volume
        state.volume = volume
        schedulePersistence()
    }

    func stopPlayback(reason: PlaybackEndReason) {
        loadTask?.cancel()
        generation += 1
        wantsPlayback = false
        let item = state.currentItem
        let position = state.position
        engine.stop()
        lyrics.clear()
        state.phase = .idle
        state.position = 0
        state.duration = 0
        state.bufferingProgress = nil
        state.isSeeking = false
        emit(.didEnd(item: item, position: position, reason: reason))
        emit(.playbackChanged(isPlaying: false))
        schedulePersistence()
    }

    private func load(
        _ entry: PlaybackQueueEntry,
        autoplay: Bool,
        position: Double = 0,
        reportPrevious: Bool = true
    ) {
        let prior = state.currentItem
        let priorPosition = state.position
        loadTask?.cancel()
        generation += 1
        wantsPlayback = autoplay
        let requestGeneration = generation
        state.phase = .preparing
        state.currentEntry = entry
        state.position = max(0, position)
        state.duration = max(0, entry.item.duration.seconds)
        state.errorMessage = nil
        state.bufferingProgress = 0
        state.isSeeking = false
        lyrics.load(for: entry.item.id)
        if reportPrevious, let prior, prior != entry.item {
            emit(.didEnd(item: prior, position: priorPosition, reason: .switched))
        }
        emit(.itemChanged(entry.item))
        emit(.positionChanged(position: state.position, duration: state.duration))
        schedulePersistence()

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let source = try await self.resolver.resolve(entry.item)
                guard !Task.isCancelled, requestGeneration == self.generation else { return }
                self.engine.load(
                    source: source,
                    generation: requestGeneration,
                    position: position,
                    autoplay: self.wantsPlayback
                )
            } catch {
                guard !Task.isCancelled, requestGeneration == self.generation else { return }
                self.failCurrentItem(error.localizedDescription)
            }
        }
    }

    private func receive(_ event: PlaybackEngineEvent, generation: Int) {
        guard generation == self.generation else { return }
        switch event {
        case .ready(let duration):
            state.duration = duration > 0 ? duration : state.duration
            state.bufferingProgress = nil
            state.phase = state.isPlaying ? .playing : .paused
            lyrics.synchronize(at: state.position)
        case let .position(position, duration):
            guard !state.isSeeking else { return }
            state.position = max(0, position)
            if duration > 0 { state.duration = duration }
            lyrics.synchronize(at: state.position)
            emit(.positionChanged(position: state.position, duration: state.duration))
            schedulePersistence()
        case .playbackChanged(let isPlaying):
            guard state.currentEntry != nil else { return }
            let changed = state.isPlaying != isPlaying
            state.phase = isPlaying ? .playing : .paused
            if isPlaying {
                lyrics.startSynchronizing { [weak self] in self?.state.position ?? 0 }
            } else {
                lyrics.stopSynchronizing()
            }
            if changed {
                emit(.playbackChanged(isPlaying: isPlaying))
                if isPlaying, let item = state.currentItem { emit(.didStart(item)) }
            }
        case .buffering(let progress):
            state.bufferingProgress = progress
        case .ended:
            let endedItem = state.currentItem
            let endedPosition = state.duration
            emit(.didEnd(item: endedItem, position: endedPosition, reason: .finished))
            guard let nextEntry = queue.next(isNaturalCompletion: true) else {
                state.phase = .paused
                return
            }
            refreshQueue()
            load(nextEntry, autoplay: true, reportPrevious: false)
        case .failed(let message):
            failCurrentItem(message)
        }
    }

    private func failCurrentItem(_ message: String) {
        state.phase = .failed
        state.errorMessage = message
        state.bufferingProgress = nil
        lyrics.stopSynchronizing()
        emit(.failed(state.currentItem, message: message))
        emit(.didEnd(item: state.currentItem, position: state.position, reason: .failed))
        schedulePersistence()
    }

    private func refreshQueue() {
        state.currentEntry = queue.current
        state.visibleEntries = queue.visibleEntries
        state.sourceCount = queue.source.count
        state.upcomingCount = queue.upcomingCount
        state.mode = queue.mode
        emit(.queueChanged(queue.snapshot))
        schedulePersistence()
    }

    private func refreshState(position: Double, volume: Float) {
        state.currentEntry = queue.current
        state.visibleEntries = queue.visibleEntries
        state.sourceCount = queue.source.count
        state.upcomingCount = queue.upcomingCount
        state.mode = queue.mode
        state.position = max(0, position)
        state.duration = queue.currentItem?.duration.seconds ?? 0
        state.volume = volume
        state.phase = queue.current == nil ? .idle : .paused
    }

    private func emit(_ event: PlaybackEvent) {
        for listener in eventListeners.values {
            listener(event)
        }
    }

    private func schedulePersistence() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveSession()
        }
    }

    func saveSession() {
        let snapshot = PlaybackSessionSnapshot(
            queue: queue.snapshot,
            position: state.position,
            volume: state.volume
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.sessionKey)
    }

    private func migrateLegacySession() {
        struct LegacyQueue: Codable {
            let playlist: [PlaylistItem]
            let currentItemIndex: Int?
            let loopMode: LegacyLoopMode
            let playNextItemsCount: Int?
        }
        struct LegacyProgress: Codable {
            let playedSecond: Double
            let volume: Float
        }
        enum LegacyLoopMode: Codable {
            case once
            case shuffle
            case sequence
        }

        let progress = defaults.data(forKey: "PlayStatus")
            .flatMap { try? JSONDecoder().decode(LegacyProgress.self, from: $0) }
        guard let data = defaults.data(forKey: "PlaylistStatus"),
            let legacy = try? JSONDecoder().decode(LegacyQueue.self, from: data)
        else {
            if let progress {
                engine.volume = progress.volume
                state.volume = progress.volume
            }
            return
        }

        let oldItems = legacy.playlist
        let oldIndex = max(0, min(legacy.currentItemIndex ?? 0, max(oldItems.count - 1, 0)))
        let playNextCount = max(0, legacy.playNextItemsCount ?? 0)
        let nextRangeStart = min(oldIndex + 1, oldItems.count)
        let nextRangeEnd = min(nextRangeStart + playNextCount, oldItems.count)
        let explicitNext = Array(oldItems[nextRangeStart..<nextRangeEnd])
        var source = oldItems
        if nextRangeStart < nextRangeEnd {
            source.removeSubrange(nextRangeStart..<nextRangeEnd)
        }
        let sourceIndex = source.firstIndex(where: { $0.id == oldItems[safe: oldIndex]?.id }) ?? 0
        let mode: PlaybackMode
        switch legacy.loopMode {
        case .sequence: mode = .repeatAll
        case .shuffle: mode = .shuffle
        case .once: mode = .repeatOne
        }
        _ = queue.replaceSource(source, startIndex: sourceIndex, mode: mode)
        _ = queue.enqueueNext(explicitNext)
        let position = progress?.playedSecond ?? 0
        let volume = progress?.volume ?? 1
        engine.volume = volume
        refreshState(position: position, volume: volume)
        saveSession()
        if let entry = queue.current {
            load(entry, autoplay: false, position: position, reportPrevious: false)
        }
    }

}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
