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

enum LoopMode: Int {
    case once
    case shuffle
    case sequence
}

enum PlayerState: Int {
    case unknown = 0
    case playing = 1
    case paused = 2
    case stopped = 3
    case interrupted = 4
}

class PlayController: ObservableObject, RemoteCommandHandler {
    private let savedCurrentPlaylistKey = "CurrentPlaylist"
    private let savedCurrentPlayingItemIndexKey = "CurrentPlayingItemIndex"

    private var player = AVPlayer()

    @Published var playedSecond: Double = 0.0
    @Published var duration: Double = 0.0

    @AppStorage("loopMode") var loopMode: LoopMode = .sequence

    @Published var loadingProgress: Double? = nil
    @Published var isLoading: Bool = false

    var scrobbled: Bool = false
    private var switchingItem: Bool = false

    var playerState: PlayerState = .stopped {
        didSet {
            DispatchQueue.main.async {
                self.isPlaying = self.playerState == .playing
            }
        }
    }

    @Published var isPlaying: Bool = false

    var playlist: [PlaylistItem] = []
    private var currentItemIndex: Int? = nil
    var currentItem: PlaylistItem? {
        if let currentItemIndex = currentItemIndex {
            return playlist[currentItemIndex]
        }
        return nil
    }

    private let timeScale = CMTimeScale(NSEC_PER_SEC)

    // Private notification observers.
    var periodicTimeObserverToken: Any?
    var playerShouldNextObserver: NSObjectProtocol?
    var playerSelectionChangedObserver: NSObjectProtocol?
    var playerStateObserver: NSKeyValueObservation?
    var timeControlStatus: AVPlayer.TimeControlStatus = .waitingToPlayAtSpecifiedRate
    var timeControlStautsObserver: NSKeyValueObservation?

    @Published var readyToPlay: Bool = true
    @Published var lyricTimeline: [Int] = []  // We align to 0.1s, 12.32 -> 123
    @Published var currentLyricIndex: Int? = nil

    func togglePlayPause() async {
        if !isPlaying {
            await startPlaying()
        } else {
            stopPlaying()
        }
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

    func stopPlaying() {
        player.pause()
        playerState = .paused
        updateCurrentPlaybackInfo()
        NowPlayingCenter.handleSetPlaybackState(playing: false)
        savePlayedSecond()
    }

    func startPlaying() async {
        if player.currentItem == nil {
            await nextTrack()
        }
        player.play()
        playerState = .playing
        updateCurrentPlaybackInfo()
        NowPlayingCenter.handleSetPlaybackState(playing: true)
    }

    func performRemoteCommand(_ command: RemoteCommand) {
        runBlocking {
            switch command {
            case .play:
                await startPlaying()
            case .pause:
                stopPlaying()
            case .togglePlayPause:
                await togglePlayPause()
            case .nextTrack:
                await nextTrack()
            case .previousTrack:
                await previousTrack()
            case .skipForward(let distance):
                await seekByOffset(offset: distance)
            case .skipBackward(let distance):
                await seekByOffset(offset: -distance)
            case .changePlaybackPosition(let offset):
                await seekToOffset(offset: offset)
            }
        }
    }

    func nextTrack() async {
        doScrobble()
        
        if loopMode == .once && currentItemIndex == playlist.count - 1 {
            stopPlaying()
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
        await seekByItem(offset: offset)
        await startPlaying()
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
        await startPlaying()
    }

    func seekByItem(offset: Int) async {
        guard playlist.count > 0 else { return }

        let currentItemIndex = currentItemIndex ?? 0
        let newItemIndex = (currentItemIndex + offset + playlist.count) % playlist.count
        await seekToItem(offset: newItemIndex)
    }

    func updateDuration(duration: Double) {
        DispatchQueue.main.async {
            self.duration = duration
        }
    }

    func replaceCurrentItem(item: AVPlayerItem?) {
        deinitPlayerObservers()
        player = AVPlayer(playerItem: item)
        loadVolume()
        player.automaticallyWaitsToMinimizeStalling = false
        initPlayerObservers()
    }

    func playBySongId(id: UInt64) async {
        guard let index = playlist.firstIndex(where: { $0.id == id }) else { return }
        await seekToItem(offset: index)
        await startPlaying()
    }

    func deleteBySongId(id: UInt64) async {
        guard let index = playlist.firstIndex(where: { $0.id == id }) else { return }
        playlist.remove(at: index)

        if let currentItemIndex = currentItemIndex {
            if index == currentItemIndex {
                await seekToItem(offset: index)
            } else if index < currentItemIndex {
                self.currentItemIndex = currentItemIndex - 1
                updateCurrentPlaybackInfo()
            }
        }

        await NowPlayingCenter.handleItemChange(
            item: currentItem,
            index: currentItemIndex ?? 0,
            count: playlist.count)

        saveState()
    }

    private func setLoadingProgress(_ progress: Double?) {
        DispatchQueue.main.async {
            self.loadingProgress = progress
            if (progress != nil) != self.isLoading {
                self.isLoading = progress != nil
            }
        }
    }

    func seekToItem(offset: Int?, playedSecond: Double? = nil) async {
        if switchingItem {
            return
        }
        switchingItem = true
        defer { switchingItem = false }
        DispatchQueue.main.async {
            if let playedSecond = playedSecond {
                self.playedSecond = playedSecond
            } else {
                self.playedSecond = 0.0
            }
        }
        if let offset = offset {
            print("seek to #\(offset)")
            guard offset < playlist.count else { return }

            if offset != currentItemIndex {
                scrobbled = false
            }

            let item = playlist[offset]
            currentItemIndex = offset
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
                assert(playedSecond == nil)
                let cacheItem = CachingPlayerItem(
                    url: url, saveFilePath: savePath.path, customFileExtension: ext)
                setLoadingProgress(0.0)
                cacheItem.delegate = self
                playerItem = cacheItem
            } else {
                return
            }

            replaceCurrentItem(item: playerItem)

            await NowPlayingCenter.handleItemChange(
                item: currentItem,
                index: currentItemIndex ?? 0,
                count: playlist.count)

            saveCurrentPlayingItemIndex()

            if let playedSecond = playedSecond {
                await seekToOffset(offset: playedSecond)
            }

        } else {
            updateDuration(duration: 0.0)
            currentItemIndex = nil
            replaceCurrentItem(item: nil)
        }
    }

    var volume: Float {
        get {
            player.volume
        }
        set {
            player.volume = newValue
            saveVolume()
        }
    }

    private var inSeeking = false

    func seekToOffset(offset newTime: CMTime) async {
        guard loadingProgress == nil else {
            print("Seeking while loading")
            return
        }

        if player.currentItem is CachingPlayerItem {
            if inSeeking {
                return
            }
            inSeeking = true
            defer { inSeeking = false }

            await seekToItem(offset: currentItemIndex, playedSecond: newTime.seconds)
            print("Seek a caching item to \(newTime.seconds)")
            await startPlaying()
            return
        }

        await player.seek(to: newTime, toleranceBefore: .zero, toleranceAfter: .zero)
        DispatchQueue.main.async {
            self.currentLyricIndex = nil
        }
        updateCurrentPlaybackInfo()
    }

    func seekToOffset(offset: Double) async {
        let newTime = CMTime(seconds: offset, preferredTimescale: timeScale)
        await seekToOffset(offset: newTime)
    }

    func seekByOffset(offset: Double) async {
        let currentTime = player.currentTime()
        let newTime = CMTimeAdd(currentTime, CMTime(seconds: offset, preferredTimescale: timeScale))
        await seekToOffset(offset: newTime)
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
        await seekToItem(offset: nil)
        if continuePlaying {
            await startPlaying()
        }
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
            await startPlaying()
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
            await seekToItem(offset: savedIndex)
        }
    }

    func saveVolume() {
        UserDefaults.standard.set(player.volume, forKey: "playerVolume")
    }

    private func loadVolume() {
        let volume = UserDefaults.standard.object(forKey: "playerVolume") as? Float ?? 0.5
        player.volume = volume
    }

    private func loadPlayedSecond() async {
        let newPlayedSecond = UserDefaults.standard.object(forKey: "playedSecond") as? Double ?? 0.0
        print("Loaded playedSecond: \(newPlayedSecond)")
        await seekToOffset(offset: newPlayedSecond)
    }

    private func savePlayedSecond() {
        UserDefaults.standard.set(playedSecond, forKey: "playedSecond")
    }

    private func saveMisc() {
        saveVolume()
    }

    private func loadMisc() {
        loadVolume()
    }

    func saveState() {
        savePlaylist()
        saveCurrentPlayingItemIndex()
        saveMisc()
    }

    func loadState(continuePlaying: Bool = true) async {
        DispatchQueue.main.async {
            self.loadMisc()
        }

        if let playlist = loadDecodableState(
            forKey: self.savedCurrentPlaylistKey, type: [PlaylistItem].self)
        {
            await self.replacePlaylist(
                playlist, continuePlaying: continuePlaying, shouldSaveState: false)
            print("Playlist loaded")
        } else {
            print("Failed to load playlist")
        }
        await self.loadCurrentPlayingItemIndex()

        DispatchQueue.main.async {
            Task {
                await self.loadPlayedSecond()
            }
        }
    }

    func clearPlaylist() {
        playlist = []
        saveState()
    }

    func addItemAndSeekTo(_ item: PlaylistItem) async -> Int {
        let idIdx = addItemToPlaylist(item, continuePlaying: false)
        await seekToItem(offset: idIdx)

        savePlaylist()
        return idIdx
    }

    private func doScrobble() {
        if let _ = player.currentItem, let currentItemIndex = currentItemIndex {
            if !scrobbled && readyToPlay {
                if playedSecond > 30 {
                    let item = playlist[currentItemIndex]
                    Task {
                        print("do scrobble")
                        if let song = item.nsSong{
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
    }

    func updateCurrentPlaybackInfo() {
        let duration =
            if let currentItemIndex = currentItemIndex {
                playlist[currentItemIndex].duration.seconds
            } else {
                0.0
            }

        NowPlayingCenter.handlePlaybackChange(
            playing: player.timeControlStatus == .playing, rate: player.rate,
            position: self.playedSecond,
            duration: duration)
    }

    func resetLyricIndex() {
        self.currentLyricIndex = monotonouslyUpdateLyric(lyricIndex: 0)
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

    func nowPlayingInit() {
        RemoteCommandCenter.handleRemoteCommands(using: self)
        updateCurrentPlaybackInfo()
        NowPlayingCenter.handleSetPlaybackState(playing: isPlaying)
    }

    func initPlayerObservers() {
        timeControlStautsObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) {
            [weak self] (player, changes) in
            self?.timeControlStatus = player.timeControlStatus
        }

        playerStateObserver = player.observe(\.rate, options: [.initial, .new]) { player, _ in
            guard player.status == .readyToPlay else { return }

            self.playerState = player.rate.isZero ? .paused : .playing
        }

        periodicTimeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: timeScale), queue: .main
        ) { [weak self] time in
            if !(self?.switchingItem ?? true) && (self?.readyToPlay ?? false) {
                let newTime = self?.player.currentTime().seconds ?? 0.0
                if Int(self?.playedSecond ?? 0) != Int(newTime) {
                    self?.playedSecond = newTime
                    self?.updateCurrentPlaybackInfo()
                }

                let initIdx = self?.currentLyricIndex
                let newIdx = self?.monotonouslyUpdateLyric(
                    lyricIndex: initIdx ?? 0, newTime: newTime)

                if newIdx != initIdx {
                    withAnimation {
                        self?.currentLyricIndex = newIdx
                    }
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

    init() {
        nowPlayingInit()

        playerShouldNextObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { _ in
            Task {
                await self.nextTrack()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            self.savePlayedSecond()
        }
    }

    deinit {
        deinitPlayerObservers()
    }
}

extension PlayController: CachingPlayerItemDelegate {
    func playerItemReadyToPlay(_ playerItem: CachingPlayerItem) {
        DispatchQueue.main.async {
            self.readyToPlay = true
        }
        print("Caching player item ready to play.")
    }

    func playerItemDidFailToPlay(_ playerItem: CachingPlayerItem, withError error: Error?) {
        print("playerItemDidFailToPlay", error?.localizedDescription ?? "")
        Task {
            await self.nextTrack()
        }
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
        print("Caching player item file download failed with error: \(error.localizedDescription).")
    }
}
