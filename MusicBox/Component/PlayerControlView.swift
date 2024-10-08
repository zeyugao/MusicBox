//
//  PlayerControlView.swift
//  MusicBox
//
//  Created by Elsa on 2024/4/17.
//

import Foundation
import SwiftUI

struct PlayControlButtonStyle: ButtonStyle {
    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        let color: Color = configuration.isPressed ? .secondary : .primary

        configuration.label
            .foregroundStyle(color)
    }
}

struct PlayControlButton: View {
    var iconName: String  // 可以根据需要传入不同的图标名称
    var action: () -> Void  // 点击按钮时要执行的动作
    @State private var isPressed = false  // 按钮默认颜色

    var body: some View {
        Button(action: action) {
            Image(systemName: iconName)
                .resizable()
                .frame(width: 16, height: 16)
        }
        .buttonStyle(PlayControlButtonStyle())
    }
}

struct PlaySliderView: View {
    @EnvironmentObject var playStatus: PlayStatus
    @State private var isEditing: Bool = false
    @State private var targetValue: Double = 0.0

    var body: some View {
        Slider(
            value: Binding(
                get: {
                    guard !self.playStatus.isLoading else {
                        return self.playStatus.playedSecond
                    }

                    if self.isEditing {
                        return targetValue
                    } else {
                        return self.playStatus.playedSecond
                    }
                },
                set: {
                    newValue in
                    guard !self.playStatus.isLoading else { return }

                    if isEditing {
                        targetValue = newValue
                    } else {
                        Task {
                            await self.playStatus.seekToOffset(offset: newValue)
                        }
                    }
                }
            ),
            in: 0...self.playStatus.duration
        ) {
            editing in
            guard !self.playStatus.isLoading else { return }

            if !editing && self.isEditing != editing {
                Task {
                    await self.playStatus.seekToOffset(offset: targetValue)
                }
            }
            self.isEditing = editing
        }
        .disabled(self.playStatus.isLoading)
        .controlSize(.mini)
        .tint(.primary)
    }
}

struct PlayerControlView: View {
    @EnvironmentObject var playStatus: PlayStatus
    @EnvironmentObject var playlistStatus: PlaylistStatus
    @EnvironmentObject private var userInfo: UserInfo
    @EnvironmentObject private var playingDetailModel: PlayingDetailModel
    @State var isHovered: Bool = false

    @State var artworkUrl: URL?

    @Binding private var navigationPath: NavigationPath

    init(navigationPath: Binding<NavigationPath>) {
        _navigationPath = navigationPath
    }

    func secondsToMinutesAndSeconds(seconds: Double) -> String {
        let seconds_int = Int(seconds)
        let minutes = (seconds_int % 3600) / 60
        let seconds = (seconds_int % 3600) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            HStack(spacing: 16) {
                if let url = artworkUrl {
                    AsyncImage(url: url) { image in
                        image.resizable()
                            .scaledToFit()
                            .frame(width: height, height: height)
                    } placeholder: {
                        Image(systemName: "music.note")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 30, height: 30)
                            .padding()
                            .frame(width: height, height: height)
                            .background(Color.gray.opacity(0.2))
                    }
                    .overlay(
                        Group {
                            if isHovered {
                                Color.gray.opacity(0.4)
                                    .transition(.opacity)
                                    .animation(.easeInOut, value: isHovered)
                            }
                        }
                    )
                    .overlay(
                        Image(
                            systemName: playingDetailModel.isPresented
                                ? "rectangle.compress.vertical" : "rectangle.expand.vertical"
                        )
                        .resizable()
                        .scaledToFit()
                        .frame(width: height * 0.5, height: height * 0.5)
                        .foregroundColor(Color.white.opacity(isHovered ? 1.0 : 0)),
                        alignment: .center
                    )
                    .onHover { hovering in
                        isHovered = hovering
                    }
                    .onTapGesture {
                        playingDetailModel.togglePlayingDetail(navigationPath: &navigationPath)
                    }
                } else {
                    Image(systemName: "music.note")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                        .padding()
                        .frame(width: height, height: height)
                        .background(Color.gray.opacity(0.2))
                }

                HStack(spacing: 32) {

                    HStack(spacing: 24) {
                        Button(action: {
                            Task { await playlistStatus.previousTrack() }
                        }) {
                            Image(systemName: "backward.fill")
                                .resizable()
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(PlayControlButtonStyle())

                        if !playStatus.readyToPlay {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                                .frame(width: 20, height: 20)
                        } else {
                            Button(action: {
                                Task {
                                    await playStatus.togglePlayPause()
                                }
                            }) {
                                Image(
                                    systemName: playStatus.playerState == .playing
                                        ? "pause.fill" : "play.fill"
                                )
                                .resizable()
                                .frame(width: 20, height: 20)
                            }
                            .keyboardShortcut(.space, modifiers: [])
                            .buttonStyle(PlayControlButtonStyle())
                            .frame(width: 20, height: 20)
                        }

                        Button(action: {
                            Task { await playlistStatus.nextTrack() }
                        }) {
                            Image(systemName: "forward.fill")
                                .resizable()
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(PlayControlButtonStyle())
                    }
                }
                .padding(.leading, 16)

                Spacer()

                VStack {
                    Text("\(playlistStatus.currentItem?.title ?? "Title")")
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .padding(.bottom, 1)
                    Text("\(playlistStatus.currentItem?.artist ?? "Artists")")
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .foregroundStyle(Color(nsColor: NSColor.placeholderTextColor))
                        .padding(.bottom, -2)
                    HStack {
                        Text(secondsToMinutesAndSeconds(seconds: playStatus.playedSecond))
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .foregroundStyle(Color(nsColor: NSColor.placeholderTextColor))
                            .frame(width: 40)

                        PlaySliderView()
                            .environmentObject(playStatus)

                        Text(secondsToMinutesAndSeconds(seconds: playStatus.duration))
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .foregroundStyle(Color(nsColor: NSColor.placeholderTextColor))
                            .frame(width: 40)
                    }
                }
                .layoutPriority(1)
                .frame(minWidth: 300)

                Spacer()

                let currentId = playlistStatus.currentItem?.id ?? 0
                let favored = (userInfo.likelist.contains(currentId))
                Button(action: {
                    guard currentId != 0 else { return }
                    Task {
                        var likelist = userInfo.likelist
                        await likeSong(
                            likelist: &likelist,
                            songId: currentId,
                            favored: favored
                        )
                        userInfo.likelist = likelist
                    }
                }) {
                    Image(systemName: favored ? "heart.fill" : "heart")
                        .resizable()
                        .frame(width: 16, height: 14)
                        .help(favored ? "Unfavor" : "Favor")
                        .padding(.trailing, 4)
                }
                .buttonStyle(PlayControlButtonStyle())

                Button(action: {
                    playlistStatus.switchToNextLoopMode()
                }) {
                    Image(
                        systemName: playlistStatus.loopMode == .once
                            ? "repeat.1"
                            : (playlistStatus.loopMode == .sequence ? "repeat" : "shuffle")
                    )
                    .resizable()
                    .frame(width: 16, height: 16)
                }
                .buttonStyle(PlayControlButtonStyle())
                .foregroundColor(.primary)
                .padding(.trailing, 16)

                HStack(spacing: 32) {
                    HStack {
                        Slider(
                            value: Binding(
                                get: {
                                    playStatus.volume
                                },
                                set: {
                                    playStatus.volume = $0
                                }
                            ),
                            in: 0...1
                        ) {
                        } minimumValueLabel: {
                            Image(systemName: "speaker.fill")
                        } maximumValueLabel: {
                            Image(systemName: "speaker.3.fill")
                        }
                        .tint(.primary)
                        .frame(width: 100)
                        .controlSize(.mini)
                    }
                }
                .padding(.trailing, 32)

            }
            .onAppear {
                Task {
                    artworkUrl = await playlistStatus.currentItem?.getArtworkUrl()
                }
            }
            .onChange(of: playlistStatus.currentItem) { _, item in
                if let item = item {
                    Task {
                        artworkUrl = await item.getArtworkUrl()
                    }
                }
            }
        }
    }
}

//#Preview {
//    PlayerControlView()
//}
