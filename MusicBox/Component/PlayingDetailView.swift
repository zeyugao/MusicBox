//
//  PlayingDetail.swift
//  MusicBox
//
//  Created by Elsa on 2024/5/16.
//

import Foundation
import SwiftUI

struct LyricView: View {
    var lyric: CloudMusicApi.LyricNew
    var body: some View {
        ScrollView {
            VStack(alignment: .leading) {
                ForEach(lyric.lrc.parse().filter {
                    line in
                    return line.time >= 0 && !line.text.isEmpty
                }, id: \.self) { line in
                    Text(line.text)
                }
            }
        }
    }
}

struct PlayingDetailView: View {
    @State private var lyric: CloudMusicApi.LyricNew?
    @EnvironmentObject var playController: PlayController

    var body: some View {
        ZStack {
            // Button("Dismiss Modal") {
            //     PlayingDetailModel.closePlayingDetail()
            // }

            if let item = playController.currentItem {
                HStack {
                    Spacer()
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
                    Spacer()

                    if let lyric = lyric {
                        LyricView(lyric: lyric)
                            .padding()
                    }
                    Spacer()
                }
            }
        }.onAppear {
            Task {
                if let currentId = playController.currentItem?.id,
                    let lyric = await CloudMusicApi.lyric_new(id: currentId)
                {
                    self.lyric = lyric
                }
            }
        }
    }
}
