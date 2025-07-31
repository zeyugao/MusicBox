//
//  PlayerControlView.swift
//  MusicBox
//
//  Created by Elsa on 2024/4/17.
//

import AVFoundation
import AVKit
import AudioToolbox
import Combine
import CoreAudio
import Foundation
import SwiftUI

struct NowPlayingPopoverView: View {
    @EnvironmentObject private var playlistStatus: PlaylistStatus
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            if playlistStatus.playlist.isEmpty {
                // Header with padding when empty
                VStack(spacing: 12) {
                    HStack {
                        Text("Now Playing")
                            .font(.headline)
                        Spacer()
                        Button(action: {
                            playlistStatus.clearPlaylist()
                        }) {
                            Image(systemName: "trash")
                                .resizable()
                                .frame(width: 14, height: 14)
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(.secondary)
                        .disabled(true)
                        .help("Clear All")
                    }

                    Text("No songs in playlist")
                        .foregroundColor(.secondary)
                        .padding()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 12)
            } else {
                // ScrollView with header inside for proxy access
                ScrollViewReader { proxy in
                    VStack(spacing: 0) {
                        // Header with buttons
                        HStack {
                            Text("Now Playing")
                                .font(.headline)
                            Spacer()
                            Button(action: {
                                scrollToCurrentSong(proxy: proxy)
                            }) {
                                Image(systemName: "dot.circle")
                                    .resizable()
                                    .frame(width: 14, height: 14)
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(.accentColor)
                            .help("Scroll to Current")

                            Button(action: {
                                playlistStatus.clearPlaylist()
                            }) {
                                Image(systemName: "trash")
                                    .resizable()
                                    .frame(width: 14, height: 14)
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(.red)
                            .help("Clear All")
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 16)

                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(
                                    Array(playlistStatus.playlist.enumerated()), id: \.offset
                                ) { index, item in
                                    NowPlayingRowView(
                                        index: index,
                                        item: item,
                                        currentItemIndex: playlistStatus.currentItemIndex,
                                        playlistStatus: playlistStatus
                                    )
                                    .id("song-\(index)")
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 0)
                            .padding(.bottom, 16)
                        }
                        .frame(maxHeight: 400)
                        .onAppear {
                            scrollToCurrentSong(proxy: proxy)
                        }
                        .onChange(of: isPresented) { _, newValue in
                            if newValue {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    scrollToCurrentSong(proxy: proxy)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 400)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func scrollToCurrentSong(proxy: ScrollViewProxy) {
        if let currentIndex = playlistStatus.currentItemIndex {
            proxy.scrollTo("song-\(currentIndex)", anchor: .center)
        }
    }
}

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

struct AudioOutputDeviceButton: View {
    var body: some View {
        AVRoutePickerViewWrapper()
            .frame(width: 16, height: 16)
            .help("Select Audio Output Device")
    }
}

struct AVRoutePickerViewWrapper: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let routePickerView = AVRoutePickerView()

        // Set the delegate to handle route picker events
        routePickerView.delegate = context.coordinator

        // Make sure the button is properly sized
        routePickerView.translatesAutoresizingMaskIntoConstraints = false

        routePickerView.isRoutePickerButtonBordered = false

        // Set button color to match PlayControlButtonStyle
        if #available(macOS 10.15, *) {
            routePickerView.setRoutePickerButtonColor(NSColor.labelColor, for: .normal)
            routePickerView.setRoutePickerButtonColor(
                NSColor.secondaryLabelColor, for: .normalHighlighted)
        }

        return routePickerView
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, AVRoutePickerViewDelegate {
        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            print("Route picker will begin presenting routes")
        }

        func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            print("Route picker did end presenting routes")
        }
    }
}

struct PlaySliderView: View {
    @EnvironmentObject var playStatus: PlayStatus
    @ObservedObject var playbackProgress: PlaybackProgress
    @State private var isEditing: Bool = false
    @State private var targetValue: Double = 0.0
    @State private var lastSeekTime: Date = Date.distantPast

    var body: some View {
        Slider(
            value: Binding(
                get: {
                    guard !self.playStatus.isLoading else {
                        return self.playbackProgress.playedSecond
                    }

                    if self.isEditing || self.playStatus.isSeeking {
                        return targetValue
                    } else {
                        return self.playbackProgress.playedSecond
                    }
                },
                set: {
                    newValue in
                    guard !self.playStatus.isLoading else { return }

                    if isEditing {
                        targetValue = newValue
                    }
                    // 移除这里的 seek 调用，只在 onEditingChanged 中处理
                    // 避免重复调用 seekToOffset
                }
            ),
            in: 0...self.playbackProgress.duration
        ) {
            editing in
            guard !self.playStatus.isLoading else { return }

            // 避免重复回调：只在状态真正改变时处理
            if self.isEditing != editing {
                if !editing {
                    // 防止重复调用：检查距离上次 seek 的时间间隔
                    let now = Date()
                    if now.timeIntervalSince(lastSeekTime) > 0.1 {
                        lastSeekTime = now
                        Task {
                            await self.playStatus.seekToOffset(offset: targetValue)
                        }
                    }
                } else {
                    // 开始编辑时，确保 targetValue 是当前值
                    targetValue = self.playbackProgress.playedSecond
                }
                self.isEditing = editing
            }
        }
        .disabled(self.playStatus.isLoading)
        .controlSize(.mini)
        .tint(.primary)
    }
}

struct PlaybackProgressView: View {
    @ObservedObject var playbackProgress: PlaybackProgress

    func secondsToMinutesAndSeconds(seconds: Double) -> String {
        let seconds_int = Int(seconds)
        let minutes = (seconds_int % 3600) / 60
        let seconds = (seconds_int % 3600) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var body: some View {
        HStack {
            Text(secondsToMinutesAndSeconds(seconds: playbackProgress.playedSecond))
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(Color(nsColor: NSColor.placeholderTextColor))
                .frame(width: 40)

            PlaySliderView(playbackProgress: playbackProgress)

            Text(secondsToMinutesAndSeconds(seconds: playbackProgress.duration))
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(Color(nsColor: NSColor.placeholderTextColor))
                .frame(width: 40)
        }
    }
}

struct PlayerControlView: View {
    @EnvironmentObject var playStatus: PlayStatus
    @EnvironmentObject var playlistStatus: PlaylistStatus
    @EnvironmentObject private var userInfo: UserInfo
    @EnvironmentObject private var playingDetailModel: PlayingDetailModel
    @State var isHovered: Bool = false

    @State var artworkUrl: URL?
    @State private var currentItemId: UInt64?
    @State private var showNowPlayingPopover: Bool = false

    @Binding private var navigationPath: NavigationPath

    let height = 80.0

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
        HStack(spacing: 16) {
            if let url = artworkUrl {
                AsyncImageWithCache(url: url) { image in
                    image.resizable()
                        .scaledToFit()
                        .frame(width: height, height: height)
                } placeholder: {
                    ZStack {
                        Color.gray.opacity(0.2)
                        Image(systemName: "music.note")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 30, height: 30)
                            .foregroundColor(.secondary)
                    }
                    .frame(width: height, height: height)
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
                    .frame(width: 40, height: 40)
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
                ZStack {
                    Color.gray.opacity(0.2)
                    Image(systemName: "music.note")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                        .foregroundColor(.secondary)
                }
                .frame(width: height, height: height)
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
                        .onReceive(NotificationCenter.default.publisher(for: .spaceKeyPressed)) {
                            _ in
                            Task {
                                await playStatus.togglePlayPause()
                            }
                        }
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
                HStack(spacing: 8) {
                    Text("\(playlistStatus.currentItem?.title ?? "Title")")
                        .font(.system(size: 12))
                        .lineLimit(1)

                    if playStatus.isLoadingNewTrack {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                    }
                }
                .padding(.bottom, 1)

                Text("\(playlistStatus.currentItem?.artist ?? "Artists")")
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(Color(nsColor: NSColor.placeholderTextColor))
                    .padding(.bottom, -2)
                PlaybackProgressView(playbackProgress: playStatus.playbackProgress)
                    .environmentObject(playStatus)
                    .frame(maxWidth: 600)
            }
            .layoutPriority(1)
            .frame(minWidth: 240)

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

            // Now Playing Button
            Button(action: {
                showNowPlayingPopover.toggle()
            }) {
                ZStack {
                    Image(systemName: "list.bullet")
                        .resizable()
                        .frame(width: 16, height: 16)
                    
                    // Badge showing play next count
                    if playlistStatus.playNextItemsCount > 0 {
                        Text("\(playlistStatus.playNextItemsCount)")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(minWidth: 12, minHeight: 12)
                            .background(
                                Circle()
                                    .fill(Color.primary)
                            )
                            .offset(x: 10, y: -10)
                    }
                }
            }
            .buttonStyle(PlayControlButtonStyle())
            .foregroundColor(.primary)
            .help("Now Playing")
            .popover(isPresented: $showNowPlayingPopover) {
                NowPlayingPopoverView(isPresented: $showNowPlayingPopover)
                    .environmentObject(playlistStatus)
            }

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

                    AudioOutputDeviceButton()
                        .padding(.leading, 8)
                }
            }
            .padding(.trailing, 32)

        }
        .frame(height: height)
        .frame(minWidth: 800)
        .onAppear {
            #if DEBUG
                print("🎵 PlayerControlView: onAppear triggered")
            #endif
            Task {
                if let item = playlistStatus.currentItem {
                    currentItemId = item.id
                    #if DEBUG
                        print(
                            "🎵 PlayerControlView: onAppear - loading artwork for \(item.title) (ID: \(item.id))"
                        )
                    #endif
                    artworkUrl = await item.getArtworkUrl()
                    #if DEBUG
                        print(
                            "🎵 PlayerControlView: onAppear - artwork URL loaded: \(artworkUrl?.absoluteString ?? "nil")"
                        )
                    #endif
                } else {
                    #if DEBUG
                        print("🎵 PlayerControlView: onAppear - no current item")
                    #endif
                }
            }
        }
        .onChange(of: playlistStatus.currentItem) { oldItem, newItem in
            #if DEBUG
                let timestamp = Date().timeIntervalSince1970
                print("🎵 PlayerControlView: onChange(currentItem) triggered at \(timestamp)")
                print(
                    "🎵 PlayerControlView: oldItem: \(oldItem?.title ?? "nil") (ID: \(oldItem?.id ?? 0))"
                )
                print(
                    "🎵 PlayerControlView: newItem: \(newItem?.title ?? "nil") (ID: \(newItem?.id ?? 0))"
                )
            #endif

            if let item = newItem {
                let newItemId = item.id
                #if DEBUG
                    print(
                        "🎵 PlayerControlView: comparing IDs - current: \(currentItemId ?? 0), new: \(newItemId)"
                    )
                #endif

                // Only update if the item actually changed
                if currentItemId != newItemId {
                    #if DEBUG
                        print(
                            "🎵 PlayerControlView: Item changed! Updating artwork for \(item.title)")
                    #endif
                    currentItemId = newItemId
                    Task {
                        #if DEBUG
                            print(
                                "🎵 PlayerControlView: Starting getArtworkUrl for \(item.title) (ID: \(newItemId))"
                            )
                        #endif
                        let newArtworkUrl = await item.getArtworkUrl()
                        #if DEBUG
                            print(
                                "🎵 PlayerControlView: getArtworkUrl completed: \(newArtworkUrl?.absoluteString ?? "nil")"
                            )
                        #endif

                        // Only update if this is still the current item (avoid race conditions)
                        if currentItemId == newItemId {
                            #if DEBUG
                                print(
                                    "🎵 PlayerControlView: Setting artworkUrl to: \(newArtworkUrl?.absoluteString ?? "nil")"
                                )
                            #endif
                            artworkUrl = newArtworkUrl
                        } else {
                            #if DEBUG
                                print(
                                    "🎵 PlayerControlView: Race condition detected! Item changed while loading. Current: \(currentItemId ?? 0), Expected: \(newItemId)"
                                )
                            #endif
                        }
                    }
                } else {
                    #if DEBUG
                        print("🎵 PlayerControlView: Same item, no update needed")
                    #endif
                }
            } else {
                #if DEBUG
                    print("🎵 PlayerControlView: New item is nil, clearing artwork")
                #endif
                currentItemId = nil
                artworkUrl = nil
            }
        }
        .onChange(of: playlistStatus.currentItem?.id) { oldId, newId in
            #if DEBUG
                print(
                    "🎵 PlayerControlView: onChange(currentItem.id) triggered - oldId: \(oldId ?? 0), newId: \(newId ?? 0)"
                )
            #endif

            // Additional trigger when currentItem ID changes (for edge cases)
            if let item = playlistStatus.currentItem,
                let newId = newId,
                currentItemId != newId
            {
                #if DEBUG
                    print(
                        "🎵 PlayerControlView: ID-based change detected! Updating for \(item.title) (ID: \(newId))"
                    )
                #endif
                currentItemId = newId
                Task {
                    #if DEBUG
                        print(
                            "🎵 PlayerControlView: ID-based getArtworkUrl starting for \(item.title)"
                        )
                    #endif
                    let newArtworkUrl = await item.getArtworkUrl()
                    #if DEBUG
                        print(
                            "🎵 PlayerControlView: ID-based getArtworkUrl completed: \(newArtworkUrl?.absoluteString ?? "nil")"
                        )
                    #endif

                    // Only update if this is still the current item
                    if currentItemId == newId {
                        #if DEBUG
                            print(
                                "🎵 PlayerControlView: ID-based setting artworkUrl to: \(newArtworkUrl?.absoluteString ?? "nil")"
                            )
                        #endif
                        artworkUrl = newArtworkUrl
                    } else {
                        #if DEBUG
                            print(
                                "🎵 PlayerControlView: ID-based race condition! Current: \(currentItemId ?? 0), Expected: \(newId)"
                            )
                        #endif
                    }
                }
            } else {
                #if DEBUG
                    print("🎵 PlayerControlView: ID-based change - no action needed")
                #endif
            }
        }
    }
}

struct NowPlayingRowView: View {
    let index: Int
    let item: PlaylistItem
    let currentItemIndex: Int?
    let playlistStatus: PlaylistStatus
    @State private var isHovered: Bool = false
    
    var body: some View {
        HStack {
            // Current playing indicator or position
            if index == currentItemIndex {
                Image(systemName: "speaker.3.fill")
                    .foregroundColor(.accentColor)
                    .frame(width: 20)
                    .font(.caption)
            } else {
                Text("\(index + 1)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 20)
            }

            // Song info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.body)
                        .lineLimit(1)
                        .foregroundColor(
                            index == currentItemIndex
                                ? .accentColor : .primary)
                    
                    // Play next indicator
                    if let currentIndex = currentItemIndex,
                        index > currentIndex
                            && index <= currentIndex
                                + playlistStatus.playNextItemsCount
                    {
                        Text("Next \(index - currentIndex)")
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(4)
                    }
                }
                Text(item.artist)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Play Next button (only show for non-current items, on hover, and not already in play next queue)
            if index != currentItemIndex && isHovered {
                let isInPlayNextQueue = {
                    guard let currentIndex = currentItemIndex else { return false }
                    return index > currentIndex && index <= currentIndex + playlistStatus.playNextItemsCount
                }()
                
                if !isInPlayNextQueue {
                    Button(action: {
                        Task {
                            await playlistStatus.addToPlayNext(item)
                        }
                    }) {
                        Image(systemName: "text.badge.plus")
                            .foregroundColor(.orange)
                    }
                    .buttonStyle(.borderless)
                    .help("Play Next")
                }
            }

            // Remove button (only show on hover)
            if isHovered {
                Button(action: {
                    Task {
                        await playlistStatus.deleteBySongId(id: item.id)
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    index == currentItemIndex
                        ? Color.accentColor.opacity(0.1)
                        : Color.gray.opacity(0.05))
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            Task {
                await playlistStatus.playBySongId(id: item.id)
            }
        }
    }
}

//#Preview {
//    PlayerControlView()
//}
