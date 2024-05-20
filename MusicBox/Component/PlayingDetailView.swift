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
                            .font(currentPlaying ? .title : .body)
                            .foregroundColor(.gray)

                        Text(line.lyric)
                            .font(currentPlaying ? .title : .body)

                        if let tlyric = line.tlyric {
                            Text(tlyric)
                                .font(currentPlaying ? .title : .body)
                                .padding(.top, 8)
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

    var body: some View {
        ZStack {
            if let item = playController.currentItem {
                HStack {
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
                    }
                    .frame(maxWidth: .infinity)

                    Divider()

                    VStack {
                        if let lyric = lyric {
                            LyricView(lyric: lyric)
                        } else {
                            Text("还没有歌词")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }.onAppear {
            Task {
                if let currentId = playController.currentItem?.id,
                    let lyric = await CloudMusicApi.lyric_new(id: currentId)
                {
                    let lyric = lyric.merge()
                    self.lyric = lyric
                    self.playController.lyricTimeline = lyric.map { $0.time }
                    self.playController.currentLyricIndex = nil
                }
            }
        }
    }
}