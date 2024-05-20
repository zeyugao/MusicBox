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
    @EnvironmentObject var playController: PlayController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading) {
                ForEach(
                    lyric.indices, id: \.self
                ) { index in
                    let line = lyric[index]
                    let currentPlaying = playController.currentLyricIndex == index

                    VStack(alignment: .leading) {
                        Text(String(format: "%.2f", line.time))
                            .lineLimit(1)
                            .font(currentPlaying ? .title2 : .body)
                            .foregroundColor(.gray)

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
                    playController.currentLyricIndex
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
                        .frame(width: geometry.size.width * 0.33, height: geometry.size.height)
                        Spacer()
                        VStack {
                            if let lyric = lyric {
                                LyricView(lyric: lyric, showRoma: $showRoma)
                            } else {
                                Text("还没有歌词")
                            }
                        }
                        .frame(width: geometry.size.width * 0.66, height: geometry.size.height)
                    }
                }
            }.onAppear {
                Task {
                    if let currentId = playController.currentItem?.id,
                        let lyric = await CloudMusicApi.lyric_new(id: currentId)
                    {
                        self.hasRoma = !lyric.romalrc.lyric.isEmpty
                        let lyric = lyric.merge()
                        self.lyric = lyric
                        self.playController.lyricTimeline = lyric.map { Int($0.time * 10) }
                        self.playController.currentLyricIndex = nil
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if hasRoma {
                        Button {
                            showRoma.toggle()
                        } label: {
                            Image(systemName: "quote.bubble")
                                .foregroundStyle(showRoma ? .blue : .gray)
                        }
                    }
                }
            }
        }
    }
}
