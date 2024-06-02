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
    @EnvironmentObject var playController: PlayController
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
                        let currentPlaying = playController.currentLyricIndex == index

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
                .onChange(of: playController.currentLyricIndex) { _, newIndex in
                    scrollToIdx(newIndex ?? 0)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Toggle(isOn: $showTimestamp) {
                        Image(systemName: "clock")
                    }
                    .onChange(of: showTimestamp) {
                        scrollToIdx(playController.currentLyricIndex ?? 0)
                    }
                    if hasRoma {
                        Toggle(isOn: $showRoma) {
                            Image(systemName: "quote.bubble")
                        }
                        .onChange(of: showRoma) {
                            scrollToIdx(playController.currentLyricIndex ?? 0)
                        }
                    }
                }
            }
        }
    }
}

struct PlayingDetailView: View {
    @State private var lyric: [CloudMusicApi.LyricLine]?
    @EnvironmentObject var playController: PlayController
    @State var hasRoma: Bool = false

    func updateLyric() async {
        if let currentId = playController.currentItem?.id,
            let lyric = await CloudMusicApi(cacheTtl: -1).lyric_new(id: currentId)
        {
            self.hasRoma = !lyric.romalrc.lyric.isEmpty
            let lyric = lyric.merge()
            self.lyric = lyric
            self.playController.lyricTimeline = lyric.map { Int($0.time * 10) }
            self.playController.currentLyricIndex = nil
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let item = playController.currentItem {
                    HStack(alignment: .center) {
                        VStack {
                            if let artworkUrl = item.artworkUrl {
                                AsyncImage(url: artworkUrl) { image in
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
            .onChange(of: playController.currentItem) {
                Task {
                    await updateLyric()
                }
            }
            .navigationTitle(playController.currentItem?.title ?? "Playing")
        }
    }
}
