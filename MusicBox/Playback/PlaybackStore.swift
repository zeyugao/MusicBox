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

struct PlaybackTimeline {
    static let sampleCorrectionDuration: TimeInterval = 0.18
    static let hardSampleCorrectionThreshold: Double = 0.25

    private var anchorPosition: Double = 0
    private var anchorUptime: TimeInterval = 0
    private(set) var duration: Double = 0
    private var isAdvancing = false
    private var sampleCorrection: Double = 0
    private var sampleCorrectionStartUptime: TimeInterval = 0

    mutating func reset(position: Double, duration: Double, isAdvancing: Bool, at uptime: TimeInterval) {
        self.duration = Self.normalizedDuration(duration)
        anchorPosition = Self.boundedPosition(position, duration: self.duration)
        anchorUptime = uptime
        self.isAdvancing = isAdvancing
        sampleCorrection = 0
        sampleCorrectionStartUptime = uptime
    }

    @discardableResult
    mutating func applySample(position: Double, duration: Double, at uptime: TimeInterval) -> Double {
        let normalizedDuration = Self.normalizedDuration(duration)
        let predictedPosition = Self.boundedPosition(self.position(at: uptime), duration: normalizedDuration)
        let sampledPosition = Self.boundedPosition(position, duration: normalizedDuration)
        let correction = sampledPosition - predictedPosition

        guard isAdvancing, abs(correction) < Self.hardSampleCorrectionThreshold else {
            reset(position: sampledPosition, duration: normalizedDuration, isAdvancing: isAdvancing, at: uptime)
            return correction
        }

        self.duration = normalizedDuration
        anchorPosition = predictedPosition
        anchorUptime = uptime
        sampleCorrection = correction
        sampleCorrectionStartUptime = uptime
        return correction
    }

    mutating func setAdvancing(_ isAdvancing: Bool, at uptime: TimeInterval) {
        guard self.isAdvancing != isAdvancing else { return }
        if self.isAdvancing {
            anchorPosition = position(at: uptime)
        }
        anchorUptime = uptime
        self.isAdvancing = isAdvancing
        sampleCorrection = 0
        sampleCorrectionStartUptime = uptime
    }

    func position(at uptime: TimeInterval) -> Double {
        guard isAdvancing else { return anchorPosition }
        let elapsed = max(0, uptime - anchorUptime)
        let correctionProgress = min(
            1,
            max(0, (uptime - sampleCorrectionStartUptime) / Self.sampleCorrectionDuration)
        )
        return Self.boundedPosition(
            anchorPosition + elapsed + sampleCorrection * correctionProgress,
            duration: duration
        )
    }

    private static func normalizedDuration(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 0
    }

    private static func boundedPosition(_ value: Double, duration: Double) -> Double {
        let position = value.isFinite ? max(0, value) : 0
        guard duration > 0 else { return position }
        return min(position, duration)
    }
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
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 1_000),
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
        case let .remote(url, cacheURL, fileExtension, _):
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
    private let currentUptime: () -> TimeInterval
    private let persistenceInterval: Duration
    private var generation = 0
    private var wantsPlayback = false
    private var loadTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var persistenceGeneration: UInt64 = 0
    private var sessionDirty = false
    private var eventListeners: [UUID: (PlaybackEvent) -> Void] = [:]
    private var terminationObserver: NSObjectProtocol?
    private var timeline = PlaybackTimeline()

    private(set) var queue = PlaybackQueue()
    private(set) var state = PlaybackState()
    let lyrics: LyricsController

    convenience init() {
        self.init(repository: NeteaseMusicRepository())
    }

    init(
        repository: any MusicRepository,
        defaults: UserDefaults = .standard,
        currentUptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        persistenceInterval: Duration = .seconds(5)
    ) {
        self.defaults = defaults
        self.currentUptime = currentUptime
        self.persistenceInterval = persistenceInterval
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
        lyrics.configurePositionProvider { [weak self] in self?.currentPosition ?? 0 }
    }

    init(
        resolver: AudioSourceResolver,
        lyrics: LyricsController,
        engine: some PlaybackEngineControlling,
        defaults: UserDefaults = .standard,
        currentUptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        persistenceInterval: Duration = .seconds(5)
    ) {
        self.resolver = resolver
        self.lyrics = lyrics
        self.engine = engine
        self.defaults = defaults
        self.currentUptime = currentUptime
        self.persistenceInterval = persistenceInterval
        engine.onEvent = { [weak self] event, generation in
            self?.receive(event, generation: generation)
        }
        lyrics.configurePositionProvider { [weak self] in self?.currentPosition ?? 0 }
    }

    var currentItem: PlaylistItem? { state.currentItem }
    var currentPosition: Double { timeline.position(at: currentUptime()) }

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
        timeline.setAdvancing(false, at: currentUptime())
        refreshTimelineState()
        lyrics.playbackStateDidChange(isPlaying: false)
        persistImmediately()
        engine.pause()
    }

    func toggle() {
        state.isPlaying ? pause() : play()
    }

    func seek(to seconds: Double) {
        guard state.currentEntry != nil else { return }
        let now = currentUptime()
        let target = max(0, min(seconds, state.duration > 0 ? state.duration : seconds))
        state.isSeeking = true
        timeline.reset(position: target, duration: state.duration, isAdvancing: false, at: now)
        refreshTimelineState()
        lyrics.seeked()
        emit(.positionChanged(position: state.position, duration: state.duration))
        persistImmediately()
        engine.seek(to: target) { [weak self] in
            guard let self else { return }
            self.state.isSeeking = false
            let now = self.currentUptime()
            self.timeline.setAdvancing(self.state.isPlaying, at: now)
            self.refreshTimelineState()
            self.lyrics.seeked()
            self.emit(.positionChanged(position: self.state.position, duration: self.state.duration))
            self.persistImmediately()
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
        persistImmediately()
    }

    func stopPlayback(reason: PlaybackEndReason) {
        loadTask?.cancel()
        generation += 1
        wantsPlayback = false
        let item = state.currentItem
        let position = currentPosition
        engine.stop()
        lyrics.clear()
        state.phase = .idle
        timeline.reset(position: 0, duration: 0, isAdvancing: false, at: currentUptime())
        refreshTimelineState()
        state.isSeeking = false
        emit(.didEnd(item: item, position: position, reason: reason))
        emit(.playbackChanged(isPlaying: false))
        stopPeriodicPersistence()
        persistImmediately()
    }

    private func load(
        _ entry: PlaybackQueueEntry,
        autoplay: Bool,
        position: Double = 0,
        reportPrevious: Bool = true
    ) {
        let prior = state.currentItem
        let priorPosition = currentPosition
        loadTask?.cancel()
        stopPeriodicPersistence()
        generation += 1
        wantsPlayback = autoplay
        let requestGeneration = generation
        state.phase = .preparing
        state.currentEntry = entry
        timeline.reset(
            position: position,
            duration: max(0, entry.item.duration.seconds),
            isAdvancing: false,
            at: currentUptime()
        )
        refreshTimelineState()
        state.errorMessage = nil
        state.isSeeking = false
        lyrics.playbackStateDidChange(isPlaying: false)
        lyrics.load(for: entry.item.id)
        if reportPrevious, let prior, prior != entry.item {
            emit(.didEnd(item: prior, position: priorPosition, reason: .switched))
        }
        emit(.itemChanged(entry.item))
        emit(.positionChanged(position: state.position, duration: state.duration))
        persistImmediately()

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
            timeline.applySample(
                position: currentPosition,
                duration: duration > 0 ? duration : state.duration,
                at: currentUptime()
            )
            refreshTimelineState()
            state.phase = state.isPlaying ? .playing : .paused
            lyrics.seeked()
            emit(.positionChanged(position: state.position, duration: state.duration))
        case let .position(position, duration):
            guard !state.isSeeking else { return }
            let correction = timeline.applySample(
                position: position,
                duration: duration > 0 ? duration : state.duration,
                at: currentUptime()
            )
            refreshTimelineState()
            emit(.positionChanged(position: state.position, duration: state.duration))
            lyrics.reconcile(afterTimelineCorrection: correction, at: position)
            markSessionDirty()
        case .playbackChanged(let isPlaying):
            guard state.currentEntry != nil else { return }
            let changed = state.isPlaying != isPlaying
            guard changed else { return }
            timeline.setAdvancing(isPlaying && !state.isSeeking, at: currentUptime())
            refreshTimelineState()
            state.phase = isPlaying ? .playing : .paused
            lyrics.playbackStateDidChange(isPlaying: isPlaying)
            emit(.playbackChanged(isPlaying: isPlaying))
            emit(.positionChanged(position: state.position, duration: state.duration))
            if isPlaying {
                markSessionDirty()
                if let item = state.currentItem { emit(.didStart(item)) }
            } else {
                stopPeriodicPersistence()
                persistImmediately()
            }
        case .ended:
            let endedItem = state.currentItem
            let endedPosition = max(currentPosition, state.duration)
            timeline.reset(position: endedPosition, duration: state.duration, isAdvancing: false, at: currentUptime())
            refreshTimelineState()
            lyrics.playbackStateDidChange(isPlaying: false)
            emit(.didEnd(item: endedItem, position: endedPosition, reason: .finished))
            guard let nextEntry = queue.next(isNaturalCompletion: true) else {
                let wasPlaying = state.isPlaying
                state.phase = .paused
                if wasPlaying { emit(.playbackChanged(isPlaying: false)) }
                stopPeriodicPersistence()
                persistImmediately()
                return
            }
            refreshQueue()
            load(nextEntry, autoplay: true, reportPrevious: false)
        case .failed(let message):
            failCurrentItem(message)
        }
    }

    private func failCurrentItem(_ message: String) {
        let wasPlaying = state.isPlaying
        timeline.setAdvancing(false, at: currentUptime())
        refreshTimelineState()
        state.phase = .failed
        state.errorMessage = message
        lyrics.playbackStateDidChange(isPlaying: false)
        emit(.failed(state.currentItem, message: message))
        emit(.didEnd(item: state.currentItem, position: state.position, reason: .failed))
        if wasPlaying { emit(.playbackChanged(isPlaying: false)) }
        stopPeriodicPersistence()
        persistImmediately()
    }

    private func refreshQueue() {
        state.currentEntry = queue.current
        state.visibleEntries = queue.visibleEntries
        state.sourceCount = queue.source.count
        state.upcomingCount = queue.upcomingCount
        state.mode = queue.mode
        emit(.queueChanged(queue.snapshot))
        persistImmediately()
    }

    private func refreshState(position: Double, volume: Float) {
        state.currentEntry = queue.current
        state.visibleEntries = queue.visibleEntries
        state.sourceCount = queue.source.count
        state.upcomingCount = queue.upcomingCount
        state.mode = queue.mode
        timeline.reset(
            position: position,
            duration: queue.currentItem?.duration.seconds ?? 0,
            isAdvancing: false,
            at: currentUptime()
        )
        refreshTimelineState()
        state.volume = volume
        state.phase = queue.current == nil ? .idle : .paused
    }

    private func emit(_ event: PlaybackEvent) {
        for listener in eventListeners.values {
            listener(event)
        }
    }

    private func refreshTimelineState() {
        state.position = currentPosition
        state.duration = timeline.duration
    }

    private func markSessionDirty() {
        sessionDirty = true
        guard state.isPlaying, persistenceTask == nil else { return }
        persistenceGeneration &+= 1
        let generation = persistenceGeneration
        let interval = persistenceInterval
        persistenceTask = Task { [weak self, interval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled,
                    let self,
                    self.persistenceGeneration == generation
                else { break }
                if self.sessionDirty {
                    self.saveSession()
                    self.sessionDirty = false
                }
                guard self.state.isPlaying else { break }
            }
            if self?.persistenceGeneration == generation {
                self?.persistenceTask = nil
            }
        }
    }

    private func stopPeriodicPersistence() {
        persistenceGeneration &+= 1
        persistenceTask?.cancel()
        persistenceTask = nil
    }

    private func persistImmediately() {
        sessionDirty = false
        saveSession()
    }

    func saveSession() {
        let snapshot = PlaybackSessionSnapshot(
            queue: queue.snapshot,
            position: currentPosition,
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
