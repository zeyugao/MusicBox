//
//  Player.swift
//  MusicBox
//
//  Created by Elsa on 2024/4/18.
//

import AVFoundation
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum LoopMode: Decodable, Encodable {
    case once
    case shuffle
    case sequence
}

class PlaybackProgress: ObservableObject {
    @Published var playedSecond: Double = 0.0
    @Published var duration: Double = 0.0
}

class LyricStatus: ObservableObject {
    @Published var lyricTimeline: [Int] = []  // We align to 0.1s, 12.32 -> 123
    @Published var currentLyricIndex: Int? = nil
    @Published private(set) var scrollResetToken = UUID()

    private var lastSearchIndex: Int = 0  // Cache last search position for performance

    func prepareForNewTrack() async {
        lastSearchIndex = 0
        await MainActor.run {
            self.lyricTimeline = []
            self.currentLyricIndex = nil
            self.scrollResetToken = UUID()
        }
    }

    func loadTimeline(_ timeline: [Int], currentTime: Double) async {
        lastSearchIndex = 0
        await MainActor.run {
            self.lyricTimeline = timeline
            self.currentLyricIndex = self.findLyricIndex(for: currentTime)
            self.scrollResetToken = UUID()
        }
    }

    func resetLyricIndex(currentTime: Double) {
        lastSearchIndex = 0
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.currentLyricIndex = self.findLyricIndex(for: currentTime)
        }
    }

    private func findLyricIndex(for currentTime: Double) -> Int? {
        guard !lyricTimeline.isEmpty else { return nil }

        let roundedPlayedSecond = Int(currentTime * 10)

        // Use binary search for better performance O(log n)
        var left = 0
        var right = lyricTimeline.count - 1
        var result: Int? = nil

        while left <= right {
            let mid = (left + right) / 2

            if lyricTimeline[mid] <= roundedPlayedSecond {
                result = mid
                left = mid + 1
            } else {
                right = mid - 1
            }
        }

        return result
    }

    func updateLyricIndex(currentTime: Double) {
        let initIdx = self.currentLyricIndex
        let newIdx = self.findLyricIndex(for: currentTime)

        if newIdx != initIdx {
            Task { @MainActor [weak self] in
                self?.currentLyricIndex = newIdx
            }
        }
    }

    // Get the time of the next lyric change for smart synchronization
    func getNextLyricChangeTime(currentTime: Double) -> Double? {
        guard !lyricTimeline.isEmpty else { return nil }

        let roundedPlayedSecond = Int(currentTime * 10)

        // Find the next lyric time that is greater than current time
        for timeStamp in lyricTimeline {
            if timeStamp > roundedPlayedSecond {
                return Double(timeStamp) / 10.0
            }
        }

        return nil
    }
}

class SmartLyricSynchronizer: ObservableObject {
    private weak var lyricStatus: LyricStatus?
    fileprivate var preciseTimer: Timer?
    private var getCurrentTime: (() -> Double)?
    private var shouldSynchronize: (() -> Bool)?

    #if DEBUG
        private func debugLog(_ message: String) {
            print("[LyricSync] \(message)")
        }
    #endif

    init(
        lyricStatus: LyricStatus, getCurrentTime: @escaping () -> Double,
        shouldSynchronize: @escaping () -> Bool
    ) {
        self.lyricStatus = lyricStatus
        self.getCurrentTime = getCurrentTime
        self.shouldSynchronize = shouldSynchronize
    }

    func startSynchronization() {
        if !Thread.isMainThread {
            #if DEBUG
                debugLog("startSynchronization: not on main thread, dispatching to main")
            #endif
            DispatchQueue.main.async { [weak self] in
                self?.startSynchronization()
            }
            return
        }

        guard shouldSynchronize?() == true else {
            #if DEBUG
                debugLog("startSynchronization: shouldSynchronize false, skipping")
            #endif
            return
        }

        guard shouldSynchronize?() == true else { return }

        // Immediately update lyric index when starting synchronization
        if let getCurrentTime = getCurrentTime,
            let lyricStatus = lyricStatus
        {
            lyricStatus.updateLyricIndex(currentTime: getCurrentTime())
        }

        #if DEBUG
            debugLog("startSynchronization: scheduling next update")
        #endif
        scheduleNextLyricUpdate()
    }

    func stopSynchronization() {
        preciseTimer?.invalidate()
        preciseTimer = nil
        #if DEBUG
            debugLog("stopSynchronization: timer invalidated")
        #endif
    }

    func updateSynchronizationState() {
        if shouldSynchronize?() == true {
            if preciseTimer == nil {
                #if DEBUG
                    debugLog("updateSynchronizationState: starting (timer nil)")
                #endif
                startSynchronization()
            } else {
                #if DEBUG
                    debugLog("updateSynchronizationState: already running")
                #endif
            }
        } else {
            #if DEBUG
                debugLog("updateSynchronizationState: shouldSynchronize is false, stopping")
            #endif
            stopSynchronization()
        }
    }

    // Force update lyric index immediately (useful when detail view opens)
    func updateLyricIndexNow() {
        if let getCurrentTime = getCurrentTime,
            let lyricStatus = lyricStatus
        {
            #if DEBUG
                debugLog("updateLyricIndexNow: forcing update at time \(getCurrentTime())")
            #endif
            lyricStatus.updateLyricIndex(currentTime: getCurrentTime())
        }
    }

    // Restart synchronization (useful after seeking)
    func restartSynchronization() {
        if !Thread.isMainThread {
            #if DEBUG
                debugLog("restartSynchronization: not on main thread, dispatching to main")
            #endif
            DispatchQueue.main.async { [weak self] in
                self?.restartSynchronization()
            }
            return
        }

        guard shouldSynchronize?() == true else {
            #if DEBUG
                debugLog("restartSynchronization: shouldSynchronize false, abort")
            #endif
            return
        }
        #if DEBUG
            debugLog("restartSynchronization: restarting timer")
        #endif
        stopSynchronization()
        startSynchronization()
    }

    private func scheduleNextLyricUpdate() {
        preciseTimer?.invalidate()

        #if DEBUG
            debugLog("scheduleNextLyricUpdate: entering on main thread? \(Thread.isMainThread)")
        #endif

        if !Thread.isMainThread {
            #if DEBUG
                debugLog("scheduleNextLyricUpdate: not on main thread, dispatching to main")
            #endif
            DispatchQueue.main.async { [weak self] in
                self?.scheduleNextLyricUpdate()
            }
            return
        }

        guard shouldSynchronize?() == true,
            let getCurrentTime = getCurrentTime,
            let lyricStatus = lyricStatus
        else {
            #if DEBUG
                debugLog("scheduleNextLyricUpdate: guard failed (shouldSynchronize=\(shouldSynchronize?() ?? false))")
            #endif
            return
        }

        let currentTime = getCurrentTime()

        if let nextChangeTime = lyricStatus.getNextLyricChangeTime(currentTime: currentTime) {
            let timeInterval = max(nextChangeTime - currentTime, 0.01)  // Minimum 10ms

            if timeInterval > 0 && timeInterval < 10.0 {  // Only schedule if within reasonable range
                #if DEBUG
                    debugLog("scheduleNextLyricUpdate: scheduling precise timer in \(timeInterval)s")
                #endif
                preciseTimer = Timer.scheduledTimer(withTimeInterval: timeInterval, repeats: false)
                { [weak self] _ in
                    self?.performLyricUpdate()
                }
            } else if timeInterval >= 10.0 {
                #if DEBUG
                    debugLog("scheduleNextLyricUpdate: long interval (\(timeInterval)s), scheduling 5s check")
                #endif
                // For long intervals, schedule a check every 5 seconds to maintain synchronization
                preciseTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) {
                    [weak self] _ in
                        self?.performLyricUpdate()
                }
            }
        } else {
            #if DEBUG
                debugLog("scheduleNextLyricUpdate: no next change, scheduling 1s fallback")
            #endif
            // No next lyric change found, schedule a regular check after 1 second
            preciseTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) {
                [weak self] _ in
                    self?.performLyricUpdate()
            }
        }
    }

    private func performLyricUpdate() {
        guard shouldSynchronize?() == true,
            let getCurrentTime = getCurrentTime,
            let lyricStatus = lyricStatus
        else { return }

        #if DEBUG
            let time = getCurrentTime()
            debugLog("performLyricUpdate: updating index for time \(time), mainThread=\(Thread.isMainThread)")
        #endif
        lyricStatus.updateLyricIndex(currentTime: getCurrentTime())

        // Schedule the next update
        scheduleNextLyricUpdate()
    }

    deinit {
        stopSynchronization()
    }
}

class PlayStatus: ObservableObject {
    private var player = AVPlayer()

    var playbackProgress = PlaybackProgress()
    var lyricStatus = LyricStatus()
    private var lyricSynchronizer: SmartLyricSynchronizer?
    private weak var playingDetailModel: PlayingDetailModel?
    private var detailModelCancellable: AnyCancellable?

    @Published var isLoading: Bool = false
    @Published var loadingProgress: Double? = nil
    @Published var readyToPlay: Bool = true
    @Published var isLoadingNewTrack: Bool = false

    var currentItem: PlaylistItem? = nil
    private var pendingItem: PlaylistItem? = nil
    private var trackRetryCounts: [UInt64: Int] = [:]
    private let maxRetryAttemptsPerTrack = 1

    enum PlayerState: Int {
        case unknown = 0
        case playing = 1
        case paused = 2
        case stopped = 3
        case interrupted = 4
    }

    @Published var playerState: PlayerState = .stopped

    struct Storage: Codable {
        let playedSecond: Double
        let volume: Float
    }

    func togglePlayPause() async {
        if playerState != .playing {
            await startPlay()
        } else {
            pausePlay()
        }
    }

    func nextTrack() {
        PlaylistStatus.controlPlaylist(command: .nextTrack)
    }

    func pausePlay() {
        player.pause()
        Task { @MainActor in
            self.playerState = .paused
        }
        updateCurrentPlaybackInfo()
        NowPlayingCenter.handleSetPlaybackState(playing: false)

        // Stop smart lyric synchronization
        #if DEBUG
            print("[LyricSync] pausePlay: stopping synchronization")
        #endif
        lyricSynchronizer?.stopSynchronization()

        // Notify about playback state change
        NotificationCenter.default.post(
            name: .playbackStateChanged,
            object: nil,
            userInfo: ["isPlaying": false]
        )
    }

    func startPlay() async {
        if player.currentItem == nil {
            nextTrack()
            return
        }
        player.play()
        await MainActor.run {
            self.playerState = .playing
        }
        updateCurrentPlaybackInfo()
        NowPlayingCenter.handleSetPlaybackState(playing: true)

        // Update smart lyric synchronization state and force immediate lyric index update
        #if DEBUG
            print("[LyricSync] startPlay: updating synchronization state")
        #endif
        lyricSynchronizer?.updateSynchronizationState()
        lyricSynchronizer?.updateLyricIndexNow()

        // Notify about playback state change
        NotificationCenter.default.post(
            name: .playbackStateChanged,
            object: nil,
            userInfo: ["isPlaying": true]
        )
    }

    var volume: Float {
        get {
            player.volume
        }
        set {
            player.volume = newValue
        }
    }

    func restartLyricSynchronization() {
        lyricSynchronizer?.restartSynchronization()
    }

    private var inSeeking: Bool = false
    private var switchingItem: Bool = false
    private var seekingTask: Task<Void, Never>?
    @Published var isSeeking: Bool = false

    func seekToOffset(offset newTime: CMTime) async {
        guard loadingProgress == nil else {
            return
        }

        seekingTask?.cancel()
        seekingTask = Task {
            await MainActor.run {
                self.isSeeking = true
                playbackProgress.playedSecond = newTime.seconds
            }

            if let item = self.currentItem, player.currentItem is CachingPlayerItem {
                if inSeeking {
                    return
                }
                inSeeking = true
                defer { inSeeking = false }

                await seekToItem(item: item, playedSecond: newTime.seconds)
                await startPlay()
                return
            }

            await player.seek(to: newTime, toleranceBefore: .zero, toleranceAfter: .zero)
            await MainActor.run {
                self.lyricStatus.updateLyricIndex(currentTime: newTime.seconds)
            }
            updateCurrentPlaybackInfo()

            // Restart lyric synchronization after seeking
            if playerState == .playing {
                try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1 seconds
                // Small delay to ensure player state is stable
                await MainActor.run {
                    self.lyricSynchronizer?.restartSynchronization()
                }
            }
            await MainActor.run {
                self.isSeeking = false
            }
        }
        await seekingTask?.value
    }

    private let timeScale = CMTimeScale(NSEC_PER_SEC)

    func seekToOffset(offset: Double) async {
        // 取消之前的 seek 任务，但允许新的 seek 操作
        seekingTask?.cancel()

        let newTime = CMTime(seconds: offset, preferredTimescale: timeScale)
        await seekToOffset(offset: newTime)
    }

    @MainActor
    func updateDuration(duration: Double) {
        self.playbackProgress.duration = duration
    }

    func seekByOffset(offset: Double) async {
        let currentTime = player.currentTime()
        let newTime = CMTimeAdd(currentTime, CMTime(seconds: offset, preferredTimescale: timeScale))
        await seekToOffset(offset: newTime)
    }

    func replaceCurrentItem(item: AVPlayerItem?) {
        deinitPlayerObservers()

        // Clear delegate of previous caching player item to break retain cycles
        if let currentItem = player.currentItem as? CachingPlayerItem {
            currentItem.delegate = nil
        }

        // Save current volume before replacing player
        let currentVolume = player.volume

        player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false

        // Restore volume after creating new player
        player.volume = currentVolume

        initPlayerObservers()
    }

    func seekToItem(item: PlaylistItem, playedSecond: Double?) async {
        if switchingItem {
            return
        }
        switchingItem = true
        defer {
            switchingItem = false
        }

        if currentItem?.id != item.id && pendingItem?.id != item.id {
            trackRetryCounts[item.id] = 0
        }

        await MainActor.run {
            self.isLoadingNewTrack = true
            self.pendingItem = item
            self.currentItem = item
        }

        await lyricStatus.prepareForNewTrack()

        await MainActor.run {
            self.playbackProgress.playedSecond = playedSecond ?? 0.0
        }

        await updateDuration(duration: item.duration.seconds)

        let playerItem: AVPlayerItem
        if let url = await item.getLocalUrl() {
            print("local url: \(url)")
            let asset = AVURLAsset(
                url: url,
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            setLoadingProgress(nil)
            playerItem = AVPlayerItem(asset: asset)
        } else if let url = await item.getUrl(),
            let savePath = item.getPotentialLocalUrl(),
            let ext = item.ext
        {
            print("remote url: \(url)")
            await MainActor.run {
                self.readyToPlay = false
            }
            assert(playedSecond == nil || playedSecond == 0.0)
            let cacheItem = await CachingPlayerItem(
                url: url, saveFilePath: savePath.path, customFileExtension: ext)
            setLoadingProgress(0.0)
            await MainActor.run {
                cacheItem.passOnObject = item
                cacheItem.delegate = self
            }
            playerItem = cacheItem
        } else {
            return
        }

        replaceCurrentItem(item: playerItem)

        if let playedSecond = playedSecond, playedSecond > 0 {
            await seekToOffset(offset: playedSecond)
        }

        #if DEBUG
            print("[LyricSync] seekToItem: playerState=\(playerState), readyToPlay=\(readyToPlay)")
        #endif
        // Restart lyric synchronization for new track if currently playing
        if playerState == .playing {
            lyricSynchronizer?.restartSynchronization()
        }

        await MainActor.run {
            if self.pendingItem?.id == item.id {
                self.isLoadingNewTrack = false
                self.pendingItem = nil
            }
        }
    }

    private var scrobbled: Bool = false

    private var scrobbleTask: Task<Void, Never>?

    private func doScrobble() {
        if !scrobbled && readyToPlay {
            if playbackProgress.playedSecond > 30 {
                scrobbleTask?.cancel()
                scrobbleTask = Task { [weak self] in
                    guard let self = self else { return }
                    print("do scrobble")
                    if let item = self.currentItem, let song = item.nsSong {
                        await CloudMusicApi().scrobble(
                            song: song,
                            playedTime: Int(self.playbackProgress.playedSecond)
                        )
                    }
                    await MainActor.run {
                        self.scrobbled = true
                    }
                }
            }
        }
    }

    private func setLoadingProgress(_ progress: Double?) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.loadingProgress = progress
            if (progress != nil) != self.isLoading {
                self.isLoading = progress != nil
            }
        }
    }

    func updateCurrentPlaybackInfo() {
        NowPlayingCenter.handlePlaybackChange(
            playing: player.timeControlStatus == .playing, rate: player.rate,
            position: self.playbackProgress.playedSecond,
            duration: playbackProgress.duration)
    }

    func nowPlayingInit() {
        updateCurrentPlaybackInfo()
        NowPlayingCenter.handleSetPlaybackState(playing: false)
    }

    var periodicTimeObserverToken: Any?
    var playerStateObserver: NSKeyValueObservation?
    var timeControlStatus: AVPlayer.TimeControlStatus = .waitingToPlayAtSpecifiedRate
    var timeControlStautsObserver: NSKeyValueObservation?

    func initPlayerObservers() {
        timeControlStautsObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) {
            [weak self] (player, changes) in
            guard let self = self else { return }
            self.timeControlStatus = player.timeControlStatus
        }

        playerStateObserver = player.observe(\.rate, options: [.initial, .new]) {
            [weak self] (player, _) in
            guard let self = self else { return }
            guard player.status == .readyToPlay else { return }

            let isPlaying = !player.rate.isZero
            Task { @MainActor in
                let oldState = self.playerState
                self.playerState = isPlaying ? .playing : .paused

                // Only send notification if state actually changed
                if (oldState == .playing) != isPlaying {
                    NotificationCenter.default.post(
                        name: .playbackStateChanged,
                        object: nil,
                        userInfo: ["isPlaying": isPlaying]
                    )

                    // Update lyric synchronization when playback state changes
                    if isPlaying {
                        #if DEBUG
                            print("[LyricSync] player rate > 0: updating synchronization state")
                        #endif
                        self.lyricSynchronizer?.updateSynchronizationState()
                    } else {
                        #if DEBUG
                            print("[LyricSync] player rate == 0: stopping synchronization")
                        #endif
                        self.lyricSynchronizer?.stopSynchronization()
                    }
                }
            }
        }

        periodicTimeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: timeScale), queue: .main
        ) { [weak self] time in
            guard let self = self else { return }
            // 在切换项目、未准备好播放或正在 seeking 时不更新播放进度
            if !self.switchingItem && self.readyToPlay && !self.isSeeking {
                let newTime = self.player.currentTime().seconds
                if Int(self.playbackProgress.playedSecond) != Int(newTime) {
                    Task { @MainActor in
                        self.playbackProgress.playedSecond = newTime
                    }
                    self.updateCurrentPlaybackInfo()
                }
            }
        }
    }

    func deinitPlayerObservers() {
        if let timeObserverToken = periodicTimeObserverToken {
            player.removeTimeObserver(timeObserverToken)
            periodicTimeObserverToken = nil
            Task { @MainActor [weak self] in
                self?.playbackProgress.playedSecond = 0
            }
        }
        playerStateObserver?.invalidate()
        playerStateObserver = nil
        timeControlStautsObserver?.invalidate()
        timeControlStautsObserver = nil
    }

    static let controllPlayerNotificationName = Notification.Name("PlayStatus.controll")
    private var controlPlayerObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?

    enum PlayerControlCommand: Int {
        case togglePlayPause, startPlay, pausePlay, seekByOffset, seekToOffset
        case switchItem
    }

    static func controlPlayer(command: PlayerControlCommand, argument: Any? = nil) {
        NotificationCenter.default.post(
            name: controllPlayerNotificationName,
            object: nil,
            userInfo: ["command": command, "argument": argument as Any]
        )
    }

    func initNotificationObservers() {
        let notificationCenter = NotificationCenter.default

        controlPlayerObserver = notificationCenter.addObserver(
            forName: PlayStatus.controllPlayerNotificationName, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self = self, let userInfo = notification.userInfo else { return }
            Task {
                if let command = userInfo["command"] as? PlayerControlCommand {
                    switch command {
                    case .togglePlayPause:
                        await self.togglePlayPause()
                    case .startPlay:
                        await self.startPlay()
                    case .pausePlay:
                        self.pausePlay()
                    case .seekByOffset:
                        if let offset = userInfo["argument"] as? Double {
                            await self.seekByOffset(offset: offset)
                        }
                    case .seekToOffset:
                        if let offset = userInfo["argument"] as? Double {
                            await self.seekToOffset(offset: offset)
                        }
                    case .switchItem:
                        if let argument = userInfo["argument"] as? [String: Any] {
                            if let item = argument["item"] as? PlaylistItem {
                                // Cancel any existing seek task
                                self.seekingTask?.cancel()

                                let shouldPlay = argument["shouldPlay"] as? Bool ?? false
                                let playedSecond = argument["playedSecond"] as? Double
                                await self.seekToItem(item: item, playedSecond: playedSecond)

                                if shouldPlay {
                                    await self.startPlay()
                                }
                            }
                        } else {
                            // Clear loading state when stopping
                            Task { @MainActor [weak self] in
                                self?.currentItem = nil
                                self?.playbackProgress.duration = 0.0
                                self?.playbackProgress.playedSecond = 0.0
                                self?.playerState = .stopped
                                self?.isLoadingNewTrack = false
                                self?.pendingItem = nil

                                // Notify about playback state change
                                NotificationCenter.default.post(
                                    name: .playbackStateChanged,
                                    object: nil,
                                    userInfo: ["isPlaying": false]
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    func deinitNotificationObservers() {
        let notificationCenter = NotificationCenter.default
        if let ob = controlPlayerObserver {
            notificationCenter.removeObserver(ob)
            controlPlayerObserver = nil
        }
        if let ob = terminationObserver {
            notificationCenter.removeObserver(ob)
            terminationObserver = nil
        }
    }

    func loadState() async {
        if let data = UserDefaults.standard.data(forKey: "PlayStatus") {
            do {
                let status = try JSONDecoder().decode(Storage.self, from: data)

                // 如果有要恢复的播放进度且当前有播放项目
                if status.playedSecond > 0 {
                    var waitIterations = 0
                    while currentItem == nil && pendingItem == nil && waitIterations < 10 {
                        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
                        waitIterations += 1
                    }

                    let item = currentItem ?? pendingItem
                    guard let item else {
                        volume = status.volume
                        return
                    }

                    // 等待当前的切换操作完成
                    while switchingItem {
                        try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1 秒
                    }

                    // 如果播放器已经有了当前项目，直接 seek；否则重新加载
                    if player.currentItem != nil {
                        await seekToOffset(offset: status.playedSecond)
                    } else {
                        await seekToItem(item: item, playedSecond: status.playedSecond)
                    }
                }

                volume = status.volume
            } catch {
                print("Failed to load PlayStatus: \(error)")
            }
        }
    }

    func saveState() {
        do {
            let storage = Storage(playedSecond: playbackProgress.playedSecond, volume: volume)
            let data = try JSONEncoder().encode(storage)
            UserDefaults.standard.set(data, forKey: "PlayStatus")
        } catch {
            print("Failed to save PlayStatus")
        }
    }

    init() {
        initPlayerObservers()
        initNotificationObservers()

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.saveState()
        }
    }

    func setPlayingDetailModel(_ playingDetailModel: PlayingDetailModel) {
        self.playingDetailModel = playingDetailModel

        // Initialize lyric synchronizer with detail model dependency
        lyricSynchronizer = SmartLyricSynchronizer(
            lyricStatus: lyricStatus,
            getCurrentTime: { [weak self] in
                return self?.player.currentTime().seconds ?? 0.0
            },
            shouldSynchronize: { [weak playingDetailModel] in
                return playingDetailModel?.isPresented == true
            }
        )

        // Listen to playingDetailModel changes to update synchronization state
        detailModelCancellable = playingDetailModel.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                // Small delay to ensure isPresented has been updated
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                    #if DEBUG
                        print("[LyricSync] detail model changed: isPresented=\(playingDetailModel.isPresented), timer running? \(self?.lyricSynchronizer?.preciseTimer != nil)")
                    #endif
                    let wasRunning = self?.lyricSynchronizer?.preciseTimer != nil
                    self?.lyricSynchronizer?.updateSynchronizationState()

                    // If detail view just opened and we weren't running before, force start
                    if playingDetailModel.isPresented && !wasRunning {
                        self?.lyricSynchronizer?.updateLyricIndexNow()
                        // Force start synchronization if we're currently playing
                        if self?.playerState == .playing {
                            self?.lyricSynchronizer?.startSynchronization()
                        }
                    }
                }
            }
        }
    }

    deinit {
        deinitPlayerObservers()
        deinitNotificationObservers()

        // Stop lyric synchronization
        lyricSynchronizer?.stopSynchronization()
        lyricSynchronizer = nil

        // Cancel Combine subscriptions
        detailModelCancellable?.cancel()
        detailModelCancellable = nil

        // Cancel any pending tasks to prevent memory leaks
        seekingTask?.cancel()
        scrobbleTask?.cancel()

        // Clear delegate of current caching player item to break retain cycles
        if let currentItem = player.currentItem as? CachingPlayerItem {
            currentItem.delegate = nil
        }

        // Ensure player is stopped and cleaned up
        player.pause()
        player.replaceCurrentItem(with: nil)

        saveState()
    }
}

extension PlayStatus: CachingPlayerItemDelegate {
    func playerItemReadyToPlay(_ playerItem: CachingPlayerItem) {
        if let track = playerItem.passOnObject as? PlaylistItem {
            trackRetryCounts[track.id] = 0
        }
        Task { @MainActor [weak self] in
            self?.readyToPlay = true
            self?.isLoadingNewTrack = false
            self?.pendingItem = nil
        }
        print("Caching player item ready to play.")
    }

    func playerItemDidFailToPlay(_ playerItem: CachingPlayerItem, withError error: Error?) {
        let track = (playerItem.passOnObject as? PlaylistItem) ?? currentItem ?? pendingItem
        let trackDescription: String
        if let track {
            trackDescription = "\"\(track.title)\" by \(track.artist) (id: \(track.id))"
        } else {
            trackDescription = "Unknown track"
        }
        let errorDescription = error?.localizedDescription ?? "No reason"
        let shouldPurgeCache = isLikelyCorruptedMedia(error)
        var actionNote = ""
        var scheduledRetry = false

        if shouldPurgeCache, let track {
            let retryCount = trackRetryCounts[track.id, default: 0]
            if retryCount < maxRetryAttemptsPerTrack {
                trackRetryCounts[track.id] = retryCount + 1
                if removeCachedFile(for: track) {
                    print("Removed cached file for track \(track.id), attempting re-download.")
                    Task { [weak self] in
                        await self?.seekToItem(item: track, playedSecond: nil)
                        await self?.startPlay()
                    }
                    actionNote = " (cleared cache, retrying)"
                    scheduledRetry = true
                } else {
                    print("No cached file removed for track \(track.id); will not retry.")
                    actionNote = " (cache missing, skipping retry)"
                }
            } else {
                print("Retry limit reached for track \(track.id); will not retry.")
                actionNote = " (retry limit reached)"
            }
        }

        let message = "playerItemDidFailToPlay: \(trackDescription) -> \(errorDescription)\(actionNote)"
        print(message)
        AlertModal.showAlert(message)

        if scheduledRetry {
            return
        }

        // Clear loading state on failure
        Task { @MainActor [weak self] in
            self?.isLoadingNewTrack = false
            self?.pendingItem = nil
        }

        self.nextTrack()
    }

    private func isLikelyCorruptedMedia(_ error: Error?) -> Bool {
        guard let nsError = error as NSError? else { return false }

        if let reason = nsError.localizedFailureReason,
            reason.lowercased().contains("media may be damaged")
        {
            return true
        }

        if nsError.domain == AVFoundationErrorDomain,
            nsError.code == -11829  // AVError.cannotOpen
        {
            return true
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
            underlying.domain == NSOSStatusErrorDomain, underlying.code == -12848
        {
            return true
        }

        return false
    }

    private func removeCachedFile(for track: PlaylistItem) -> Bool {
        let fileManager = FileManager.default
        let candidatePaths: [URL] = [
            track.getPotentialLocalUrl(),
            getCachedMusicFile(id: track.id),
        ].compactMap { $0 }

        for path in candidatePaths {
            if fileManager.fileExists(atPath: path.path) {
                do {
                    try fileManager.removeItem(at: path)
                    return true
                } catch {
                    print("Failed to remove cached file for track \(track.id) at \(path.path): \(error)")
                }
            }
        }

        return false
    }

    func playerItemPlaybackStalled(_ playerItem: CachingPlayerItem) {
        print("Caching player item stalled.")
    }

    func playerItem(
        _ playerItem: CachingPlayerItem, didDownloadBytesSoFar bytesDownloaded: Int,
        outOf bytesExpected: Int
    ) {
        if loadingProgress != nil {
            setLoadingProgress(Double(bytesDownloaded) / Double(bytesExpected))
        }
    }

    func playerItem(_ playerItem: CachingPlayerItem, didFinishDownloadingFileAt filePath: String) {
        setLoadingProgress(nil)
        print("Caching player item file downloaded.")
    }

    func playerItem(_ playerItem: CachingPlayerItem, downloadingFailedWith error: Error) {
        setLoadingProgress(nil)
        let message =
            "Caching player item file download failed with error: \(error.localizedDescription)."
        print(message)
        AlertModal.showAlert(message)

        // Clear loading state on failure
        Task { @MainActor [weak self] in
            self?.isLoadingNewTrack = false
            self?.pendingItem = nil
        }

        nextTrack()
    }
}

actor PlaylistMutationCoordinator {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ operation: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            isLocked = false
        }
    }
}

class PlaylistStatus: ObservableObject, RemoteCommandHandler {
    private let savedCurrentPlaylistKey = "CurrentPlaylist"
    private let savedCurrentPlayingItemIndexKey = "CurrentPlayingItemIndex"

    struct Storage: Codable {
        let playlist: [PlaylistItem]
        let currentItemIndex: Int?
        let loopMode: LoopMode
        let playNextItemsCount: Int
    }

    private let mutationCoordinator = PlaylistMutationCoordinator()

    @Published var loopMode: LoopMode = .sequence
    private var switchingItem: Bool = false

    // MARK: - Shuffle State

    /// A pre-generated playback timeline used when `loopMode == .shuffle`.
    /// `shuffleSequenceIndex` points to the currently playing item inside this timeline.
    private var shuffleSequence: [UInt64] = []
    private var shuffleSequenceIndex: Int? = nil

    /// Keep the upcoming shuffle timeline "long" so next/previous behave deterministically.
    private let shufflePrefetchCycles: Int = 3

    @Published var playlist: [PlaylistItem] = []
    @Published var playNextItemsCount: Int = 0
    @Published var currentItemIndex: Int? = nil
    var currentItem: PlaylistItem? {
        if let currentItemIndex = currentItemIndex {
            if currentItemIndex < 0 || currentItemIndex >= playlist.count {
                print(
                    "Current item index out of bounds: \(currentItemIndex), playlist count: \(playlist.count)"
                )
                return nil
            }

            return playlist[currentItemIndex]
        }
        return nil
    }

    private func withPlaylistLock<T>(_ operation: () async throws -> T) async rethrows -> T {
        try await mutationCoordinator.withLock(operation)
    }

    // MARK: - Shuffle Helpers

    private func resetShuffleState() {
        shuffleSequence.removeAll(keepingCapacity: true)
        shuffleSequenceIndex = nil
    }

    private func fisherYatesShuffled<T, R: RandomNumberGenerator>(_ items: [T], using rng: inout R)
        -> [T]
    {
        guard items.count > 1 else { return items }
        var result = items
        for i in stride(from: result.count - 1, through: 1, by: -1) {
            let j = Int.random(in: 0...i, using: &rng)
            if i != j {
                result.swapAt(i, j)
            }
        }
        return result
    }

    private func makeShuffleCycle(playlistIDs: [UInt64], avoidingFirstBeing avoidID: UInt64?) -> [UInt64]
    {
        guard !playlistIDs.isEmpty else { return [] }

        var rng = SystemRandomNumberGenerator()
        var cycle = fisherYatesShuffled(playlistIDs, using: &rng)

        if let avoidID, cycle.count > 1, cycle.first == avoidID {
            let swapIndex = Int.random(in: 1..<(cycle.count), using: &rng)
            cycle.swapAt(0, swapIndex)
        }

        return cycle
    }

    private func bootstrapShuffleSequenceFromCurrentItem() async {
        await withPlaylistLock {
            let (playlist, currentItemIndex) = await MainActor.run {
                (self.playlist, self.currentItemIndex ?? 0)
            }

            guard !playlist.isEmpty else {
                resetShuffleState()
                return
            }

            let normalizedCurrentIndex = max(0, min(currentItemIndex, playlist.count - 1))
            let currentID = playlist[normalizedCurrentIndex].id
            let playlistIDs = playlist.map(\.id)

            shuffleSequence = [currentID]
            shuffleSequenceIndex = 0

            // Initial cycle: current + shuffled remainder (no immediate repeat).
            let remaining = playlistIDs.filter { $0 != currentID }
            if !remaining.isEmpty {
                var rng = SystemRandomNumberGenerator()
                shuffleSequence.append(contentsOf: fisherYatesShuffled(remaining, using: &rng))
            }

            ensureShufflePrefetched(currentID: currentID, playlistIDs: playlistIDs)
        }
    }

    private func ensureShuffleStateAligned(currentID: UInt64, playlistIDs: [UInt64]) {
        if let idx = shuffleSequenceIndex,
            idx >= 0,
            idx < shuffleSequence.count,
            shuffleSequence[idx] == currentID
        {
            return
        }

        if let idx = shuffleSequence.firstIndex(of: currentID) {
            shuffleSequenceIndex = idx
            return
        }

        // Current item changed externally while in shuffle: rebuild from current item.
        shuffleSequence = [currentID]
        shuffleSequenceIndex = 0

        let remaining = playlistIDs.filter { $0 != currentID }
        if !remaining.isEmpty {
            var rng = SystemRandomNumberGenerator()
            shuffleSequence.append(contentsOf: fisherYatesShuffled(remaining, using: &rng))
        }
    }

    private func ensureShufflePrefetched(currentID: UInt64, playlistIDs: [UInt64]) {
        guard loopMode == .shuffle else { return }
        guard let idx = shuffleSequenceIndex, idx >= 0, idx < shuffleSequence.count else { return }
        guard !playlistIDs.isEmpty else { return }

        let desiredUpcomingCount = max(playlistIDs.count * shufflePrefetchCycles, 1)
        var upcomingCount = shuffleSequence.count - idx - 1

        while upcomingCount < desiredUpcomingCount {
            let avoidID = shuffleSequence.last
            let cycle = makeShuffleCycle(playlistIDs: playlistIDs, avoidingFirstBeing: avoidID)
            guard !cycle.isEmpty else { break }
            shuffleSequence.append(contentsOf: cycle)
            upcomingCount = shuffleSequence.count - idx - 1
        }
    }

    private func applyShuffleOverride(nextID: UInt64, currentID: UInt64, playlistIDs: [UInt64]) {
        guard loopMode == .shuffle else { return }
        guard nextID != currentID else { return }

        ensureShuffleStateAligned(currentID: currentID, playlistIDs: playlistIDs)

        guard let idx = shuffleSequenceIndex, idx >= 0, idx < shuffleSequence.count else { return }

        let nextPos = idx + 1
        if nextPos < shuffleSequence.count, shuffleSequence[nextPos] == nextID {
            shuffleSequenceIndex = nextPos
            return
        }

        if nextPos < shuffleSequence.count {
            shuffleSequence.removeSubrange(nextPos..<shuffleSequence.count)
        }
        shuffleSequence.append(nextID)
        shuffleSequenceIndex = idx + 1

        // After an override (Play Next / manual select), regenerate the remainder of the current shuffle cycle
        // so the just-selected track won't immediately show up again in the next Fisher-Yates permutation.
        let remaining = playlistIDs.filter { $0 != nextID }
        if !remaining.isEmpty {
            var rng = SystemRandomNumberGenerator()
            shuffleSequence.append(contentsOf: fisherYatesShuffled(remaining, using: &rng))
        }

        ensureShufflePrefetched(currentID: nextID, playlistIDs: playlistIDs)
    }

    private func nextShuffleID(playlistIDs: [UInt64]) -> UInt64? {
        guard let idx = shuffleSequenceIndex, idx >= 0, idx < shuffleSequence.count else { return nil }

        let playlistIdSet = Set(playlistIDs)
        var candidate = idx + 1

        while candidate < shuffleSequence.count {
            let candidateID = shuffleSequence[candidate]
            if playlistIdSet.contains(candidateID) {
                shuffleSequenceIndex = candidate
                return candidateID
            }
            candidate += 1
        }

        return nil
    }

    private func previousShuffleID(playlistIDs: [UInt64]) -> UInt64? {
        guard let idx = shuffleSequenceIndex, idx > 0, idx < shuffleSequence.count else { return nil }

        let playlistIdSet = Set(playlistIDs)
        var candidate = idx - 1

        while candidate >= 0 {
            let candidateID = shuffleSequence[candidate]
            if playlistIdSet.contains(candidateID) {
                shuffleSequenceIndex = candidate
                return candidateID
            }
            candidate -= 1
        }

        return nil
    }

    func switchToNextLoopMode() {
        let previousMode = loopMode
        switch loopMode {
        case .once:
            loopMode = .sequence
        case .sequence:
            loopMode = .shuffle
        case .shuffle:
            loopMode = .once
        }

        if previousMode == .shuffle && loopMode != .shuffle {
            Task { [weak self] in
                guard let self else { return }
                await self.withPlaylistLock {
                    self.resetShuffleState()
                }
            }
        } else if previousMode != .shuffle && loopMode == .shuffle {
            Task { [weak self] in
                await self?.bootstrapShuffleSequenceFromCurrentItem()
            }
        }
    }

    func startPlay() {
        PlayStatus.controlPlayer(command: .startPlay)
    }

    func pausePlay() {
        PlayStatus.controlPlayer(command: .pausePlay)
    }

    func performRemoteCommand(_ command: RemoteCommand) {
        Task {
            switch command {
            case .play:
                startPlay()
            case .pause:
                pausePlay()
            case .togglePlayPause:
                PlayStatus.controlPlayer(command: .togglePlayPause)
            case .nextTrack:
                await nextTrack()
            case .previousTrack:
                await previousTrack()
            case .skipForward(let distance):
                PlayStatus.controlPlayer(command: .seekByOffset, argument: distance)
            case .skipBackward(let distance):
                PlayStatus.controlPlayer(command: .seekByOffset, argument: -distance)
            case .changePlaybackPosition(let offset):
                PlayStatus.controlPlayer(command: .seekToOffset, argument: offset)
            }
        }
    }

    func nextTrack() async {
        // doScrobble()

        if loopMode == .once && currentItemIndex == playlist.count - 1 {
            pausePlay()
            await seekToItem(offset: nil)
            return
        }

        await withPlaylistLock {
            let (playlist, currentItemIndex, playNextItemsCount, loopMode) = await MainActor.run {
                (self.playlist, self.currentItemIndex ?? 0, self.playNextItemsCount, self.loopMode)
            }

            guard !playlist.isEmpty else { return }

            if loopMode == .shuffle {
                let playlistIDs = playlist.map(\.id)
                let normalizedCurrentIndex = max(0, min(currentItemIndex, playlist.count - 1))
                let currentID = playlist[normalizedCurrentIndex].id

                if playNextItemsCount > 0 {
                    // Consume play-next items sequentially first, but keep shuffle history consistent.
                    let _ = await consumePlayNextItem()
                    let nextIndex = (normalizedCurrentIndex + 1) % playlist.count
                    let nextID = playlist[nextIndex].id
                    applyShuffleOverride(nextID: nextID, currentID: currentID, playlistIDs: playlistIDs)

                    RemoteCommandCenter.handleRemoteCommands(using: self)
                    await seekToItem(offset: nextIndex, shouldPlay: true, clearPlayNext: false)
                    return
                }

                ensureShuffleStateAligned(currentID: currentID, playlistIDs: playlistIDs)
                ensureShufflePrefetched(currentID: currentID, playlistIDs: playlistIDs)

                guard let nextID = nextShuffleID(playlistIDs: playlistIDs) else {
                    // Fallback: if shuffle state can't produce a next item, behave like sequential next.
                    RemoteCommandCenter.handleRemoteCommands(using: self)
                    await seekByItem(offset: 1, shouldPlay: true, clearPlayNext: false)
                    return
                }

                guard let nextIndex = playlist.firstIndex(where: { $0.id == nextID }) else { return }

                RemoteCommandCenter.handleRemoteCommands(using: self)
                await seekToItem(offset: nextIndex, shouldPlay: true, clearPlayNext: false)
                return
            }

            // Sequential mode - consume play next counter if applicable but don't clear queue
            if playNextItemsCount > 0 {
                let _ = await consumePlayNextItem()
            }

            RemoteCommandCenter.handleRemoteCommands(using: self)
            await seekByItem(offset: 1, shouldPlay: true, clearPlayNext: false)
        }
    }

    func previousTrack() async {
        await withPlaylistLock {
            let (playlist, currentItemIndex, loopMode) = await MainActor.run {
                (self.playlist, self.currentItemIndex ?? 0, self.loopMode)
            }

            guard !playlist.isEmpty else { return }

            if loopMode == .shuffle {
                let playlistIDs = playlist.map(\.id)
                let normalizedCurrentIndex = max(0, min(currentItemIndex, playlist.count - 1))
                let currentID = playlist[normalizedCurrentIndex].id

                ensureShuffleStateAligned(currentID: currentID, playlistIDs: playlistIDs)

                guard let previousID = previousShuffleID(playlistIDs: playlistIDs) else {
                    // No history yet: restart current track.
                    await seekToItem(offset: normalizedCurrentIndex, playedSecond: 0.0, clearPlayNext: true)
                    startPlay()
                    return
                }

                guard let previousIndex = playlist.firstIndex(where: { $0.id == previousID }) else { return }
                await seekToItem(offset: previousIndex, playedSecond: 0.0, clearPlayNext: true)
                startPlay()
                return
            }

            await seekByItem(offset: -1)
            startPlay()
        }
    }

    func seekByItem(offset: Int, shouldPlay: Bool = false, clearPlayNext: Bool = true) async {
        guard playlist.count > 0 else { return }

        let currentItemIndex = currentItemIndex ?? 0
        let newItemIndex = (currentItemIndex + offset + playlist.count) % playlist.count
        await seekToItem(offset: newItemIndex, shouldPlay: shouldPlay, clearPlayNext: clearPlayNext)
    }

    func playBySongId(id: UInt64) async {
        guard let index = playlist.firstIndex(where: { $0.id == id }) else { return }
        if loopMode == .shuffle {
            await withPlaylistLock {
                let (playlist, currentItemIndex) = await MainActor.run {
                    (self.playlist, self.currentItemIndex ?? 0)
                }
                guard !playlist.isEmpty else { return }
                let playlistIDs = playlist.map(\.id)
                let normalizedCurrentIndex = max(0, min(currentItemIndex, playlist.count - 1))
                let currentID = playlist[normalizedCurrentIndex].id
                applyShuffleOverride(nextID: id, currentID: currentID, playlistIDs: playlistIDs)
            }
        }
        await seekToItem(offset: index, shouldPlay: true)
    }

    func deleteBySongId(id: UInt64) async {
        await withPlaylistLock {
            let wasCurrentItem = await MainActor.run { () -> Bool in
                guard let index = playlist.firstIndex(where: { $0.id == id }) else { return false }
                let isCurrentlyPlaying = index == currentItemIndex

                playlist.remove(at: index)

                if let currentItemIndex = currentItemIndex {
                    if index < currentItemIndex {
                        self.currentItemIndex = currentItemIndex - 1
                    } else if index == currentItemIndex {
                        // Don't update currentItemIndex here, handle it below
                    }
                }

                return isCurrentlyPlaying
            }

            if wasCurrentItem {
                // Handle deletion of current playing item
                let playlistIsEmpty = await MainActor.run { playlist.isEmpty }
                if playlistIsEmpty {
                    // No more songs, stop playback
                    await MainActor.run {
                        self.currentItemIndex = nil
                    }
                    pausePlay()
                } else {
                    // Choose next song intelligently
                    let nextIndex = await MainActor.run { () -> Int in
                        guard let oldCurrentIndex = self.currentItemIndex else { return 0 }

                        // If we deleted the last song, go to the previous one
                        if oldCurrentIndex >= playlist.count {
                            return playlist.count - 1
                        }

                        // Otherwise, stay at the same index (which now has the next song)
                        return oldCurrentIndex
                    }

                    // Switch to the next song and continue playing
                    await seekToItem(offset: nextIndex, shouldPlay: true)
                }
            }

            await NowPlayingCenter.handleItemChange(
                item: currentItem,
                index: currentItemIndex ?? 0,
                count: playlist.count)

            saveState()
        }
    }

    func seekToItem(
        offset: Int?, playedSecond: Double? = 0.0, shouldPlay: Bool = false,
        clearPlayNext: Bool = true
    ) async {
        if let offset = offset {
            guard offset < playlist.count else { return }

            let targetItem = playlist[offset]

            await MainActor.run {
                currentItemIndex = offset
                // Clear Play Next queue when manually switching to a different song
                if clearPlayNext {
                    playNextItemsCount = 0
                }
            }

            await NowPlayingCenter.handleItemChange(
                item: currentItem,
                index: currentItemIndex ?? 0,
                count: playlist.count)

            PlayStatus.controlPlayer(
                command: .switchItem,
                argument: [
                    "item": targetItem,
                    "shouldPlay": shouldPlay,
                    "playedSecond": playedSecond!,
                ])

            saveCurrentPlayingItemIndex()
        } else {
            PlayStatus.controlPlayer(command: .switchItem, argument: nil)
        }
    }

    private func findIdIndex(_ id: UInt64) -> Int {
        for (index, item) in playlist.enumerated() {
            if item.id == id {
                return index
            }
        }
        return -1
    }

    func addItemToPlaylist(
        _ item: PlaylistItem, continuePlaying: Bool = true, shouldSaveState: Bool = false
    ) async -> Int {
        await withPlaylistLock {
            await addItemToPlaylistUnlocked(
                item, continuePlaying: continuePlaying, shouldSaveState: shouldSaveState)
        }
    }

    private func addItemToPlaylistUnlocked(
        _ item: PlaylistItem, continuePlaying: Bool = true, shouldSaveState: Bool = false
    ) async -> Int {
        let idIdx = findIdIndex(item.id)
        if idIdx == -1 {
            await MainActor.run {
                playlist.append(item)
                if shouldSaveState {
                    saveState()
                }
            }
            return playlist.count - 1 // Return expected index
        }
        if shouldSaveState {
            await MainActor.run {
                saveState()
            }
        }
        return idIdx
    }

    func replacePlaylist(
        _ items: [PlaylistItem],
        continuePlaying: Bool = true,
        shouldSaveState: Bool = true,
        startIndex: Int? = nil
    ) async {
        await withPlaylistLock {
            await replacePlaylistUnlocked(
                items,
                continuePlaying: continuePlaying,
                shouldSaveState: shouldSaveState,
                startIndex: startIndex
            )
        }
    }

    private func replacePlaylistUnlocked(
        _ items: [PlaylistItem],
        continuePlaying: Bool = true,
        shouldSaveState: Bool = true,
        startIndex: Int? = nil
    ) async {
        resetShuffleState()
        await MainActor.run {
            playlist = items
            playNextItemsCount = 0
        }

        let targetIndex = startIndex ?? 0
        if items.isEmpty {
            await seekToItem(offset: 0, shouldPlay: continuePlaying)
        } else {
            let normalizedIndex = max(0, min(targetIndex, items.count - 1))
            await seekToItem(offset: normalizedIndex, shouldPlay: continuePlaying)
        }

        if shouldSaveState {
            saveState()
        }
    }

    func replacePlaylistStreaming(
        totalCount: Int,
        startIndex: Int,
        continuePlaying: Bool = true,
        shouldSaveState: Bool = true,
        itemStream: AsyncStream<[PlaylistItem]>
    ) async {
        await withPlaylistLock {
            resetShuffleState()
            await MainActor.run {
                playlist = []
                playNextItemsCount = 0
                currentItemIndex = nil
            }

            var accumulatedCount = 0
            var hasStartedPlayback = false

            for await chunk in itemStream {
                guard !chunk.isEmpty else { continue }

                await MainActor.run {
                    playlist.append(contentsOf: chunk)
                }

                let upperBound = accumulatedCount + chunk.count
                if !hasStartedPlayback && startIndex < upperBound {
                    let normalizedIndex = max(0, min(startIndex, playlist.count - 1))
                    await seekToItem(offset: normalizedIndex, shouldPlay: continuePlaying)
                    hasStartedPlayback = true
                }

                accumulatedCount = upperBound

                if accumulatedCount >= totalCount {
                    break
                }
            }

            if !hasStartedPlayback && !playlist.isEmpty {
                let normalizedIndex = max(0, min(startIndex, playlist.count - 1))
                await seekToItem(offset: normalizedIndex, shouldPlay: continuePlaying)
            }

            if shouldSaveState {
                saveState()
            }
        }
    }

    func replaceFromCurrentPosition(
        _ items: [PlaylistItem], continuePlaying: Bool = true, shouldSaveState: Bool = true
    ) async {
        await withPlaylistLock {
            await replaceFromCurrentPositionUnlocked(
                items, continuePlaying: continuePlaying, shouldSaveState: shouldSaveState)
        }
    }

    private func replaceFromCurrentPositionUnlocked(
        _ items: [PlaylistItem], continuePlaying: Bool = true, shouldSaveState: Bool = true
    ) async {
        resetShuffleState()
        await MainActor.run {
            guard let currentIndex = currentItemIndex else {
                playlist = items
                playNextItemsCount = 0
                return
            }

            // Keep items up to current, replace everything after
            let keepItems = Array(playlist[0...currentIndex])
            playlist = keepItems + items
            playNextItemsCount = 0
        }

        if continuePlaying {
            startPlay()
        }
        if shouldSaveState {
            saveState()
        }
    }

    func addItemsToPlaylist(
        _ items: [PlaylistItem], continuePlaying: Bool = true, shouldSaveState: Bool = true
    ) async {
        await withPlaylistLock {
            for item in items {
                let _ = await addItemToPlaylistUnlocked(
                    item, continuePlaying: continuePlaying, shouldSaveState: false)
            }
            if continuePlaying {
                startPlay()
            }
            if shouldSaveState {
                saveState()
            }
        }
    }

    func addItemsToPlayNext(
        _ items: [PlaylistItem], shouldSaveState: Bool = true
    ) async {
        await withPlaylistLock {
            for item in items {
                await MainActor.run {
                    guard let currentIndex = currentItemIndex else {
                        // If no current item, add to beginning
                        playlist.insert(item, at: 0)
                        playNextItemsCount += 1
                        return
                    }

                    // Check if item already exists in playlist
                    if let existingIndex = playlist.firstIndex(where: { $0.id == item.id }) {
                        let wasPlayNextItem =
                            existingIndex > currentIndex
                            && existingIndex <= currentIndex + playNextItemsCount

                        // If it's already in the play next queue, skip it
                        if wasPlayNextItem {
                            return
                        }

                        // Remove from current position
                        playlist.remove(at: existingIndex)

                        // Adjust currentIndex if we removed an item before it
                        let adjustedCurrentIndex =
                            existingIndex < currentIndex ? currentIndex - 1 : currentIndex
                        self.currentItemIndex = adjustedCurrentIndex

                        // Insert at the end of play next queue
                        let insertIndex = adjustedCurrentIndex + playNextItemsCount + 1
                        playlist.insert(item, at: insertIndex)
                        playNextItemsCount += 1
                    } else {
                        // Insert new item at the end of play next queue
                        let insertIndex = currentIndex + playNextItemsCount + 1
                        playlist.insert(item, at: insertIndex)
                        playNextItemsCount += 1
                    }
                }
            }

            if shouldSaveState {
                saveState()
            }
        }
    }

    private func savePlaylist() {
        saveEncodableState(forKey: savedCurrentPlaylistKey, data: playlist)
    }

    private func saveCurrentPlayingItemIndex() {
        UserDefaults.standard.set(currentItemIndex, forKey: savedCurrentPlayingItemIndexKey)
    }

    private func loadCurrentPlayingItemIndex() async {
        if let savedIndex = UserDefaults.standard.object(forKey: savedCurrentPlayingItemIndexKey)
            as? Int
        {
            if savedIndex < 0 || savedIndex >= playlist.count {
                return
            }
            currentItemIndex = savedIndex
            await seekToItem(offset: savedIndex, playedSecond: nil)
        }
    }

    func clearPlaylist() async {
        await withPlaylistLock {
            resetShuffleState()
            await MainActor.run {
                playlist = []
                playNextItemsCount = 0
                currentItemIndex = nil
            }
            saveState()
        }
    }

    // MARK: - Play Next Management

    func addToPlayNext(_ item: PlaylistItem) async {
        await withPlaylistLock {
            await MainActor.run {
                guard let currentIndex = currentItemIndex else {
                    // If no current item, add to beginning
                    playlist.insert(item, at: 0)
                    playNextItemsCount += 1
                    return
                }

                // Check if the item is the currently playing item
                if currentIndex < playlist.count && playlist[currentIndex].id == item.id {
                    return  // Don't add the currently playing item to play next
                }

                // Check if item already exists in playlist
                if let existingIndex = playlist.firstIndex(where: { $0.id == item.id }) {
                    // Check if the existing item is already in the play next queue
                    let isInPlayNextQueue =
                        existingIndex > currentIndex
                        && existingIndex <= currentIndex + playNextItemsCount
                    if isInPlayNextQueue {
                        return  // Item is already in the play next queue, don't move it
                    }

                    // Check if the existing item is already at the end of the play next queue
                    let playNextEndIndex = currentIndex + playNextItemsCount
                    if existingIndex == playNextEndIndex {
                        return  // Already in the right position
                    }

                    // Remove from current position
                    playlist.remove(at: existingIndex)

                    // Adjust currentIndex if we removed an item before it
                    let adjustedCurrentIndex =
                        existingIndex < currentIndex ? currentIndex - 1 : currentIndex
                    self.currentItemIndex = adjustedCurrentIndex

                    // Check if the item was in the play next queue
                    let wasPlayNextItem =
                        existingIndex > currentIndex
                        && existingIndex <= currentIndex + playNextItemsCount

                    // Insert at the end of the play next queue
                    let insertIndex = adjustedCurrentIndex + playNextItemsCount + 1
                    playlist.insert(item, at: insertIndex)

                    // Update playNextItemsCount
                    if !wasPlayNextItem {
                        playNextItemsCount += 1
                    }
                } else {
                    // Insert new item at the end of the play next queue
                    let insertIndex = currentIndex + playNextItemsCount + 1
                    playlist.insert(item, at: insertIndex)
                    playNextItemsCount += 1
                }
            }

            saveState()
        }
    }

    func clearPlayNext() {
        Task { @MainActor in
            guard let currentIndex = currentItemIndex, playNextItemsCount > 0 else { return }

            // Remove play next items that come after current item
            let endIndex = min(currentIndex + playNextItemsCount + 1, playlist.count)
            let range = (currentIndex + 1)..<endIndex
            playlist.removeSubrange(range)
            playNextItemsCount = 0
            saveState()
        }
    }

    @MainActor
    private func consumePlayNextItem() -> Bool {
        guard playNextItemsCount > 0 else { return false }
        playNextItemsCount -= 1
        return true
    }

    func addItemAndSeekTo(_ item: PlaylistItem, shouldPlay: Bool = false) async -> Int {
        let idIdx = await addItemToPlaylist(item, continuePlaying: false)
        await seekToItem(offset: idIdx, shouldPlay: shouldPlay)

        savePlaylist()
        return idIdx
    }

    func saveState() {
        do {
            let storage = Storage(
                playlist: playlist,
                currentItemIndex: currentItemIndex,
                loopMode: loopMode,
                playNextItemsCount: playNextItemsCount
            )
            let data = try JSONEncoder().encode(storage)
            UserDefaults.standard.set(data, forKey: "PlaylistStatus")
        } catch {
            print("Failed to save PlaylistStatus")
        }
    }

    func loadState() async {
        if let data = UserDefaults.standard.data(forKey: "PlaylistStatus") {
            do {
                let storage = try JSONDecoder().decode(Storage.self, from: data)
                await MainActor.run {
                    playlist = storage.playlist
                    currentItemIndex = storage.currentItemIndex
                    loopMode = storage.loopMode
                    playNextItemsCount = storage.playNextItemsCount
                }

                await seekToItem(offset: currentItemIndex)
            } catch {
                print("Failed to load PlaylistStatus: \(error)")
                // Try to load without playNextItemsCount for backward compatibility
                do {
                    struct LegacyStorage: Codable {
                        let playlist: [PlaylistItem]
                        let currentItemIndex: Int?
                        let loopMode: LoopMode
                        let playNextQueue: [PlaylistItem]?
                    }
                    let legacyStorage = try JSONDecoder().decode(LegacyStorage.self, from: data)
                    await MainActor.run {
                        playlist = legacyStorage.playlist
                        currentItemIndex = legacyStorage.currentItemIndex
                        loopMode = legacyStorage.loopMode
                        playNextItemsCount = 0  // Reset for legacy data
                    }
                    await seekToItem(offset: currentItemIndex)
                } catch {
                    print("Failed to load PlaylistStatus with legacy format: \(error)")
                }
            }
        }
    }

    static let controllPlaylistNotificationName = Notification.Name(
        "PlaylistStatus.controllPlaylist")
    private var controlPlaylistObserver: NSObjectProtocol!
    private var terminationObserver: NSObjectProtocol?

    enum PlaylistControlCommand: Int {
        case nextTrack, previousTrack, switchLoopMode
    }

    static func controlPlaylist(command: PlaylistControlCommand) {
        NotificationCenter.default.post(
            name: controllPlaylistNotificationName,
            object: nil,
            userInfo: ["command": command]
        )
    }

    func initNotificationObservers() {
        let notificationCenter = NotificationCenter.default

        controlPlaylistObserver = notificationCenter.addObserver(
            forName: PlaylistStatus.controllPlaylistNotificationName, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self = self, let userInfo = notification.userInfo else { return }
            if let command = userInfo["command"] as? PlaylistControlCommand {
                switch command {
                case .nextTrack:
                    Task { [weak self] in
                        await self?.nextTrack()
                    }
                case .previousTrack:
                    Task { [weak self] in
                        await self?.previousTrack()
                    }
                case .switchLoopMode:
                    self.switchToNextLoopMode()
                }
            }
        }
    }

    func deinitNotificationObservers() {
        let notificationCenter = NotificationCenter.default
        if let ob = controlPlaylistObserver {
            notificationCenter.removeObserver(ob)
        }
        if let ob = terminationObserver {
            notificationCenter.removeObserver(ob)
            terminationObserver = nil
        }
    }

    func reinitializeRemoteCommands() {
        RemoteCommandCenter.handleRemoteCommands(using: self)
    }

    private var playerShouldNextObserver: NSObjectProtocol?

    init() {
        RemoteCommandCenter.handleRemoteCommands(using: self)

        playerShouldNextObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }

            Task { [weak self] in
                print("didPlayToEndTimeNotification")
                await self?.nextTrack()
            }
        }

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.saveState()
        }

        initNotificationObservers()
    }

    deinit {
        if let ob = playerShouldNextObserver {
            NotificationCenter.default.removeObserver(ob)
        }

        deinitNotificationObservers()
        
        // Clean up remote command center
        RemoteCommandCenter.cleanup()

        saveState()
    }
}
