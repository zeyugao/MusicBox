//
//  NowPlaying.swift
//  MusicBox
//
//  Created by Elsa on 2024/5/6.
//

import CoreMedia
import Foundation
import SwiftUI

func formatCMTime(_ time: CMTime) -> String {
    // Converting CMTime to seconds
    let totalSeconds = CMTimeGetSeconds(time)
    guard !totalSeconds.isNaN else { return "00:00" }  // Check for NaN which can occur for an invalid CMTime

    // Extracting minutes and seconds from total seconds
    let minutes = Int(totalSeconds) / 60
    let seconds = Int(totalSeconds) % 60

    // Formatting the string as mm:ss
    return String(format: "%02d:%02d", minutes, seconds)
}

struct NowPlayingView: View {
    @EnvironmentObject var playController: PlaylistStatus
    @State private var playlist: [PlaylistItem] = []

    var body: some View {
        Table(of: PlaylistItem.self) {
            TableColumn("Title") { song in
                HStack {
                    Text(song.title)
                    if let nsSong = song.nsSong {
                        if let alia = nsSong.tns?.first ?? nsSong.alia.first {
                            Text("( \(alia) )")
                                .foregroundColor(.secondary)
                        }
                    }
                    if song.id == playController.currentItem?.id {
                        Image(systemName: "speaker.3.fill")
                    }
                }
            }
            TableColumn("Duration") { song in
                Text(formatCMTime(song.duration))
            }.width(max: 60)
        } rows: {
            ForEach(playlist) { item in
                TableRow(item)
                    .contextMenu {
                        Button("Play") {
                            Task {
                                await playController.playBySongId(id: item.id)
                            }
                        }

                        Button("Delete") {
                            Task {
                                await playController.deleteBySongId(id: item.id)
                                playlist = playController.playlist
                            }
                        }
                    }
            }
        }
        .task {
            playlist = playController.playlist
        }
    }
}
