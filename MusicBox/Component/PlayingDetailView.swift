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
    @ObservedObject var lyricStatus: LyricStatus
    @Binding var hasRoma: Bool

    @AppStorage("showRoma") var showRoma: Bool = false
    @AppStorage("showTimestamp") var showTimestamp: Bool = false

    var body: some View {
        ScrollViewReader { proxy in
            let scrollToIdx: (Int) -> Void = { idx in
                withAnimation(.spring) {
                    proxy.scrollTo("lyric-\(idx)", anchor: .center)
                }
            }
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading) {
                    ForEach(
                        lyric.indices, id: \.self
                    ) { index in
                        let line = lyric[index]
                        let currentPlaying = lyricStatus.currentLyricIndex == index

                        VStack(alignment: .leading) {
                            if showTimestamp {
                                Text(String(format: "%.2f", line.time))
                                    .lineLimit(1)
                                    .font(.body)
                                    .foregroundColor(.gray)
                            }

                            if showRoma, let romalrc = line.romalrc {
                                Text(romalrc)
                                    .font(.body)
                                    .foregroundStyle(
                                        Color(
                                            nsColor: currentPlaying
                                                ? NSColor.textColor : NSColor.placeholderTextColor))
                            }

                            Text(line.lyric)
                                .font(.title2)
                                .foregroundStyle(
                                    Color(
                                        nsColor: currentPlaying
                                            ? NSColor.textColor : NSColor.placeholderTextColor)
                                )
                                .id("lyric-\(index)")

                            if let tlyric = line.tlyric {
                                Text(tlyric)
                                    .font(.title2)
                                    .foregroundStyle(
                                        Color(
                                            nsColor: currentPlaying
                                                ? NSColor.textColor : NSColor.placeholderTextColor))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()

                        Spacer()
                    }
                }
                .padding(.vertical)
                .onAppear {
                    if let currentIndex = lyricStatus.currentLyricIndex {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            scrollToIdx(currentIndex)
                        }
                    }
                }
                .onChange(of: lyricStatus.currentLyricIndex) { _, newIndex in
                    if let index = newIndex {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            scrollToIdx(index)
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Toggle(isOn: $showTimestamp) {
                        Image(systemName: "clock")
                    }
                    .onChange(of: showTimestamp) {
                        scrollToIdx(lyricStatus.currentLyricIndex ?? 0)
                    }
                    if hasRoma {
                        Toggle(isOn: $showRoma) {
                            Image(systemName: "quote.bubble")
                        }
                        .onChange(of: showRoma) {
                            scrollToIdx(lyricStatus.currentLyricIndex ?? 0)
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
            self.playStatus.lyricStatus.lyricTimeline = lyric.map { Int($0.time * 10) }
            self.playStatus.lyricStatus.resetLyricIndex(
                currentTime: self.playStatus.playbackProgress.playedSecond)

            // Force restart lyric synchronization with new lyrics
            if playStatus.playerState == .playing {
                playStatus.restartLyricSynchronization()
            }

            // Ensure scroll position is updated after lyric index reset
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if self.playStatus.lyricStatus.currentLyricIndex != nil {
                    // Trigger scroll update by notifying the view
                    self.playStatus.lyricStatus.objectWillChange.send()
                }
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
                    } else if showNoLyricMessage {
                        Text("还没有歌词")
                    }
                }
                .padding()
            }
        }
        .task {
            await updateLyric()
        }
        .onChange(of: playStatus.currentItem) {
            Task {
                await updateLyric()
            }
        }
        .navigationTitle(playStatus.currentItem?.title ?? "Playing")
    }
}
