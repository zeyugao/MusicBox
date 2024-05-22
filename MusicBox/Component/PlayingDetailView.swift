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
    @Binding var showRoma: Bool
    @Binding var showTimestamp: Bool
    @EnvironmentObject var playController: PlayController

    var body: some View {
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
                                .font(currentPlaying ? .title2 : .body)
                                .foregroundColor(.gray)
                        }

                        if showRoma, let romalrc = line.romalrc {
                            Text(romalrc)
                                .lineLimit(1)
                                .font(currentPlaying ? .title2 : .body)
                        }

                        Text(line.lyric)
                            .lineLimit(1)
                            .font(currentPlaying ? .title : .body)

                        if let tlyric = line.tlyric {
                            Text(tlyric)
                                .lineLimit(1)
                                .font(currentPlaying ? .title : .body)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()

                    Spacer()
                        .id(index)
                }
            }
            .padding()
        }
        .scrollPosition(
            id: Binding(
                get: {
                    playController.currentLyricIndex ?? 0
                },
                set: { value in
                }),
            anchor: .center)
    }
}

struct PlayingDetailView: View {
    @State private var lyric: [CloudMusicApi.LyricLine]?
    @EnvironmentObject var playController: PlayController
    @State var showRoma: Bool = false
    @State var hasRoma: Bool = false
    @State var showTimestamp: Bool = false

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
                        .padding()

                        .frame(width: geometry.size.width * 0.33, height: geometry.size.height)
                        Spacer()
                        VStack {
                            if let lyric = lyric {
                                LyricView(
                                    lyric: lyric, showRoma: $showRoma, showTimestamp: $showTimestamp
                                )
                            } else {
                                Text("还没有歌词")
                            }
                        }
                        .frame(width: geometry.size.width * 0.66, height: geometry.size.height)
                    }
                }
            }.onAppear {
                Task {
                    await updateLyric()
                }
            }
            .onChange(of: playController.currentItem) {
                Task {
                    await updateLyric()
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Toggle(isOn: $showTimestamp) {
                        Image(systemName: "clock")
                    }
                    if hasRoma {
                        Toggle(isOn: $showRoma) {
                            Image(systemName: "quote.bubble")
                        }
                    }
                }
            }
        }
    }
}
