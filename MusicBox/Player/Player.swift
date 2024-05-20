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

    @Published var loopMode: LoopMode = .sequence

    @Published var isLoading = false

    var lastUpdatedSecond: Int = 0

    var isUpdatingOffset: Bool = false

    var scrobbled: Bool = false

    var playerState: PlayerState = .stopped

    var isPlaying: Bool {
        playerState == .playing
    }

    var playlist: [PlaylistItem] = []
    private var currentItemIndex: Int? = nil
    var currentItem: PlaylistItem? {
        if let currentItemIndex = currentItemIndex {
            return playlist[currentItemIndex]
        }
        return nil
    }

    // Private notification observers.
    var periodicTimeObserverToken: Any?
    var playerShouldNextObserver: NSObjectProtocol?
    var playerSelectionChangedObserver: NSObjectProtocol?
    var playerStateObserver: NSKeyValueObservation?
    var timeControlStatus: AVPlayer.TimeControlStatus = .waitingToPlayAtSpecifiedRate
    var timeControlStautsObserver: NSKeyValueObservation?

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
        saveLoopMode()
    }

    func stopPlaying() {
        player.pause()
        playerState = .paused
        updateCurrentPlaybackInfo()
        NowPlayingCenter.handleSetPlaybackState(playing: isPlaying)
    }

    func startPlaying() async {
        if player.currentItem == nil {
            await nextTrack()
        }
        player.play()
        playerState = .playing
        updateCurrentPlaybackInfo()
        NowPlayingCenter.handleSetPlaybackState(playing: isPlaying)
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
                seekByOffset(offset: distance)
            case .skipBackward(let distance):
                seekByOffset(offset: -distance)
            case .changePlaybackPosition(let offset):
                seekToOffset(offset: offset)
            }
        }
    }

    func nextTrack() async {
        if loopMode == .once && currentItemIndex == playlist.count - 1 {
            stopPlaying()
            await seekToItem(offset: nil)
        }

        let offset =
            if loopMode == .shuffle {
                Int.random(in: 0..<playlist.count)
            } else {
                1
            }
        await seekByItem(offset: offset)
        await startPlaying()
    }

    func previousTrack() async {
        let offset =
            if loopMode == .shuffle {
                Int.random(in: 0..<playlist.count)
            } else {
                -1
            }
        await seekToItem(offset: offset)
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

        saveState()
    }

    func seekToItem(offset: Int?) async {
        if let offset = offset {
            guard offset < playlist.count else { return }

            let item = playlist[offset]
            currentItemIndex = offset
            updateDuration(duration: item.duration.seconds)

            let playerItem: AVPlayerItem
            if let url = item.getLocalUrl() {
                playerItem = AVPlayerItem(url: url)
            } else if let url = await item.getUrlAsync(),
                let savePath = item.getPotentialLocalUrl(),
                let ext = item.ext
            {
                playerItem = CachingPlayerItem(
                    url: url, saveFilePath: savePath.path, customFileExtension: ext)
            } else {
                return
            }

            replaceCurrentItem(item: playerItem)

            NowPlayingCenter.handleItemChange(
                item: currentItem,
                index: currentItemIndex ?? 0,
                count: playlist.count)

            saveCurrentPlayingItemIndex()
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

    func seekToOffset(offset: Double) {
        let newTime = CMTime(seconds: offset, preferredTimescale: 1)
        player.seek(to: newTime)
        updateCurrentPlaybackInfo()
    }

    func seekByOffset(offset: Double) {
        let currentTime = player.currentTime()
        let newTime = CMTimeAdd(currentTime, CMTime(seconds: offset, preferredTimescale: 1))
        player.seek(to: newTime)
        updateCurrentPlaybackInfo()
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

    func saveLoopMode() {
        UserDefaults.standard.set(loopMode.rawValue, forKey: "LoopMode")
    }

    func loadLoopMode() {
        let loopMode = UserDefaults.standard.integer(forKey: "LoopMode")
        self.loopMode = LoopMode(rawValue: loopMode) ?? .sequence
    }

    func saveVolume() {
        UserDefaults.standard.set(player.volume, forKey: "playerVolume")
    }

    private func loadVolume() {
        let volume = UserDefaults.standard.object(forKey: "playerVolume") as? Float ?? 0.5
        player.volume = volume
    }

    private func saveMisc() {
        saveLoopMode()
        saveVolume()
    }

    private func loadMisc() {
        loadLoopMode()
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
        if let currentItem = player.currentItem, let currentItemIndex = currentItemIndex {
            if !scrobbled {
                if playedSecond / currentItem.duration.seconds > 0.75 {
                    let item = playlist[currentItemIndex]
                    Task {
                        await CloudMusicApi.scrobble(
                            id: item.id, sourceid: item.albumId,
                            time: Int64(item.duration.seconds))
                        scrobbled = true
                    }
                }
            }
        }
    }

    func updateCurrentPlaybackInfo() {
        doScrobble()

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

        let timeScale = CMTimeScale(NSEC_PER_SEC)

        playerStateObserver = player.observe(\.rate, options: [.initial, .new]) { player, _ in
            guard player.status == .readyToPlay else { return }

            self.playerState = player.rate.isZero ? .paused : .playing
        }

        periodicTimeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: timeScale), queue: .main
        ) { [weak self] time in
            self?.playedSecond = self?.player.currentTime().seconds ?? 0.0
            self?.updateCurrentPlaybackInfo()
        }

        playerShouldNextObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { _ in
            Task {
                await self.nextTrack()
            }
        }

        playerSelectionChangedObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: nil, queue: .main
        ) { _ in
            print("mediaSelectionDidChangeNotification")
        }
    }

    func deinitPlayerObservers() {
        if let timeObserverToken = periodicTimeObserverToken {
            player.removeTimeObserver(timeObserverToken)
            periodicTimeObserverToken = nil
            playedSecond = 0
        }
        playerStateObserver?.invalidate()
        timeControlStautsObserver?.invalidate()

        if let obs = playerShouldNextObserver {
            NotificationCenter.default.removeObserver(obs)
            playerShouldNextObserver = nil
        }
    }

    init() {
        nowPlayingInit()
    }

    deinit {
        deinitPlayerObservers()
    }
}
