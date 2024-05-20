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
    @EnvironmentObject var playController: PlayController
    @State private var isEditing: Bool = false
    @State private var targetValue: Double = 0.0

    var body: some View {
        Slider(
            value: Binding(
                get: {
                    if self.isEditing {
                        return targetValue
                    } else {
                        return self.playController.playedSecond
                    }
                },
                set: {
                    newValue in
                    if isEditing {
                        targetValue = newValue
                    } else {
                        self.playController.seekToOffset(offset: newValue)
                    }
                }
            ),
            in: 0...self.playController.duration
        ) {
            editing in
            if !editing && self.isEditing != editing {
                self.playController.seekToOffset(offset: targetValue)
            }
            self.isEditing = editing
        }

        .controlSize(.mini)
        .tint(Color(red: 0.745, green: 0.745, blue: 0.745))

    }
}

struct PlayerControlView: View {
    @EnvironmentObject var playController: PlayController
    @EnvironmentObject private var userInfo: UserInfo
    @State var errorText: String = ""

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
                if let currentItem = playController.currentItem,
                    let url = currentItem.getArtwork()
                {
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
                    .onTapGesture {
                        PlayingDetailModel.openPlayingDetail()
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
                            Task { await playController.previousTrack() }
                        }) {
                            Image(systemName: "backward.fill")
                                .resizable()
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(PlayControlButtonStyle())

                        if playController.isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                                .frame(width: 20, height: 20)
                        } else {
                            Button(action: {
                                Task { await playController.togglePlayPause() }
                            }) {
                                Image(
                                    systemName: playController.isPlaying
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
                            Task { await playController.nextTrack() }
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
                    Text("\(playController.currentItem?.title ?? "Title")")
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .padding(.bottom, 1)
                    Text("\(playController.currentItem?.artist ?? "Artists")")
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .foregroundStyle(Color(red: 0.745, green: 0.745, blue: 0.745))
                        .padding(.bottom, -2)
                    HStack {
                        Text(secondsToMinutesAndSeconds(seconds: playController.playedSecond))
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .foregroundStyle(Color(red: 0.745, green: 0.745, blue: 0.745))
                            .frame(width: 40)

                        PlaySliderView()
                            .environmentObject(playController)

                        Text(secondsToMinutesAndSeconds(seconds: playController.duration))
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .foregroundStyle(Color(red: 0.745, green: 0.745, blue: 0.745))
                            .frame(width: 40)
                    }
                }
                .layoutPriority(1)
                .frame(minWidth: 300)
                // .padding(.vertical, 16)

                Spacer()

                let currentId = playController.currentItem?.id ?? 0
                let favored = (userInfo.likelist.contains(currentId))
                Button(action: {
                    guard currentId != 0 else { return }
                    Task {
                        var likelist = userInfo.likelist
                        await likeSong(
                            likelist: &likelist,
                            songId: currentId,
                            favored: favored,
                            errorText: $errorText
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
                    playController.switchToNextLoopMode()
                }) {
                    Image(
                        systemName: playController.loopMode == .once
                            ? "repeat.1"
                            : (playController.loopMode == .sequence ? "repeat" : "shuffle")
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
                                    playController.volume
                                },
                                set: {
                                    playController.volume = $0
                                }
                            ),
                            in: 0...1
                        ) {
                        } minimumValueLabel: {
                            Image(systemName: "speaker.fill")
                        } maximumValueLabel: {
                            Image(systemName: "speaker.3.fill")
                        }
                        .frame(width: 100)
                        .controlSize(.mini)
                        .tint(Color(red: 0.678, green: 0.678, blue: 0.678))
                    }
                }
                .padding(.trailing, 32)

            }
            .alert(
                isPresented: Binding<Bool>(
                    get: { !errorText.isEmpty },
                    set: { if !$0 { errorText = "" } }
                )
            ) {
                Alert(title: Text("Error"), message: Text(errorText))
            }
        }
    }
}

//#Preview {
//    PlayerControlView()
//}
