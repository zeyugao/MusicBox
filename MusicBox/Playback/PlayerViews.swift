import SwiftUI

struct PlayerCapsuleView: View {
    @Environment(AppModel.self) private var app
    @State private var isQueuePresented = false

    var body: some View {
        @Bindable var router = app.router
        let state = app.playback.state
        HStack(spacing: 12) {
            Button {
                router.isLyricsPresented = true
            } label: {
                artwork(for: state.currentItem)
            }
            .buttonStyle(.plain)
            .disabled(state.currentItem == nil)
            .help(String(localized: "player.show_lyrics"))

            VStack(alignment: .leading, spacing: 2) {
                Text(state.currentItem?.title ?? String(localized: "player.nothing_playing"))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(state.currentItem?.artist ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 100, idealWidth: 180, maxWidth: 220, alignment: .leading)

            Slider(
                value: Binding(
                    get: { state.position },
                    set: { app.playback.seek(to: $0) }
                ),
                in: 0...max(1, state.duration)
            )
            .frame(minWidth: 90, maxWidth: .infinity)
            .disabled(state.currentItem == nil)
            .accessibilityLabel(String(localized: "player.seek"))

            if app.settings.showTimestamp {
                Text(timeText(state.position))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }

            HStack(spacing: 8) {
                iconButton("backward.fill", help: "player.previous") { app.playback.previous() }
                    .disabled(state.currentItem == nil)
                iconButton(state.isPlaying ? "pause.fill" : "play.fill", help: state.isPlaying ? "player.pause" : "player.play") {
                    app.playback.toggle()
                }
                .disabled(state.currentItem == nil || state.isLoading)
                iconButton("forward.fill", help: "player.next") { app.playback.next() }
                    .disabled(state.currentItem == nil)
                iconButton(modeIcon(state.mode), help: "player.cycle_mode") { app.playback.cycleMode() }
                    .disabled(state.currentItem == nil)
            }

            Menu {
                Slider(
                    value: Binding(
                        get: { Double(state.volume) },
                        set: { app.playback.setVolume(Float($0)) }
                    ),
                    in: 0...1
                )
                .frame(width: 150)
            } label: {
                Image(systemName: state.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .menuStyle(.borderlessButton)
            .help(String(localized: "player.volume"))

            Button {
                isQueuePresented.toggle()
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "list.bullet")
                    if state.upcomingCount > 0 {
                        Text(state.upcomingCount, format: .number)
                            .font(.system(size: 8, weight: .bold))
                            .padding(3)
                            .background(.red, in: Circle())
                            .foregroundStyle(.white)
                            .offset(x: 8, y: -7)
                    }
                }
            }
            .buttonStyle(.borderless)
            .help(String(localized: "player.queue"))
            .popover(isPresented: $isQueuePresented, arrowEdge: .bottom) {
                QueuePopoverView(isPresented: $isQueuePresented)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: PlayerOverlayMetrics.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }

    @ViewBuilder
    private func artwork(for item: PlaylistItem?) -> some View {
        if let url = item?.artworkUrl {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            Image(systemName: "music.note")
                .frame(width: 36, height: 36)
                .foregroundStyle(.secondary)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
        }
    }

    private func iconButton(_ image: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .help(String(localized: String.LocalizationValue(help)))
    }

    private func modeIcon(_ mode: PlaybackMode) -> String {
        switch mode {
        case .repeatAll: return "repeat"
        case .shuffle: return "shuffle"
        case .repeatOne: return "repeat.1"
        }
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let minutes = Int(seconds) / 60
        return String(format: "%d:%02d", minutes, Int(seconds) % 60)
    }
}

private struct QueuePopoverView: View {
    @Environment(AppModel.self) private var app
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "queue.title"))
                    .font(.headline)
                Spacer()
                Button {
                    app.playback.clearQueue()
                    isPresented = false
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "queue.clear"))
                .disabled(app.playback.state.visibleEntries.isEmpty)
            }
            .padding(12)

            Divider()

            if app.playback.state.visibleEntries.isEmpty {
                ContentUnavailableView(String(localized: "queue.empty"), systemImage: "music.note.list")
                    .frame(width: 330, height: 180)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(app.playback.state.visibleEntries) { entry in
                            QueueRow(entry: entry)
                        }
                    }
                }
                .frame(width: 360, height: 360)
            }
        }
    }
}

private struct QueueRow: View {
    @Environment(AppModel.self) private var app
    let entry: PlaybackQueueEntry

    var body: some View {
        Button {
            app.playback.play(entryID: entry.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: app.playback.state.currentEntry?.id == entry.id ? "speaker.wave.2.fill" : "music.note")
                    .foregroundStyle(app.playback.state.currentEntry?.id == entry.id ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.item.title)
                        .lineLimit(1)
                    Text(entry.item.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(String(localized: "queue.play_next")) {
                app.playback.enqueueNext(entry.item)
            }
            Button(String(localized: "action.remove"), role: .destructive) {
                app.playback.removeEntry(entry.id)
            }
        }
    }
}

struct LyricsInspectorView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let lyrics = app.playback.lyrics.state
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(app.playback.currentItem?.title ?? String(localized: "player.nothing_playing"))
                    .font(.headline)
                    .lineLimit(1)
                Text(app.playback.currentItem?.artist ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            Divider()

            if lyrics.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = lyrics.errorMessage {
                ContentUnavailableView(String(localized: "lyrics.unavailable"), systemImage: "text.quote", description: Text(error))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if lyrics.lines.isEmpty {
                ContentUnavailableView(String(localized: "lyrics.empty"), systemImage: "text.quote")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(line.lyric)
                                        .font(index == lyrics.currentIndex ? .headline : .body)
                                        .foregroundStyle(index == lyrics.currentIndex ? .primary : .secondary)
                                    if app.settings.showRoma, let roma = line.romalrc, !roma.isEmpty {
                                        Text(roma).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let translation = line.tlyric, !translation.isEmpty {
                                        Text(translation).font(.subheadline).foregroundStyle(.secondary)
                                    }
                                }
                                .id(index)
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: lyrics.currentIndex) { _, index in
                        if let index {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(index, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }
}
