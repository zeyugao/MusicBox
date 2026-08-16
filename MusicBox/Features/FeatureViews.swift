import SwiftUI

struct ExploreFeatureView: View {
    @Environment(AppModel.self) private var app
    @State private var model: ExploreFeatureModel

    init(repository: any MusicRepository) {
        _model = State(initialValue: ExploreFeatureModel(repository: repository))
    }

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 8) {
                    TextField(String(localized: "explore.search"), text: Binding(
                        get: { model.query },
                        set: { model.updateQuery($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.search() }

                    Button {
                        model.search()
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .help(String(localized: "explore.search"))
                    .disabled(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if !model.suggestions.isEmpty && model.results.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "explore.suggestions"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        ForEach(model.suggestions.prefix(6), id: \.id) { result in
                            Button {
                                model.updateQuery(result.name)
                                model.search()
                            } label: {
                                Text(result.name)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if model.isSearching {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if !model.results.isEmpty {
                    SongResultsSection(songs: model.results.map { $0.convertToSong() })
                } else {
                    recommendations
                }

                if let error = model.errorMessage {
                    RetryState(message: error) { model.search() }
                }
            }
            .padding(20)
        }
        .task {
            model.loadRecommendations()
        }
    }

    private var recommendations: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(localized: "explore.recommended"))
                    .font(.title3.weight(.semibold))
                if model.isLoadingRecommendations { ProgressView().controlSize(.small) }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 16)], spacing: 16) {
                ForEach(model.recommendations) { recommendation in
                    Button {
                        app.router.showPlaylist(PlaylistDestination(id: recommendation.id, name: recommendation.name))
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            if let url = URL(string: recommendation.picUrl), url.scheme != nil, url.host != nil {
                                AsyncImage(url: url) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Color.secondary.opacity(0.15)
                                }
                                .frame(height: 112)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            } else {
                                Image(systemName: recommendation.picUrl)
                                    .font(.title)
                                    .frame(maxWidth: .infinity, minHeight: 112)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            }
                            Text(recommendation.name)
                                .font(.subheadline)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct PlaylistFeatureView: View {
    @Environment(AppModel.self) private var app
    @State private var model: PlaylistFeatureModel

    init(destination: PlaylistDestination, repository: any MusicRepository) {
        _model = State(initialValue: PlaylistFeatureModel(destination: destination, repository: repository))
    }

    var body: some View {
        Group {
            if model.isLoading && model.songs.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.errorMessage, model.songs.isEmpty {
                RetryState(message: error) { model.retry() }
            } else {
                List {
                    Section {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.destination.name)
                                    .font(.title2.weight(.semibold))
                                Text(model.songs.count, format: .number)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                app.playback.replaceSource(model.items)
                            } label: {
                                Image(systemName: "play.fill")
                            }
                            .help(String(localized: "playlist.play_all"))
                            .disabled(model.items.isEmpty)
                        }
                        .padding(.vertical, 6)
                    }

                    Section {
                        ForEach(Array(model.songs.enumerated()), id: \.element.id) { index, song in
                            SongRow(song: song, isCurrent: app.playback.currentItem?.id == song.id) {
                                playSong(at: index)
                            } onPlayNext: {
                                app.playback.enqueueNext(model.items[index])
                            }
                            .onAppear {
                                if index == model.songs.indices.last { model.loadMore() }
                            }
                        }
                    }

                    if model.isLoadingMore {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                }
                .listStyle(.inset)
            }
        }
        .task { model.load() }
    }

    private func playSong(at index: Int) {
        let items = model.items
        guard items.indices.contains(index) else { return }
        switch app.settings.doubleClickPlayAction {
        case .replaceSource:
            app.playback.replaceSource(items, startIndex: index)
        case .appendSource:
            app.playback.playNow(items[index])
        }
    }
}

struct CloudFilesFeatureView: View {
    @Environment(AppModel.self) private var app
    @State private var model: CloudFilesFeatureModel
    @State private var matchFile: CloudMusicApi.CloudFile?
    @State private var adjustedSongID = ""

    init(repository: any MusicRepository) {
        _model = State(initialValue: CloudFilesFeatureModel(repository: repository))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(String(localized: "cloud.search"), text: Binding(
                    get: { model.query },
                    set: { model.updateQuery($0) }
                ))
                .textFieldStyle(.roundedBorder)
                Button {
                    model.load(reset: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(String(localized: "action.refresh"))
            }
            .padding(16)

            if model.isLoading && model.files.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.errorMessage, model.files.isEmpty {
                RetryState(message: error) { model.load(reset: true) }
            } else if model.filteredFiles.isEmpty {
                ContentUnavailableView(String(localized: "cloud.empty"), systemImage: "icloud")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(model.filteredFiles.enumerated()), id: \.element.id) { index, file in
                        HStack(spacing: 12) {
                            Image(systemName: file.isMatched ? "checkmark.circle.fill" : "questionmark.circle")
                                .foregroundStyle(file.isMatched ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(file.fileName).lineLimit(1)
                                Text(file.simpleSong?.name ?? file.parseFileSize())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                matchFile = file
                                adjustedSongID = ""
                            } label: {
                                Image(systemName: "link")
                            }
                            .help(String(localized: "cloud.match"))
                        }
                        .onAppear {
                            if index == model.filteredFiles.indices.last, model.query.isEmpty { model.loadMore() }
                        }
                    }
                    if model.isLoadingMore {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                }
                .listStyle(.inset)
            }
        }
        .task { model.load() }
        .sheet(item: $matchFile) { file in
            VStack(alignment: .leading, spacing: 16) {
                Text(String(localized: "cloud.match"))
                    .font(.headline)
                Text(file.fileName).lineLimit(1)
                TextField(String(localized: "cloud.match_song_id"), text: $adjustedSongID)
                HStack {
                    Spacer()
                    Button(String(localized: "action.cancel")) { matchFile = nil }
                    Button(String(localized: "action.confirm")) {
                        guard let userID = app.account.profile?.userId,
                            let songID = UInt64(adjustedSongID)
                        else { return }
                        let job = app.transfers.begin(name: file.fileName)
                        Task {
                            do {
                                try await model.match(file, to: songID, userID: userID)
                                app.transfers.complete(job)
                            } catch {
                                app.transfers.fail(job, message: error.localizedDescription)
                                app.alerts.show(error.localizedDescription)
                            }
                            matchFile = nil
                        }
                    }
                    .disabled(UInt64(adjustedSongID) == nil)
                }
            }
            .padding(20)
            .frame(width: 360)
        }
    }
}

struct AccountFeatureView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.account.profile == nil {
            LoginFeatureView(repository: app.repository)
        } else {
            SettingsFeatureView()
        }
    }
}

private struct LoginFeatureView: View {
    @Environment(AppModel.self) private var app
    @State private var model: LoginFeatureModel

    init(repository: any MusicRepository) {
        _model = State(initialValue: LoginFeatureModel(repository: repository))
    }

    var body: some View {
        Form {
            Section {
                Text(String(localized: "login.message"))
                    .foregroundStyle(.secondary)
                TextField(String(localized: "login.phone"), text: $model.phone)
                TextField(String(localized: "login.country_code"), text: $model.countryCode)
                SecureField(String(localized: "login.password"), text: $model.password)
                HStack {
                    Button(String(localized: "login.submit")) {
                        model.loginWithPassword { await app.refreshAccount() }
                    }
                    .disabled(model.isSubmitting || model.phone.isEmpty || model.password.isEmpty)
                    Button(String(localized: "login.qr")) {
                        model.beginQRCodeLogin { await app.refreshAccount() }
                    }
                    .disabled(model.isSubmitting)
                }
                if let url = model.qrCodeURL {
                    Link(String(localized: "login.open_qr"), destination: url)
                }
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
                if model.isSubmitting { ProgressView() }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 520, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
    }
}

private struct SettingsFeatureView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section(String(localized: "settings.account")) {
                LabeledContent(String(localized: "settings.user"), value: app.account.profile?.nickname ?? "")
                Button(String(localized: "action.refresh")) {
                    Task { await app.refreshAccount() }
                }
                Button(String(localized: "settings.logout"), role: .destructive) {
                    Task { await app.signOut() }
                }
            }

            Section(String(localized: "settings.playback")) {
                Toggle(String(localized: "settings.prevent_sleep"), isOn: $settings.preventSleepWhenPlaying)
                Toggle(String(localized: "settings.show_timestamp"), isOn: $settings.showTimestamp)
                Toggle(String(localized: "settings.show_roma"), isOn: $settings.showRoma)
                Picker(String(localized: "settings.double_click"), selection: $settings.doubleClickPlayAction) {
                    Text(String(localized: "settings.double_click.replace")).tag(DoubleClickPlayAction.replaceSource)
                    Text(String(localized: "settings.double_click.append")).tag(DoubleClickPlayAction.appendSource)
                }
            }

            if app.reporting.relayAvailable {
                Section(String(localized: "settings.relay")) {
                    Toggle(
                        String(localized: "settings.relay_enabled"),
                        isOn: Binding(
                            get: { app.reporting.relayEnabled },
                            set: { enabled in Task { await app.reporting.updateRelayEnabled(enabled) } }
                        )
                    )
                    .disabled(app.reporting.isUpdatingRelaySetting)
                }
            }

            Section(String(localized: "settings.storage")) {
                Button(String(localized: "settings.clear_cache"), role: .destructive) {
                    do {
                        try MusicLibraryCache.clear()
                        app.alerts.show(String(localized: "settings.cache_cleared"))
                    } catch {
                        app.alerts.show(error.localizedDescription)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

private struct SongResultsSection: View {
    @Environment(AppModel.self) private var app
    let songs: [CloudMusicApi.Song]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "explore.results"))
                .font(.title3.weight(.semibold))
            ForEach(songs) { song in
                SongRow(song: song, isCurrent: app.playback.currentItem?.id == song.id) {
                    app.playback.playNow(PlaylistItemFactory.make(song: song))
                } onPlayNext: {
                    app.playback.enqueueNext(PlaylistItemFactory.make(song: song))
                }
            }
        }
    }
}

private struct SongRow: View {
    let song: CloudMusicApi.Song
    let isCurrent: Bool
    let onPlay: () -> Void
    let onPlayNext: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                Image(systemName: isCurrent ? "speaker.wave.2.fill" : "music.note")
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.name).lineLimit(1)
                    Text(song.ar.compactMap(\.name).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(durationText(song.dt))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(String(localized: "queue.play_next"), action: onPlayNext)
            Button(String(localized: "comments.title")) {
                CommentsWindowManager.shared.show(
                    target: CommentsTarget(kind: .song, resourceID: song.id, name: song.name, subtitle: song.ar.compactMap(\.name).joined(separator: ", "))
                )
            }
        }
    }

    private func durationText(_ milliseconds: Int64) -> String {
        let seconds = Int(milliseconds / 1_000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct RetryState: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(String(localized: "state.error"), systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button(String(localized: "action.retry"), action: retry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
