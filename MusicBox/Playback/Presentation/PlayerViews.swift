import AppKit
import AVKit
import SwiftUI

struct PlayerCapsuleView: View {
    @Environment(AppModel.self) private var app
    @State private var isQueuePresented = false
    @State private var isVolumePresented = false
    @State private var isSeeking = false
    @State private var seekTarget = 0.0

    var body: some View {
        @Bindable var router = app.router
        let playback = app.playbackPresentation
        HStack(spacing: 24) {
            HStack(spacing: 16) {
                playerButton("backward.fill", size: 14, help: "Previous") { playback.previous() }
                playerButton(playback.isPlaying ? "pause.fill" : "play.fill", size: 16, help: playback.isPlaying ? "Pause" : "Play") {
                    playback.toggle()
                }
                .disabled(!playback.hasCurrentItem || playback.isLoading)
                .keyboardShortcut(.space, modifiers: [])
                .frame(width: 20, height: 20)
                playerButton("forward.fill", size: 14, help: "Next") { playback.next() }
                playerButton(modeIcon(playback.mode), size: 16, help: "Repeat 1") { playback.cycleMode() }
            }

            NowPlayingTrackPresentation(
                playback: playback,
                isSeeking: $isSeeking,
                seekTarget: $seekTarget
            )

            HStack(spacing: 16) {
                Button {
                    isQueuePresented.toggle()
                } label: {
                    ZStack {
                        Image(systemName: "list.bullet")
                            .resizable()
                            .frame(width: 16, height: 14)
                        if playback.explicitNextCount > 0 {
                            Text("\(playback.explicitNextCount)")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(minWidth: 12, minHeight: 12)
                                .background(Circle().fill(Color.primary))
                                .offset(x: 10, y: -10)
                        }
                    }
                }
                .buttonStyle(PlayerControlButtonStyle())
                .help("Now Playing")
                .popover(isPresented: $isQueuePresented) {
                    QueuePopoverView(isPresented: $isQueuePresented)
                }

                Button {
                    isVolumePresented.toggle()
                } label: {
                    Image(systemName: volumeIcon(playback.volume))
                        .resizable()
                        .frame(width: 16, height: 14)
                }
                .buttonStyle(PlayerControlButtonStyle())
                .help("Volume")
                .popover(isPresented: $isVolumePresented) {
                    VolumePopoverView(isPresented: $isVolumePresented)
                }

                AudioOutputDeviceButton()

                Button {
                    router.isLyricsPresented.toggle()
                } label: {
                    Image(systemName: "quote.bubble")
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(PlayerControlButtonStyle(color: router.isLyricsPresented ? .accentColor : .primary))
                .help(router.isLyricsPresented ? "Hide Lyrics" : "Show Lyrics")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: PlayerOverlayMetrics.height)
        .background(Color.gray.opacity(0.005))
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .frame(minWidth: 100, maxWidth: 600)
        .glassEffect()
    }

    private func playerButton(_ icon: String, size: CGFloat, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .resizable()
                .frame(width: size, height: size)
        }
        .buttonStyle(PlayerControlButtonStyle())
        .help(help)
    }

    private func modeIcon(_ mode: PlaybackMode) -> String {
        switch mode {
        case .repeatAll: return "repeat"
        case .shuffle: return "shuffle"
        case .repeatOne: return "repeat.1"
        }
    }

    private func volumeIcon(_ volume: Float) -> String {
        switch volume {
        case 0: return "speaker.slash.fill"
        case ..<0.33: return "speaker.wave.1.fill"
        case ..<0.66: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

}

private struct NowPlayingTrackPresentation: View {
    @Environment(AppModel.self) private var app
    let playback: PlaybackPresentationModel
    @Binding var isSeeking: Bool
    @Binding var seekTarget: Double

    var body: some View {
        VStack(alignment: .leading, spacing: PlayerOverlayMetrics.trackLayoutPadding) {
            HStack(spacing: 8) {
                artwork
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(playback.currentItem?.title ?? "Title")
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        if playback.isLoading {
                            ProgressView()
                                .scaleEffect(0.3)
                                .frame(width: 8, height: 8)
                        }
                        Spacer()
                        if let item = playback.currentItem {
                            Button {
                                Task {
                                    let liked = app.account.likedSongIDs.contains(item.id)
                                    do {
                                        try await app.account.setLiked(item.id, liked: !liked)
                                    } catch {
                                        app.alerts.show(error.localizedDescription)
                                    }
                                }
                            } label: {
                                Image(systemName: app.account.likedSongIDs.contains(item.id) ? "heart.fill" : "heart")
                                    .resizable()
                                    .frame(width: 10, height: 9)
                            }
                            .buttonStyle(PlayerControlButtonStyle(color: app.account.likedSongIDs.contains(item.id) ? .accentColor : .secondary))
                            .help(app.account.likedSongIDs.contains(item.id) ? "Unfavor" : "Favor")

                            Menu {
                                Button("查看评论") {
                                    CommentsWindowManager.shared.show(
                                        target: CommentsTarget(
                                            kind: .song,
                                            resourceID: item.id,
                                            name: item.title,
                                            subtitle: item.artist
                                        )
                                    )
                                }
                                if let source = item.sourcePlaylist {
                                    Divider()
                                    Button("定位到歌单") {
                                        app.router.showPlaylist(
                                            PlaylistDestination(id: source.id, name: source.name),
                                            songID: item.id
                                        )
                                    }
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 14, height: 12)
                            }
                            .menuIndicator(.hidden)
                            .menuStyle(.borderlessButton)
                            .buttonStyle(PlayerControlButtonStyle(color: .secondary))
                            .help("更多")
                        }
                    }
                    HStack(spacing: 6) {
                        Text(playback.currentItem?.artist ?? "Artists")
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .foregroundStyle(Color(nsColor: .placeholderTextColor))
                        Spacer(minLength: 4)
                        Text("\(clock(playback.position)) / \(clock(playback.duration))")
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: PlayerOverlayMetrics.trackInfoHeight)

            Slider(
                value: Binding(
                    get: { isSeeking ? seekTarget : playback.position },
                    set: { seekTarget = $0 }
                ),
                in: 0...max(1, playback.duration),
                onEditingChanged: { editing in
                    isSeeking = editing
                    if editing {
                        seekTarget = playback.position
                    } else {
                        playback.seek(to: seekTarget)
                    }
                }
            )
            .disabled(!playback.hasCurrentItem || playback.isLoading)
            .controlSize(.mini)
            .tint(.secondary)
            .sliderThumbVisibility(.hidden)
            .frame(height: PlayerOverlayMetrics.trackSliderHeight)
        }
        .padding(.top, PlayerOverlayMetrics.trackVisualPadding)
        .padding(.bottom, PlayerOverlayMetrics.trackLayoutPadding)
        .frame(height: PlayerOverlayMetrics.height)
    }

    @ViewBuilder
    private var artwork: some View {
        if let url = playback.currentItem?.artworkUrl {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                artworkPlaceholder
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            artworkPlaceholder
        }
    }

    private var artworkPlaceholder: some View {
        ZStack {
            Color.gray.opacity(0.2)
            Image(systemName: "music.note")
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(.secondary)
        }
        .frame(width: 32, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct PlayerControlButtonStyle: ButtonStyle {
    var color: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(color ?? (configuration.isPressed ? Color.secondary : Color.primary))
    }
}

private struct VolumePopoverView: View {
    @Environment(AppModel.self) private var app
    @Binding var isPresented: Bool

    var body: some View {
        Slider(
            value: Binding(
                get: { Double(app.playbackPresentation.volume) },
                set: { app.playbackPresentation.setVolume(Float($0)) }
            ),
            in: 0...1,
            label: { EmptyView() },
            minimumValueLabel: { Image(systemName: "speaker.fill") },
            maximumValueLabel: { Image(systemName: "speaker.wave.3.fill") }
        )
        .controlSize(.mini)
        .padding(12)
        .frame(width: 160)
    }
}

private struct QueuePopoverView: View {
    @Environment(AppModel.self) private var app
    @Binding var isPresented: Bool

    var body: some View {
        let playback = app.playbackPresentation
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack {
                    Text("Now Playing")
                        .font(.headline)
                    Spacer()
                    Button {
                        if let current = playback.queueEntries.first(where: \.isCurrent) {
                            proxy.scrollTo(current.id, anchor: .center)
                        }
                    } label: {
                        Image(systemName: "dot.circle")
                            .resizable()
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                    .help("Scroll to Current")
                    Button {
                        playback.clearQueue()
                        isPresented = false
                    } label: {
                        Image(systemName: "trash")
                            .resizable()
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .help("Clear All")
                    .disabled(playback.queueEntries.isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)

                if playback.queueEntries.isEmpty {
                    Text("No songs in playlist")
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 20)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(playback.queueEntries) { entry in
                                QueueRow(entry: entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }
                    .frame(maxHeight: 400)
                    .onAppear {
                        if let current = playback.queueEntries.first(where: \.isCurrent) {
                            proxy.scrollTo(current.id, anchor: .center)
                        }
                    }
                }
            }
            .frame(width: 400)
        }
    }
}

private struct QueueRow: View {
    @Environment(AppModel.self) private var app
    let entry: QueueDisplayEntry
    @State private var isHovering = false
    @State private var showButtons = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(entry.item.title)
                        .font(.body)
                        .lineLimit(1)
                        .foregroundStyle(entry.isCurrent ? Color.accentColor : Color.primary)
                    if let position = entry.explicitNextPosition {
                        Text("Next \(position)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text(entry.item.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if entry.isCurrent {
                Image(systemName: "speaker.3.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
            } else if showButtons {
                if !entry.isExplicitNext {
                    Button {
                        app.playbackPresentation.enqueueNext(entry.item)
                    } label: {
                        Image(systemName: "text.badge.plus")
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.borderless)
                    .help("Play Next")
                }
                Button {
                    app.playbackPresentation.remove(entryID: entry.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(entry.isCurrent ? Color.accentColor.opacity(0.1) : Color.gray.opacity(0.05))
        )
        .contentShape(Rectangle())
        .onTapGesture { app.playbackPresentation.play(entryID: entry.id) }
        .onHover { hovering in
            isHovering = hovering
            hoverTask?.cancel()
            if hovering {
                hoverTask = Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, isHovering else { return }
                    showButtons = true
                }
            } else {
                showButtons = false
            }
        }
        .onDisappear { hoverTask?.cancel() }
    }
}

private struct AudioOutputDeviceButton: View {
    var body: some View {
        AVRoutePickerViewWrapper()
            .frame(width: 16, height: 16)
            .help("Select Audio Output Device")
    }
}

private struct AVRoutePickerViewWrapper: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let routePicker = AVRoutePickerView()
        routePicker.isRoutePickerButtonBordered = false
        routePicker.setRoutePickerButtonColor(.labelColor, for: .normal)
        routePicker.setRoutePickerButtonColor(.labelColor, for: .normalHighlighted)
        return routePicker
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

struct LyricsInspectorView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let lyrics = app.playbackPresentation.lyrics
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading) {
                    if lyrics.lines.isEmpty, !lyrics.isLoading {
                        Text("还没有歌词")
                            .foregroundStyle(.secondary)
                            .padding(16)
                    }
                    ForEach(lyrics.lines.indices, id: \.self) { index in
                        let line = lyrics.lines[index]
                        let isCurrent = lyrics.currentIndex == index
                        VStack(alignment: .leading) {
                            if app.settings.showTimestamp {
                                Text(timestamp(line.time))
                                    .lineLimit(1)
                                    .font(.footnote)
                                    .foregroundStyle(.gray)
                            }
                            if app.settings.showRoma, let roma = line.romalrc, !roma.isEmpty {
                                Text(roma)
                                    .font(.body)
                                    .foregroundStyle(isCurrent ? .primary : Color(nsColor: .placeholderTextColor))
                            }
                            Text(line.lyric)
                                .font(.title3)
                                .foregroundStyle(isCurrent ? .primary : Color(nsColor: .placeholderTextColor))
                                .id(index)
                            if let translation = line.tlyric, !translation.isEmpty {
                                Text(translation)
                                    .font(.title3)
                                    .foregroundStyle(isCurrent ? .primary : Color(nsColor: .placeholderTextColor))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 12)
            }
            .onChange(of: lyrics.currentIndex) { _, index in
                if let index {
                    withAnimation(.spring) { proxy.scrollTo(index, anchor: .center) }
                }
            }
            .onChange(of: lyrics.scrollResetToken) { _, _ in
                withAnimation(.spring) { proxy.scrollTo(0, anchor: .top) }
            }
        }
        .navigationTitle(app.playbackPresentation.currentItem?.title ?? "Playing")
    }

    private func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00.00" }
        let hundredths = max(0, Int((seconds * 100).rounded()))
        return String(format: "%02d:%02d.%02d", hundredths / 6_000, (hundredths % 6_000) / 100, hundredths % 100)
    }
}
