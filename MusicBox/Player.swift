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

struct Song2 {
    var title: String
    var artist: String
    var thumbnail: Image
}

class PlayController: ObservableObject {
    let sampleBufferPlayer = SampleBufferPlayer()

    @Published var isPlaying: Bool = false

    @Published var song: Song2 = Song2(
        title: "Song Title", artist: "Artist", thumbnail: Image(systemName: "music.note"))

    @Published var playedSecond: Double = 0.0
    @Published var duration: Double = 0.0

    var isUpdatingOffset: Bool = false

    // Private notification observers.
    private var currentOffsetObserver: NSObjectProtocol!
    private var currentItemObserver: NSObjectProtocol!
    private var playbackRateObserver: NSObjectProtocol!

    func togglePlayPause() {
        isPlaying.toggle()  // 切换播放状态
        if isPlaying {
            sampleBufferPlayer.play()
        } else {
            sampleBufferPlayer.pause()
        }
        updateCurrentPlaybackInfo()
    }

    func seekToOffset(offset: Double) {
        isUpdatingOffset = true
        playedSecond = offset
        let offset = CMTime(seconds: offset, preferredTimescale: 10)
        sampleBufferPlayer.seekToOffset(offset)
        
        updateCurrentPlaybackInfo()
    }

    private func updateCurrentPlaybackInfo() {
        NowPlayingCenter.handlePlaybackChange(
            playing: sampleBufferPlayer.isPlaying, rate: sampleBufferPlayer.rate,
            position: sampleBufferPlayer.currentItemEndOffset?.seconds ?? 0,
            duration: sampleBufferPlayer.currentItem?.duration.seconds ?? 0)
    }

    init() {
        let notificationCenter = NotificationCenter.default

        currentOffsetObserver = notificationCenter.addObserver(
            forName: SampleBufferPlayer.currentOffsetDidChange,
            object: sampleBufferPlayer,
            queue: .main
        ) { [unowned self] notification in
            if !isUpdatingOffset {
                let offset =
                    (notification.userInfo?[SampleBufferPlayer.currentOffsetKey] as? NSValue)?
                    .timeValue.seconds
                self.playedSecond = offset ?? 0.0
                
//                updateCurrentPlaybackInfo()
            }
        }

        currentItemObserver = notificationCenter.addObserver(
            forName: SampleBufferPlayer.currentItemDidChange,
            object: sampleBufferPlayer,
            queue: .main
        ) { [unowned self] _ in
            if let currentItem = sampleBufferPlayer.currentItem {
                let duration = currentItem.duration.seconds
                self.duration = duration

                self.song = Song2(
                    title: currentItem.title, artist: currentItem.artist,
                    thumbnail: Image(systemName: "music.note"))
            }
        }

        playbackRateObserver = notificationCenter.addObserver(
            forName: SampleBufferPlayer.playbackRateDidChange,
            object: sampleBufferPlayer,
            queue: .main
        ) { [unowned self] _ in
            isUpdatingOffset = false
            self.isPlaying = sampleBufferPlayer.isPlaying
            
            updateCurrentPlaybackInfo()
        }
    }
}
