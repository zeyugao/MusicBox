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
        ScrollViewReader { proxy in
            List(playlist) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(item.title)
                                .font(.body)
                            if let nsSong = item.nsSong {
                                if let alia = nsSong.tns?.first ?? nsSong.alia.first {
                                    Text("( \(alia) )")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                }
                            }
                            if item.id == playController.currentItem?.id {
                                Image(systemName: "speaker.3.fill")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                    
                    Spacer()
                    
                    Text(formatCMTime(item.duration))
                        .foregroundColor(.secondary)
                        .font(.caption)
                        .frame(width: 60, alignment: .trailing)
                }
                .padding(.vertical, 2)
                .id(item.id)
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
            .listStyle(PlainListStyle())
            .task {
                playlist = playController.playlist
                // 自动滚动到当前播放的歌曲
                if let currentItem = playController.currentItem {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation(.easeInOut(duration: 0.5)) {
                            proxy.scrollTo(currentItem.id, anchor: .center)
                        }
                    }
                }
            }
            .onChange(of: playController.currentItem) { _, newItem in
                // 当播放的歌曲改变时，也自动滚动到新的歌曲
                if let currentItem = newItem {
                    withAnimation(.easeInOut(duration: 0.5)) {
                        proxy.scrollTo(currentItem.id, anchor: .center)
                    }
                }
            }
        }
    }
}
