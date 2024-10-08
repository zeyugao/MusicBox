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

class PlayStatus: ObservableObject {
    private var player = AVPlayer()

    @Published var playedSecond: Double = 0.0
    @Published var duration: Double = 0.0

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
        DispatchQueue.main.async {
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
        DispatchQueue.main.async {
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

    func seekToOffset(offset newTime: CMTime) async {
        guard loadingProgress == nil else {
            print("Seeking while loading")
            return
        }

        DispatchQueue.main.async {
            self.playedSecond = newTime.seconds
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
        DispatchQueue.main.async {
            self.currentLyricIndex = nil
        }
        updateCurrentPlaybackInfo()
    }

    private let timeScale = CMTimeScale(NSEC_PER_SEC)

    func seekToOffset(offset: Double) async {
        let newTime = CMTime(seconds: offset, preferredTimescale: timeScale)
        await seekToOffset(offset: newTime)
    }

    func updateDuration(duration: Double) {
        DispatchQueue.main.async {
            self.duration = duration
        }
    }

    func seekByOffset(offset: Double) async {
        let currentTime = player.currentTime()
        let newTime = CMTimeAdd(currentTime, CMTime(seconds: offset, preferredTimescale: timeScale))
        await seekToOffset(offset: newTime)
    }

    func replaceCurrentItem(item: AVPlayerItem?) {
        deinitPlayerObservers()
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

        updateDuration(duration: item.duration.seconds)

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
            DispatchQueue.main.async {
                self.readyToPlay = false
            }
            assert(playedSecond == nil || playedSecond == 0.0)
            let cacheItem = CachingPlayerItem(
                url: url, saveFilePath: savePath.path, customFileExtension: ext)
            setLoadingProgress(0.0)
            cacheItem.delegate = self
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

    private func doScrobble() {
        if !scrobbled && readyToPlay {
            if playedSecond > 30 {
                Task {
                    print("do scrobble")
                    if let item = currentItem, let song = item.nsSong {
                        await CloudMusicApi().scrobble(
                            song: song,
                            playedTime: Int(playedSecond)
                        )
                    }
                    scrobbled = true
                }
            }
        }
    }

    func resetLyricIndex() {
        DispatchQueue.main.async {
            self.currentLyricIndex = self.monotonouslyUpdateLyric(lyricIndex: 0)
        }
    }

    func monotonouslyUpdateLyric(lyricIndex: Int, newTime: Double? = nil) -> Int? {
        var lyricIndex = lyricIndex

        let roundedPlayedSecond = Int((newTime ?? playedSecond) * 10)
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
        DispatchQueue.main.async {
            self.loadingProgress = progress
            if (progress != nil) != self.isLoading {
                self.isLoading = progress != nil
            }
        }
    }

    func updateCurrentPlaybackInfo() {
        NowPlayingCenter.handlePlaybackChange(
            playing: player.timeControlStatus == .playing, rate: player.rate,
            position: self.playedSecond,
            duration: duration)
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
            self?.timeControlStatus = player.timeControlStatus
        }

        playerStateObserver = player.observe(\.rate, options: [.initial, .new]) {
            [weak self] (player, _) in
            guard player.status == .readyToPlay else { return }

            DispatchQueue.main.async {
                self?.playerState = player.rate.isZero ? .paused : .playing
            }
        }

        periodicTimeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: timeScale), queue: .main
        ) { [weak self] time in
            if !(self?.switchingItem ?? true) && (self?.readyToPlay ?? false) {
                let newTime = self?.player.currentTime().seconds ?? 0.0
                if Int(self?.playedSecond ?? 0) != Int(newTime) {
                    DispatchQueue.main.async {
                        self?.playedSecond = newTime
                    }
                    self?.updateCurrentPlaybackInfo()
                }

                let initIdx = self?.currentLyricIndex
                let newIdx = self?.monotonouslyUpdateLyric(
                    lyricIndex: initIdx ?? 0, newTime: newTime)

                if newIdx != initIdx {
                    // withAnimation {
                    self?.currentLyricIndex = newIdx
                    // }
                }
            }
        }
    }

    func deinitPlayerObservers() {
        if let timeObserverToken = periodicTimeObserverToken {
            player.removeTimeObserver(timeObserverToken)
            periodicTimeObserverToken = nil
            DispatchQueue.main.async {
                self.playedSecond = 0
            }
        }
        playerStateObserver?.invalidate()
        timeControlStautsObserver?.invalidate()
    }

    static let controllPlayerNotificationName = Notification.Name("PlayStatus.controll")
    private var controlPlayerObserver: NSObjectProtocol?

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
        ) { notification in
            guard let userInfo = notification.userInfo else { return }
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
                            DispatchQueue.main.async {
                                self.currentItem = nil
                                self.duration = 0.0
                                self.playedSecond = 0.0
                                self.playerState = .stopped
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
            let storage = Storage(playedSecond: playedSecond, volume: volume)
            let data = try JSONEncoder().encode(storage)
            UserDefaults.standard.set(data, forKey: "PlayStatus")
        } catch {
            print("Failed to save PlayStatus")
        }
    }

    init() {
        initPlayerObservers()
        initNotificationObservers()

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.saveState()
        }
    }

    deinit {
        deinitPlayerObservers()
        deinitNotificationObservers()

        saveState()
    }
}

extension PlayStatus: CachingPlayerItemDelegate {
    func playerItemReadyToPlay(_ playerItem: CachingPlayerItem) {
        DispatchQueue.main.async {
            self.readyToPlay = true
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
        if let _ = loadingProgress {
            setLoadingProgress(Double(bytesDownloaded) / Double(bytesExpected))
        }
    }

    func playerItem(_ playerItem: CachingPlayerItem, didFinishDownloadingFileAt filePath: String) {
        setLoadingProgress(nil)
        print("Caching player item file downloaded.")
    }

    func playerItem(_ playerItem: CachingPlayerItem, downloadingFailedWith error: Error) {
        setLoadingProgress(nil)
        let message = "Caching player item file download failed with error: \(error.localizedDescription)."
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

    var loopMode: LoopMode = .sequence
    private var switchingItem: Bool = false

    var playlist: [PlaylistItem] = []
    private var currentItemIndex: Int? = nil
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
            currentItemIndex = offset

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
                playlist = storage.playlist
                currentItemIndex = storage.currentItemIndex
                loopMode = storage.loopMode

                await seekToItem(offset: currentItemIndex)
            } catch {
                print("Failed to load PlaylistStatus")
            }
        }
    }

    static let controllPlaylistNotificationName = Notification.Name(
        "PlaylistStatus.controllPlaylist")
    private var controlPlaylistObserver: NSObjectProtocol!

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
        ) { notification in
            guard let userInfo = notification.userInfo else { return }
            if let command = userInfo["command"] as? PlaylistControlCommand {
                switch command {
                case .nextTrack:
                    Task {
                        await self.nextTrack()
                    }
                case .previousTrack:
                    Task {
                        await self.previousTrack()
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
    }

    private var playerShouldNextObserver: NSObjectProtocol?

    init() {
        RemoteCommandCenter.handleRemoteCommands(using: self)

        playerShouldNextObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { _ in
            Task {
                print("didPlayToEndTimeNotification")
                await self.nextTrack()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            self.saveState()
        }

        initNotificationObservers()
    }

    deinit {
        if let ob = playerShouldNextObserver {
            NotificationCenter.default.removeObserver(ob)
        }

        saveState()
    }
}
