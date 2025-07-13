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
                    proxy.scrollTo(idx, anchor: .center)
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
                                            ? NSColor.textColor : NSColor.placeholderTextColor))

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
                            .id(index)
                    }
                }
                .padding(.vertical)
                .onChange(of: lyricStatus.currentLyricIndex) { _, newIndex in
                    scrollToIdx(newIndex ?? 0)
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
    @State var hasRoma: Bool = false

    func updateLyric() async {
        if let currentId = playStatus.currentItem?.id,
            let lyric = await CloudMusicApi(cacheTtl: -1).lyric_new(id: currentId)
        {
            self.hasRoma = !lyric.romalrc.lyric.isEmpty
            let lyric = lyric.merge()
            self.lyric = lyric
            self.playStatus.lyricStatus.lyricTimeline = lyric.map { Int($0.time * 10) }
            self.playStatus.lyricStatus.resetLyricIndex(
                currentTime: self.playStatus.playbackProgress.playedSecond)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let item = playStatus.currentItem {
                    HStack(alignment: .center) {
                        VStack {
                            if let artworkUrl = item.artworkUrl {
                                AsyncImageWithCache(url: artworkUrl) { image in
                                    image.resizable()
                                        .interpolation(.high)
                                        .scaledToFit()
                                } placeholder: {
                                    Color.white
                                }
                                .frame(width: 200, height: 200)
                                .cornerRadius(5)
                            }
                            Text(item.title)
                                .font(.title)
                                .padding()
                            Text(item.artist)
                                .font(.title2)
                        }
                        .frame(width: geometry.size.width * 0.33, height: geometry.size.height)

                        Spacer()

                        VStack {
                            if let lyric = lyric {
                                LyricView(
                                    lyric: lyric,
                                    lyricStatus: playStatus.lyricStatus,
                                    hasRoma: $hasRoma
                                )
                            } else {
                                Text("还没有歌词")
                            }
                        }
                        .frame(width: geometry.size.width * 0.66, height: geometry.size.height)
                    }
                    .padding()
                }
            }.task {
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
}
