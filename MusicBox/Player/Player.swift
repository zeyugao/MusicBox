//
//  Player.swift
//  MusicBox
//
//  Created by Elsa on 2024/4/18.
//

import AVFoundation
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

class PlayStatus: ObservableObject {
    private var player = AVPlayer()

    var playbackProgress = PlaybackProgress()
    
    @Published var isLoading: Bool = false
    @Published var loadingProgress: Double? = nil
    @Published var readyToPlay: Bool = true

    var currentItem: PlaylistItem? = nil

    enum PlayerState: Int {
        case unknown = 0
        case playing = 1
        case paused = 2
        case stopped = 3
        case interrupted = 4
    }

    @Published var playerState: PlayerState = .stopped
    @Published var lyricTimeline: [Int] = []  // We align to 0.1s, 12.32 -> 123
    @Published var currentLyricIndex: Int? = nil

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
    }

    var volume: Float {
        get {
            player.volume
        }
        set {
            player.volume = newValue
        }
    }

    private var inSeeking: Bool = false
    private var switchingItem: Bool = false
    private var seekingTask: Task<Void, Never>?

    func seekToOffset(offset newTime: CMTime) async {
        guard loadingProgress == nil else {
            print("Seeking while loading")
            return
        }

        seekingTask?.cancel()
        seekingTask = Task {
            await MainActor.run {
                playbackProgress.playedSecond = newTime.seconds
            }

            if let item = self.currentItem, player.currentItem is CachingPlayerItem {
                if inSeeking {
                    return
                }
                inSeeking = true
                defer { inSeeking = false }

                await seekToItem(item: item, playedSecond: newTime.seconds)
                print("Seek a caching item to \(newTime.seconds)")
                await startPlay()
                return
            }

            await player.seek(to: newTime, toleranceBefore: .zero, toleranceAfter: .zero)
            await MainActor.run {
                self.currentLyricIndex = nil
            }
            updateCurrentPlaybackInfo()
        }
        await seekingTask?.value
    }

    private let timeScale = CMTimeScale(NSEC_PER_SEC)

    func seekToOffset(offset: Double) async {
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
        defer { switchingItem = false }

        self.currentItem = item

        await updateDuration(duration: item.duration.seconds)

        let playerItem: AVPlayerItem
        if let url = item.getLocalUrl() {
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

    func resetLyricIndex() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.currentLyricIndex = self.monotonouslyUpdateLyric(lyricIndex: 0)
        }
    }

    func monotonouslyUpdateLyric(lyricIndex: Int, newTime: Double? = nil) -> Int? {
        var lyricIndex = lyricIndex

        let roundedPlayedSecond = Int((newTime ?? playbackProgress.playedSecond) * 10)
        while lyricIndex < self.lyricTimeline.count
            && roundedPlayedSecond >= self.lyricTimeline[lyricIndex]
        {
            lyricIndex += 1
        }
        if lyricIndex > 0 {
            return lyricIndex - 1
        }
        return nil
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

            Task { @MainActor in
                self.playerState = player.rate.isZero ? .paused : .playing
            }
        }

        periodicTimeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: timeScale), queue: .main
        ) { [weak self] time in
            guard let self = self else { return }
            if !self.switchingItem && self.readyToPlay {
                let newTime = self.player.currentTime().seconds
                if Int(self.playbackProgress.playedSecond) != Int(newTime) {
                    Task { @MainActor in
                        self.playbackProgress.playedSecond = newTime
                    }
                    self.updateCurrentPlaybackInfo()
                }

                let initIdx = self.currentLyricIndex
                let newIdx = self.monotonouslyUpdateLyric(
                    lyricIndex: initIdx ?? 0, newTime: newTime)

                if newIdx != initIdx {
                    // withAnimation {
                    self.currentLyricIndex = newIdx
                    // }
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
                                let shouldPlay = argument["shouldPlay"] as? Bool ?? false
                                let playedSecond = argument["playedSecond"] as? Double
                                await self.seekToItem(item: item, playedSecond: playedSecond)

                                if shouldPlay {
                                    await self.startPlay()
                                }
                            }
                        } else {
                            Task { @MainActor [weak self] in
                                self?.currentItem = nil
                                self?.playbackProgress.duration = 0.0
                                self?.playbackProgress.playedSecond = 0.0
                                self?.playerState = .stopped
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
                print("playedSecond: \(status.playedSecond)")
                await self.seekToOffset(offset: status.playedSecond)
                volume = status.volume
            } catch {
                print("Failed to load PlayStatus")
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

    deinit {
        deinitPlayerObservers()
        deinitNotificationObservers()

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
        }
        print("Caching player item ready to play.")
    }

    func playerItemDidFailToPlay(_ playerItem: CachingPlayerItem, withError error: Error?) {
        let message = "playerItemDidFailToPlay: \(error?.localizedDescription ?? "No reason")"
        print(message)
        AlertModal.showAlert(message)
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
    }

    @Published var loopMode: LoopMode = .sequence
    private var switchingItem: Bool = false

    @Published var playlist: [PlaylistItem] = []
    @Published private var currentItemIndex: Int? = nil
    var currentItem: PlaylistItem? {
        if let currentItemIndex = currentItemIndex {
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
                    "item": playlist[offset],
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
        var idIdx = findIdIndex(item.id)
        if idIdx == -1 {
            playlist.append(item)
            idIdx = playlist.count - 1
        }
        if shouldSaveState {
            saveState()
        }
        return idIdx
    }

    func replacePlaylist(
        _ items: [PlaylistItem], continuePlaying: Bool = true, shouldSaveState: Bool = true
    ) async {
        playlist = items
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
                loopMode: loopMode
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
                }

                await MainActor.run {
                    loopMode = storage.loopMode
                }

                await seekToItem(offset: currentItemIndex)
            } catch {
                print("Failed to load PlaylistStatus")
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
