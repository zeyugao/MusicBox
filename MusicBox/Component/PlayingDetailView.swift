//
//  PlayingDetail.swift
//  MusicBox
//
//  Created by Elsa on 2024/5/16.
//

import Foundation
import SwiftUI


struct LyricView: View {
    var lyric: [CloudMusicApi.LyricLine]
    @EnvironmentObject var playStatus: PlayStatus
    @EnvironmentObject var appSettings: AppSettings
    @ObservedObject var lyricStatus: LyricStatus
    @Binding var hasRoma: Bool

    var body: some View {
        ScrollViewReader { proxy in
            let scrollToIdx: (Int) -> Void = { idx in
                guard !lyric.isEmpty else { return }
                let clamped = max(0, min(idx, lyric.count - 1))
                withAnimation(.spring) {
                    proxy.scrollTo("lyric-\(clamped)", anchor: .center)
                }
            }

            let formatTimestamp: (Double) -> String = { seconds in
                guard seconds.isFinite else { return "00:00.00" }
                let hundredths = max(0, Int((seconds * 100).rounded()))
                let minutes = hundredths / 6000
                let secondsComponent = (hundredths % 6000) / 100
                let subSecond = hundredths % 100
                return String(format: "%02d:%02d.%02d", minutes, secondsComponent, subSecond)
            }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading) {
                    ForEach(
                        lyric.indices, id: \.self
                    ) { index in
                        let line = lyric[index]
                        let currentPlaying = lyricStatus.currentLyricIndex == index

                        VStack(alignment: .leading) {
                            if appSettings.showTimestamp {
                                Text(formatTimestamp(line.time))
                                    .lineLimit(1)
                                    .font(.footnote)
                                    .foregroundColor(.gray)
                            }

                            if appSettings.showRoma, let romalrc = line.romalrc {
                                Text(romalrc)
                                    .font(.body)
                                    .foregroundStyle(
                                        Color(
                                            nsColor: currentPlaying
                                                ? NSColor.textColor : NSColor.placeholderTextColor))
                            }

                            Text(line.lyric)
                                .font(.title3)
                                .foregroundStyle(
                                    Color(
                                        nsColor: currentPlaying
                                            ? NSColor.textColor : NSColor.placeholderTextColor)
                                )
                                .id("lyric-\(index)")

                            if let tlyric = line.tlyric {
                                Text(tlyric)
                                    .font(.title3)
                                    .foregroundStyle(
                                        Color(
                                            nsColor: currentPlaying
                                                ? NSColor.textColor : NSColor.placeholderTextColor))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 12)
                .onChange(of: lyricStatus.currentLyricIndex) { _, newIndex in
                    #if DEBUG
                        print("LyricView: currentLyricIndex changed to \(String(describing: newIndex))")
                    #endif
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        if let index = newIndex {
                            scrollToIdx(index)
                        } else {
                            scrollToIdx(0)
                        }
                    }
                }
                .onChange(of: lyricStatus.scrollResetToken) { _, _ in
                    guard !lyric.isEmpty, !lyricStatus.lyricTimeline.isEmpty else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        scrollToIdx(0)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .focusCurrentPlayingItem)) {
                    notification in
                    if let index = notification.userInfo?["scrollToIndex"] as? Int {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            scrollToIdx(index)
                        }
                    }
                }
            }
        }
    }
}

struct PlayingDetailView: View {
    @State private var lyric: [CloudMusicApi.LyricLine]?
    @EnvironmentObject var playStatus: PlayStatus
    @EnvironmentObject var playlistStatus: PlaylistStatus
    @State var hasRoma: Bool = false
    @State private var showNoLyricMessage: Bool = false

    func updateLyric() async {
        showNoLyricMessage = false

        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
            if lyric == nil {
                showNoLyricMessage = true
            }
        }

        if let currentId = playStatus.currentItem?.id,
            let lyric = await CloudMusicApi(cacheTtl: -1).lyric_new(id: currentId)
        {
            self.hasRoma = !lyric.romalrc.lyric.isEmpty
            let lyric = lyric.merge()
            self.lyric = lyric
            await self.playStatus.lyricStatus.loadTimeline(
                lyric.map { Int($0.time * 10) },
                currentTime: self.playStatus.playbackProgress.playedSecond
            )

            if let currentIndex = self.playStatus.lyricStatus.currentLyricIndex {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NotificationCenter.default.post(
                        name: .focusCurrentPlayingItem,
                        object: nil,
                        userInfo: ["scrollToIndex": currentIndex]
                    )
                }
            }

            // Force restart lyric synchronization with new lyrics
            if playStatus.playerState == .playing {
                playStatus.restartLyricSynchronization()
            }

            showNoLyricMessage = false
        }
    }

    var body: some View {
        ZStack {
            if playStatus.currentItem != nil {
                VStack {
                    if let lyric = lyric {
                        LyricView(
                            lyric: lyric,
                            lyricStatus: playStatus.lyricStatus,
                            hasRoma: $hasRoma
                        )
                        .id(playStatus.currentItem?.id ?? 0)
                    } else if showNoLyricMessage {
                        Text("还没有歌词")
                    }
                }
            }
        }
        .task {
            await updateLyric()
        }
        .onChange(of: playStatus.currentItem) { oldItem, newItem in
            #if DEBUG
                print("PlayingDetailView: currentItem changed from \(oldItem?.title ?? "nil") to \(newItem?.title ?? "nil")")
            #endif
            Task {
                await updateLyric()
            }
        }
        .navigationTitle(playStatus.currentItem?.title ?? "Playing")
    }
}
