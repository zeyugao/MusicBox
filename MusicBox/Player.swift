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

enum LoopMode {
    case once
    case shuffle
    case sequence
}

class PlayController: ObservableObject, RemoteCommandHandler {
    let sampleBufferPlayer = SampleBufferPlayer()

    @Published var isPlaying: Bool = false

    @Published var playedSecond: Double = 0.0
    @Published var duration: Double = 0.0

    @Published var loopMode: LoopMode = .sequence

    @Published var isLoading = false

    var lastUpdatedSecond: Int = 0

    var isUpdatingOffset: Bool = false

    var scrobbled: Bool = false

    // Private notification observers.
    private var currentOffsetObserver: NSObjectProtocol!
    private var currentItemObserver: NSObjectProtocol!
    private var playbackRateObserver: NSObjectProtocol!
    private var playbackOffsetChangeObserver: NSObjectProtocol!

    func togglePlayPause() {
        isPlaying.toggle()  // 切换播放状态
        if isPlaying {
            startPlaying()
        } else {
            stopPlaying()
        }
    }

    func stopPlaying() {
        sampleBufferPlayer.pause()
        isPlaying = false
        NowPlayingCenter.handleSetPlaybackState(playing: isPlaying)
        updateCurrentPlaybackInfo()
    }

    func startPlaying() {
        guard sampleBufferPlayer.itemCount > 0 else { return }
        RemoteCommandCenter.handleRemoteCommands(using: self)
        sampleBufferPlayer.play()
        isPlaying = true
        NowPlayingCenter.handleSetPlaybackState(playing: isPlaying)
        updateCurrentPlaybackInfo()
    }

    func performRemoteCommand(_ command: RemoteCommand) {
        switch command {
        case .play:
            startPlaying()
        case .pause:
            stopPlaying()
        case .nextTrack:
            nextTrack()
            break
        case .previousTrack:
            previousTrack()
            break
        case .skipForward(let distance):
            seekByOffset(offset: distance)
        case .skipBackward(let distance):
            seekByOffset(offset: -distance)
        case .changePlaybackPosition(let offset):
            seekToOffset(offset: offset)
        }
    }

    func nextTrack() {
        let offset =
            if loopMode == .shuffle {
                Int.random(in: 0..<sampleBufferPlayer.itemCount)
            } else {
                1
            }
        seekItemByOffset(offset: offset)
    }

    func previousTrack() {
        let offset =
            if loopMode == .shuffle {
                Int.random(in: 0..<sampleBufferPlayer.itemCount)
            } else {
                -1
            }
        seekItemByOffset(offset: offset)
    }

    func seekItemByOffset(offset: Int) {
        if let currentItemIndex = sampleBufferPlayer.currentItemIndex {
            let totalCnt = sampleBufferPlayer.itemCount
            let offset = (offset + totalCnt) % totalCnt
            let newItemIndex = ((currentItemIndex + offset) + totalCnt) % totalCnt
            sampleBufferPlayer.seekToItem(at: newItemIndex)
        }
    }

    func seekToOffset(offset: Double) {
        isUpdatingOffset = true
        playedSecond = offset
        let offset = CMTime(seconds: offset, preferredTimescale: 10)
        sampleBufferPlayer.seekToOffset(offset)
        updateCurrentPlaybackInfo()
    }

    func seekByOffset(offset: Double) {
        isUpdatingOffset = true
        let newPlayedSecond = playedSecond + offset
        let offset = CMTime(seconds: newPlayedSecond, preferredTimescale: 10)
        sampleBufferPlayer.seekToOffset(offset)
        updateCurrentPlaybackInfo()
    }

    private func findIdIndex(_ id: UInt64) -> Int {
        let items = sampleBufferPlayer.items
        for (index, item) in items.enumerated() {
            if item.id == id {
                return index
            }
        }
        return -1
    }

    func addItemToPlaylist(_ item: PlaylistItem, continuePlaying: Bool = true) -> Int {
        var idIdx = findIdIndex(item.id)
        if idIdx == -1 {
            let totalCnt = sampleBufferPlayer.itemCount
            sampleBufferPlayer.insertItem(item, at: totalCnt, continuePlaying: continuePlaying)
            idIdx = totalCnt
        }
        return idIdx
    }

    func addItemAndPlay(_ item: PlaylistItem) -> Int {
        let idIdx = addItemToPlaylist(item, continuePlaying: false)
        sampleBufferPlayer.seekToItem(at: idIdx)
        return idIdx
    }

    private func doScrobble() {
        if let currentItem = sampleBufferPlayer.currentItem {
            if playedSecond / currentItem.duration.seconds > 0.75 {
                if !scrobbled {
                    Task {
                        await CloudMusicApi.scrobble(
                            id: currentItem.id, sourceid: currentItem.albumId,
                            time: Int64(duration))
                        scrobbled = true
                    }
                }
            }
        }
    }

    private func updateCurrentPlaybackInfo() {
        doScrobble()

        NowPlayingCenter.handlePlaybackChange(
            playing: sampleBufferPlayer.isPlaying, rate: sampleBufferPlayer.rate,
            position: self.playedSecond,
            duration: sampleBufferPlayer.currentItem?.duration.seconds ?? 0)
    }

    init() {
        let notificationCenter = NotificationCenter.default

        currentOffsetObserver = notificationCenter.addObserver(
            forName: SampleBufferPlayer.currentOffsetDidChange,
            object: sampleBufferPlayer,
            queue: .main
        ) { [unowned self] notification in
            let offset =
                (notification.userInfo?[SampleBufferPlayer.currentOffsetKey] as? NSValue)?
                .timeValue.seconds
            // Avoid updating the offset if it is being changed by the user.
            if !isUpdatingOffset {
                if let offset = offset {
                    let newOffset = Int(offset)
                    if newOffset != lastUpdatedSecond {
                        lastUpdatedSecond = newOffset
                        DispatchQueue.main.async {
                            self.playedSecond = Double(self.lastUpdatedSecond)
                        }
                    }
                }
            }
            updateCurrentPlaybackInfo()
        }

        currentItemObserver = notificationCenter.addObserver(
            forName: SampleBufferPlayer.currentItemDidChange,
            object: sampleBufferPlayer,
            queue: .main
        ) { [unowned self] _ in
            NowPlayingCenter.handleItemChange(
                item: sampleBufferPlayer.currentItem,
                index: sampleBufferPlayer.currentItemIndex ?? 0,
                count: sampleBufferPlayer.itemCount)

            scrobbled = false

            if let currentItem = sampleBufferPlayer.currentItem {
                let duration = currentItem.duration.seconds
                self.duration = duration
            } else {
                switch loopMode {
                case .once:
                    self.stopPlaying()
                case .sequence:
                    self.startPlaying()
                case .shuffle:
                    self.nextTrack()
                }
            }
        }

        playbackRateObserver = notificationCenter.addObserver(
            forName: SampleBufferPlayer.playbackRateDidChange,
            object: sampleBufferPlayer,
            queue: .main
        ) { [unowned self] notification in
            self.isPlaying = sampleBufferPlayer.isPlaying
            updateCurrentPlaybackInfo()
            isUpdatingOffset = false

            if let isLoading = notification.userInfo?[SampleBufferPlayer.isLoadingKey] as? Bool {
                self.isLoading = isLoading
            }
        }

        playbackOffsetChangeObserver = notificationCenter.addObserver(
            forName: SampleBufferPlayer.playbackOffsetDidUpdated,
            object: sampleBufferPlayer,
            queue: .main
        ) { [unowned self] _ in
            isUpdatingOffset = false
            self.isPlaying = sampleBufferPlayer.isPlaying

            updateCurrentPlaybackInfo()
        }
    }
}
