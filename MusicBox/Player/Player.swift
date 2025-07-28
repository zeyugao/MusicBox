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

    private var lastSearchIndex: Int = 0  // Cache last search position for performance

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

    init(
        lyricStatus: LyricStatus, getCurrentTime: @escaping () -> Double,
        shouldSynchronize: @escaping () -> Bool
    ) {
        self.lyricStatus = lyricStatus
        self.getCurrentTime = getCurrentTime
        self.shouldSynchronize = shouldSynchronize
    }

    func startSynchronization() {
        guard shouldSynchronize?() == true else { return }

        // Immediately update lyric index when starting synchronization
        if let getCurrentTime = getCurrentTime,
            let lyricStatus = lyricStatus
        {
            lyricStatus.updateLyricIndex(currentTime: getCurrentTime())
        }

        scheduleNextLyricUpdate()
    }

    func stopSynchronization() {
        preciseTimer?.invalidate()
        preciseTimer = nil
    }

    func updateSynchronizationState() {
        if shouldSynchronize?() == true {
            if preciseTimer == nil {
                startSynchronization()
            }
        } else {
            stopSynchronization()
        }
    }

    // Force update lyric index immediately (useful when detail view opens)
    func updateLyricIndexNow() {
        if let getCurrentTime = getCurrentTime,
            let lyricStatus = lyricStatus
        {
            lyricStatus.updateLyricIndex(currentTime: getCurrentTime())
        }
    }

    // Restart synchronization (useful after seeking)
    func restartSynchronization() {
        guard shouldSynchronize?() == true else { return }
        stopSynchronization()
        startSynchronization()
    }

    private func scheduleNextLyricUpdate() {
        preciseTimer?.invalidate()

        guard shouldSynchronize?() == true,
            let getCurrentTime = getCurrentTime,
            let lyricStatus = lyricStatus
        else {
            return
        }

        let currentTime = getCurrentTime()

        if let nextChangeTime = lyricStatus.getNextLyricChangeTime(currentTime: currentTime) {
            let timeInterval = max(nextChangeTime - currentTime, 0.01)  // Minimum 10ms

            if timeInterval > 0 && timeInterval < 10.0 {  // Only schedule if within reasonable range
                preciseTimer = Timer.scheduledTimer(withTimeInterval: timeInterval, repeats: false)
                { [weak self] _ in
                    self?.performLyricUpdate()
                }
            } else if timeInterval >= 10.0 {
                // For long intervals, schedule a check every 5 seconds to maintain synchronization
                preciseTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) {
                    [weak self] _ in
                    self?.performLyricUpdate()
                }
            }
        } else {
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

        player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
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

        await MainActor.run {
            self.isLoadingNewTrack = true
            self.pendingItem = item
        }

        self.currentItem = item

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
                        self.lyricSynchronizer?.updateSynchronizationState()
                    } else {
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
                if status.playedSecond > 0, let item = currentItem {
                    // 等待当前的切换操作完成
                    while switchingItem {
                        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
                    }
                    
                    // 如果播放器已经有了当前项目，直接seek；否则重新加载
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
        Task { @MainActor [weak self] in
            self?.readyToPlay = true
            self?.isLoadingNewTrack = false
            self?.pendingItem = nil
        }
        print("Caching player item ready to play.")
    }

    func playerItemDidFailToPlay(_ playerItem: CachingPlayerItem, withError error: Error?) {
        let message = "playerItemDidFailToPlay: \(error?.localizedDescription ?? "No reason")"
        print(message)
        AlertModal.showAlert(message)

        // Clear loading state on failure
        Task { @MainActor [weak self] in
            self?.isLoadingNewTrack = false
            self?.pendingItem = nil
        }

        self.nextTrack()
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

class PlaylistStatus: ObservableObject, RemoteCommandHandler {
    private let savedCurrentPlaylistKey = "CurrentPlaylist"
    private let savedCurrentPlayingItemIndexKey = "CurrentPlayingItemIndex"

    struct Storage: Codable {
        let playlist: [PlaylistItem]
        let currentItemIndex: Int?
        let loopMode: LoopMode
        let playNextQueue: [PlaylistItem]
    }

    @Published var loopMode: LoopMode = .sequence
    private var switchingItem: Bool = false

    @Published var playlist: [PlaylistItem] = []
    @Published var playNextQueue: [PlaylistItem] = []
    @Published private var currentItemIndex: Int? = nil
    var currentPlayingItemIndex: Int? {
        return currentItemIndex
    }
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

    func switchToNextLoopMode() {
        switch loopMode {
        case .once:
            loopMode = .sequence
        case .sequence:
            loopMode = .shuffle
        case .shuffle:
            loopMode = .once
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
        
        // Check play next queue first
        if let nextQueueItem = await getNextFromQueue() {
            // Add the queued item to playlist and play it
            let idIdx = addItemToPlaylist(nextQueueItem, continuePlaying: false)
            await seekToItem(offset: idIdx, shouldPlay: true)
            return
        }
        
        if loopMode == .once && currentItemIndex == playlist.count - 1 {
            pausePlay()
            await seekToItem(offset: nil)

            return
        }

        let offset: Int
        if loopMode == .shuffle {
            var nextIdx = Int.random(in: 0..<playlist.count)
            while nextIdx == currentItemIndex && playlist.count > 1 {
                nextIdx = Int.random(in: 0..<playlist.count)
            }
            offset = nextIdx
        } else {
            offset = 1
        }
        await seekByItem(offset: offset, shouldPlay: true)
    }

    func previousTrack() async {
        let offset: Int
        if loopMode == .shuffle {
            var nextIdx = Int.random(in: 0..<playlist.count)
            while nextIdx == currentItemIndex && playlist.count > 1 {
                nextIdx = Int.random(in: 0..<playlist.count)
            }
            offset = nextIdx
        } else {
            offset = -1
        }
        await seekByItem(offset: offset)
        startPlay()
    }

    func seekByItem(offset: Int, shouldPlay: Bool = false) async {
        guard playlist.count > 0 else { return }

        let currentItemIndex = currentItemIndex ?? 0
        let newItemIndex = (currentItemIndex + offset + playlist.count) % playlist.count
        await seekToItem(offset: newItemIndex, shouldPlay: shouldPlay)
    }

    func playBySongId(id: UInt64) async {
        guard let index = playlist.firstIndex(where: { $0.id == id }) else { return }
        await seekToItem(offset: index, shouldPlay: true)
    }

    func deleteBySongId(id: UInt64) async {
        guard let index = playlist.firstIndex(where: { $0.id == id }) else { return }
        playlist.remove(at: index)

        if let currentItemIndex = currentItemIndex {
            if index == currentItemIndex {
                await seekToItem(offset: index)
            } else if index < currentItemIndex {
                self.currentItemIndex = currentItemIndex - 1
            }
        }

        await NowPlayingCenter.handleItemChange(
            item: currentItem,
            index: currentItemIndex ?? 0,
            count: playlist.count)

        saveState()
    }

    func seekToItem(offset: Int?, playedSecond: Double? = 0.0, shouldPlay: Bool = false) async {
        if let offset = offset {
            guard offset < playlist.count else { return }

            let targetItem = playlist[offset]

            await MainActor.run {
                currentItemIndex = offset
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
    ) -> Int {
        let idIdx = findIdIndex(item.id)
        if idIdx == -1 {
            Task { @MainActor in
                playlist.append(item)
                if shouldSaveState {
                    saveState()
                }
            }
            return playlist.count // Return expected index
        }
        if shouldSaveState {
            Task { @MainActor in
                saveState()
            }
        }
        return idIdx
    }

    func replacePlaylist(
        _ items: [PlaylistItem], continuePlaying: Bool = true, shouldSaveState: Bool = true
    ) async {
        await MainActor.run {
            playlist = items
        }
        await seekToItem(offset: 0, shouldPlay: continuePlaying)
        if shouldSaveState {
            saveState()
        }
    }

    func addItemsToPlaylist(
        _ items: [PlaylistItem], continuePlaying: Bool = true, shouldSaveState: Bool = true
    ) async {
        for item in items {
            let _ = addItemToPlaylist(
                item, continuePlaying: continuePlaying, shouldSaveState: false)
        }
        if continuePlaying {
            startPlay()
        }
        if shouldSaveState {
            saveState()
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

    func clearPlaylist() {
        playlist = []
        saveState()
    }
    
    // MARK: - Play Next Queue Management
    
    func addToPlayNextQueue(_ item: PlaylistItem) {
        Task { @MainActor in
            playNextQueue.append(item)
            saveState()
        }
    }
    
    func clearPlayNextQueue() {
        Task { @MainActor in
            playNextQueue.removeAll()
            saveState()
        }
    }
    
    func removeFromPlayNextQueue(at index: Int) {
        Task { @MainActor in
            guard index >= 0 && index < playNextQueue.count else { return }
            playNextQueue.remove(at: index)
            saveState()
        }
    }
    
    func removeFromPlayNextQueue(itemId: UInt64) {
        Task { @MainActor in
            playNextQueue.removeAll { $0.id == itemId }
            saveState()
        }
    }
    
    private func getNextFromQueue() async -> PlaylistItem? {
        return await MainActor.run {
            guard !playNextQueue.isEmpty else { return nil }
            let nextItem = playNextQueue.removeFirst()
            saveState()
            return nextItem
        }
    }

    func addItemAndSeekTo(_ item: PlaylistItem, shouldPlay: Bool = false) async -> Int {
        let idIdx = addItemToPlaylist(item, continuePlaying: false)
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
                playNextQueue: playNextQueue
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
                    playNextQueue = storage.playNextQueue
                }

                await seekToItem(offset: currentItemIndex)
            } catch {
                print("Failed to load PlaylistStatus: \(error)")
                // Try to load without playNextQueue for backward compatibility
                do {
                    struct LegacyStorage: Codable {
                        let playlist: [PlaylistItem]
                        let currentItemIndex: Int?
                        let loopMode: LoopMode
                    }
                    let legacyStorage = try JSONDecoder().decode(LegacyStorage.self, from: data)
                    await MainActor.run {
                        playlist = legacyStorage.playlist
                        currentItemIndex = legacyStorage.currentItemIndex
                        loopMode = legacyStorage.loopMode
                        playNextQueue = []
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

        saveState()
    }
}
