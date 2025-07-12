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

    var body: some View {
        ScrollViewReader { proxy in
            List(playController.playlist) { item in
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
                        }
                    }
                }
            }
            .listStyle(PlainListStyle())
            .task {
                // 自动滚动到当前播放的歌曲
                scrollToCurrentItem(proxy: proxy)
            }
            .onChange(of: playController.playlist) { _, _ in
                // 当播放列表改变时，重新滚动到当前歌曲
                scrollToCurrentItem(proxy: proxy)
            }
            .onChange(of: playController.currentItem) { _, _ in
                // 当播放的歌曲改变时，也自动滚动到新的歌曲
                scrollToCurrentItem(proxy: proxy)
            }
        }
    }

    private func scrollToCurrentItem(proxy: ScrollViewProxy) {
        guard let currentItem = playController.currentItem else { return }

        // 验证当前项是否在播放列表中
        guard playController.playlist.contains(where: { $0.id == currentItem.id }) else {
            print("Warning: Current item not found in playlist")
            return
        }

        // 使用多重延迟确保布局完成后再滚动，提高滚动准确性
        DispatchQueue.main.async {
            // 第三次尝试：进一步延迟，处理布局变化的情况
            DispatchQueue.main.async {
                proxy.scrollTo(currentItem.id, anchor: .center)
            }
        }
    }
}
