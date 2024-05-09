//
//  PlayerControlView.swift
//  MusicBox
//
//  Created by Elsa on 2024/4/17.
//

import Foundation
import SwiftUI

private struct PlayControlButtonStyle: ButtonStyle {
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
    //    @State private var shouldSyncOffset: Bool = false

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

    func secondsToMinutesAndSeconds(seconds: Double) -> String {
        let seconds_int = Int(seconds)
        let minutes = (seconds_int % 3600) / 60
        let seconds = (seconds_int % 3600) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 32) {
                Button(action: {}) {
                    Image(systemName: "shuffle")
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(BorderlessButtonStyle())
                .foregroundColor(.primary)

                HStack(spacing: 24) {
                    Button(action: {}) {
                        Image(systemName: "backward.fill")
                            .resizable()
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(PlayControlButtonStyle())

                    //   Button(action: {}) {
                    //     Image(systemName: "play.fill")
                    //       .resizable()
                    //       .frame(width: 20, height: 20)
                    //   }
                    //   .buttonStyle(PlayControlButtonStyle())
                    Button(action: {
                        playController.togglePlayPause()
                    }) {
                        Image(systemName: playController.isPlaying ? "pause.fill" : "play.fill")
                            .resizable()
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(PlayControlButtonStyle())

                    Button(action: {}) {
                        Image(systemName: "forward.fill")
                            .resizable()
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(PlayControlButtonStyle())
                }

                Button(action: {}) {
                    Image(systemName: "repeat")
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(BorderlessButtonStyle())
                .foregroundColor(.primary)
            }
            .padding(.leading, 16)

            Spacer()

            VStack {
                Text("\(playController.sampleBufferPlayer.currentItem?.title ?? "Title")")
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .padding(.bottom, 2)
                Text("\(playController.sampleBufferPlayer.currentItem?.artist ?? "Artists")")
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(Color(red: 0.745, green: 0.745, blue: 0.745))
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

            Spacer()

            HStack(spacing: 32) {
                HStack {
                    Slider(
                        value: .constant(0.5)
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

        }
        .padding()
    }
}

#Preview {
    PlayerControlView()
}
