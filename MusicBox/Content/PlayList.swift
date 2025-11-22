//
//  PlayList.swift
//  MusicBox
//
//  Created by Elsa on 2024/4/19.
//

import Cocoa
import CoreImage.CIFilterBuiltins
import CoreMedia
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let uploadToCloud = Notification.Name("uploadToCloud")
    static let refreshPlaylist = Notification.Name("refreshPlaylist")
    static let focusCurrentPlayingItem = Notification.Name("focusCurrentPlayingItem")
}

enum PlaylistMetadata: Hashable, Equatable {
    static func == (lhs: PlaylistMetadata, rhs: PlaylistMetadata) -> Bool {
        lhs.id == rhs.id
    }

    static func hash(into hasher: inout Hasher, value: PlaylistMetadata) {
        hasher.combine(value.id)
    }

    case netease(UInt64, String)  // id, name
    case songs([CloudMusicApi.Song], UInt64, String)  // all songs, id, name

    var name: String {
        switch self {
        case .netease(_, let name):
            return name
        case .songs(_, _, let name):
            return name
        }
    }

    var id: UInt64 {
        switch self {
        case .netease(let id, _):
            return id
        case .songs(_, let id, _):
            return id
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

class PlaylistDetailModel: ObservableObject {
    var originalSongs: [CloudMusicApi.Song]?
    @Published var songs: [CloudMusicApi.Song]?
    var curId: UInt64?

    // Incremental loading related properties
    private var allTrackIds: [UInt64] = []
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var hasMoreSongs = false
    @Published var allSongsLoaded = false
    private let pageSize = 100

    var sortOrder: [KeyPathComparator<CloudMusicApi.Song>]? = nil
    var searchText = ""

    func updatePlaylistDetail(metadata: PlaylistMetadata, force: Bool = false) async {
        switch metadata {
        case .netease(let id, _):
            let cacheTtl = if force { 0.0 } else { 10 * 60.0 }

            if let playlist = await CloudMusicApi(cacheTtl: cacheTtl).playlist_detail(id: id) {
                let trackIds = playlist.trackIds
                let tracks = playlist.tracks

                if let cur = curId, cur != id {
                    return
                }

                // Reset incremental loading state
                await MainActor.run {
                    self.allTrackIds = trackIds
                    self.originalSongs = []
                    self.isLoading = true
                    self.hasMoreSongs = trackIds.count > pageSize
                    self.allSongsLoaded = false
                }

                if trackIds.count == tracks.count {
                    await MainActor.run {
                        self.originalSongs = tracks
                        self.isLoading = false
                        self.allSongsLoaded = true
                        self.hasMoreSongs = false
                    }
                    self.update()
                } else {
                    // Start incremental loading
                    await loadInitialSongs(cacheTtl: cacheTtl)
                }
            }
        case .songs(let songs, _, _):
            await MainActor.run {
                self.originalSongs = songs
                self.allSongsLoaded = true
                self.hasMoreSongs = false
                self.isLoading = false
            }
            self.update()
        }
    }

    private func loadInitialSongs(cacheTtl: Double) async {
        let initialIds = Array(allTrackIds.prefix(pageSize))

        if let songs = await CloudMusicApi(cacheTtl: cacheTtl).song_detail(ids: initialIds) {
            await MainActor.run {
                self.originalSongs = songs
                self.isLoading = false
                self.hasMoreSongs = allTrackIds.count > pageSize
                if allTrackIds.count <= pageSize {
                    self.allSongsLoaded = true
                }
            }
            self.update()
        } else {
            await MainActor.run {
                self.originalSongs = []
                self.isLoading = false
                self.hasMoreSongs = false
                self.allSongsLoaded = true
            }
        }
    }

    private func loadMoreSongsInternal() async -> [CloudMusicApi.Song]? {
        guard !isLoadingMore && hasMoreSongs && !allSongsLoaded else { return nil }

        await MainActor.run {
            self.isLoadingMore = true
        }

        let currentCount = originalSongs?.count ?? 0
        let nextBatch = Array(allTrackIds.dropFirst(currentCount).prefix(pageSize))

        if let newSongs = await CloudMusicApi().song_detail(ids: nextBatch) {
            await MainActor.run {
                if self.originalSongs == nil {
                    self.originalSongs = newSongs
                } else {
                    self.originalSongs?.append(contentsOf: newSongs)
                }

                let totalLoaded = self.originalSongs?.count ?? 0
                self.hasMoreSongs = totalLoaded < allTrackIds.count
                self.isLoadingMore = false

                if totalLoaded >= allTrackIds.count {
                    self.allSongsLoaded = true
                }
            }
            self.update()
            return newSongs
        } else {
            await MainActor.run {
                self.hasMoreSongs = false
                self.isLoadingMore = false
                self.allSongsLoaded = true
            }
            return nil
        }
    }

    func loadMoreSongs() async {
        let _ = await loadMoreSongsInternal()
    }

    func loadAllSongsInBackground() async {
        guard !allSongsLoaded else { return }

        while await MainActor.run(resultType: Bool.self, body: { self.hasMoreSongs && !self.allSongsLoaded }) {
            let _ = await loadMoreSongsInternal()
            // Add small delay to prevent blocking UI
            try? await Task.sleep(nanoseconds: 10_000_000)  // 0.01 second
        }
    }

    func applySorting(by sortOrder: [KeyPathComparator<CloudMusicApi.Song>]) {
        self.sortOrder = sortOrder
    }

    func applySearch(by keyword: String) {
        searchText = keyword
    }

    func resetSorting() {
        sortOrder = nil
    }

    func resetSearchText() {
        searchText = ""
    }

    var hasActiveFilters: Bool {
        !searchText.isEmpty || sortOrder != nil
    }

    func update() {
        Task {
            guard let originalSongs = originalSongs else { return }
            let newSongs = applyFiltersAndSorting(to: originalSongs)

            await MainActor.run {
                self.songs = newSongs
            }
        }
    }

    private func applyFiltersAndSorting(to songs: [CloudMusicApi.Song]) -> [CloudMusicApi.Song] {
        var filteredSongs = songs

        if !searchText.isEmpty {
            let keyword = searchText.lowercased()
            filteredSongs = filteredSongs.filter { song in
                song.name.lowercased().contains(keyword)
                    || song.ar.compactMap(\.name).joined().lowercased().contains(keyword)
                    || song.albumName.lowercased().contains(keyword)
            }
        }

        if let sortOrder = sortOrder {
            filteredSongs = filteredSongs.sorted(using: sortOrder)
        }

        return filteredSongs
    }

    func totalTrackCount() async -> Int {
        await MainActor.run { self.allTrackIds.count }
    }

    private func waitForInitialLoadCompletion() async {
        while await MainActor.run(body: { self.isLoading && self.originalSongs == nil }) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func songsForPlayback(loadEntirePlaylist: Bool = false) async -> [CloudMusicApi.Song] {
        await waitForInitialLoadCompletion()

        if loadEntirePlaylist {
            let needsFullLoad = await MainActor.run {
                self.hasMoreSongs && !self.allSongsLoaded
            }

            if needsFullLoad {
                await loadAllSongsInBackground()
            }
        }

        return await MainActor.run {
            guard let originalSongs = self.originalSongs else { return [] }
            return self.applyFiltersAndSorting(to: originalSongs)
        }
    }

    func streamSongsForPlayback(loadEntirePlaylist: Bool = false) -> AsyncStream<[CloudMusicApi.Song]> {
        AsyncStream { continuation in
            Task {
                await waitForInitialLoadCompletion()

                let initialSongs = await MainActor.run { self.originalSongs ?? [] }
                if !initialSongs.isEmpty {
                    continuation.yield(initialSongs)
                }

                guard loadEntirePlaylist, !self.hasActiveFilters else {
                    continuation.finish()
                    return
                }

                while await MainActor.run(resultType: Bool.self, body: { self.hasMoreSongs && !self.allSongsLoaded }) {
                    if let newSongs = await loadMoreSongsInternal(), !newSongs.isEmpty {
                        continuation.yield(newSongs)
                    } else {
                        // Either another load is still in progress or loading failed; wait briefly.
                        try? await Task.sleep(nanoseconds: 10_000_000)
                    }
                }

                continuation.finish()
            }
        }
    }
}

func loadItem(song: CloudMusicApi.Song, songData: CloudMusicApi.SongData) async -> PlaylistItem? {
    guard let url = URL(string: songData.url.https) else { return nil }
    let newItem = PlaylistItem(
        id: songData.id,
        url: url,
        title: song.name,
        artist: song.ar.compactMap(\.name).joined(separator: ", "),
        albumId: song.al.id,
        ext: songData.type,
        duration: CMTime(value: songData.time, timescale: 1000),
        artworkUrl: URL(string: song.al.picUrl.https),
        nsSong: song
    )
    return newItem
}

func loadItem(song: CloudMusicApi.Song) -> PlaylistItem {
    let newItem = PlaylistItem(
        id: song.id,
        url: nil,
        title: song.name,
        artist: song.ar.compactMap(\.name).joined(separator: ", "),
        albumId: song.al.id,
        ext: nil,
        duration: CMTime(value: song.dt, timescale: 1000),
        artworkUrl: URL(string: song.al.picUrl.https),
        nsSong: song
    )
    return newItem
}

func likeSong(
    likelist: inout Set<UInt64>, songId: UInt64, favored: Bool
)
    async
{
    do {
        try await CloudMusicApi().like(id: songId, like: !favored)
        if favored {
            likelist.remove(songId)
        } else {
            likelist.insert(songId)
        }
    } catch let error as RequestError {
        AlertModal.showAlert(error.localizedDescription)
    } catch {
        AlertModal.showAlert(error.localizedDescription)
    }
}

func uploadCloudFile(songId: UInt64, url: URL, userInfo: UserInfo) async throws -> Bool {
    if let metadata = await loadMetadata(url: url) {
        if let privateSongId = try await CloudMusicApi().cloud(
            filePath: url,
            songName: metadata.title,
            artist: metadata.artist,
            album: metadata.album
        ) {
            print("Private song ID: \(privateSongId)")
            try await CloudMusicApi().cloud_match(
                userId: userInfo.profile?.userId ?? 0,
                songId: privateSongId,
                adjustSongId: songId
            )
            return true
        } else {
            throw RequestError.Request("Failed to upload file to cloud")
        }

    } else {
        throw RequestError.Request("Failed to load metadata from file")
    }
}

@MainActor
func selectAudioFile(forSong songTitle: String? = nil) async -> URL? {
    let openPanel = NSOpenPanel()
    openPanel.prompt = "Select"
    if let songTitle = songTitle {
        openPanel.message = "Choose an audio file to upload for \"\(songTitle)\""
    }
    openPanel.allowsMultipleSelection = false
    openPanel.canChooseDirectories = false
    openPanel.canChooseFiles = true
    openPanel.allowedContentTypes = [UTType.mp3, UTType.audio]

    let result = await openPanel.begin()

    if result == .OK, let url = openPanel.url {
        return url
    }
    return nil
}

struct ListPlaylistDialogView: View {
    @EnvironmentObject var userInfo: UserInfo
    @Environment(\.dismiss) private var dismiss

    var onSelect: ((CloudMusicApi.PlayListItem) -> Void)?

    var body: some View {
        VStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(userInfo.playlists.filter { !$0.subscribed }) { playlist in
                        PlaylistSelectionRowView(playlist: playlist, onSelect: {
                            onSelect?(playlist)
                            dismiss()
                        })
                    }
                }
            }
            .frame(maxWidth: 400, maxHeight: 600)
            .padding(.top, 16)

            Button("Cancel") {
                dismiss()
            }
            .padding(.bottom, 8)
        }
    }
}

struct PlaylistSelectionRowView: View {
    let playlist: CloudMusicApi.PlayListItem
    let onSelect: () -> Void
    @State private var isHovering = false
    
    var body: some View {
        Button(action: onSelect) {
            HStack {
                let height = 48.0
                AsyncImageWithCache(url: URL(string: playlist.coverImgUrl.https)) {
                    image in
                    image.resizable()
                        .scaledToFit()
                        .frame(width: height, height: height)
                        .cornerRadius(5)
                } placeholder: {
                    Image(systemName: "music.note")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                        .padding()
                        .frame(width: height, height: height)
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(5)
                }
                .padding(.trailing, 8)
                VStack(alignment: .leading) {
                    HStack(spacing: 4) {
                        if playlist.privacy != 0 {
                            Image(systemName: "lock.fill")
                                .foregroundColor(.secondary)
                        }
                        Text(playlist.name)
                            .lineLimit(1)
                            .multilineTextAlignment(.leading)
                    }
                    Text("\((playlist.trackCount ?? 0) + (playlist.cloudTrackCount ?? 0))首 • \(playlist.creator.nickname)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovering ? Color.accentColor.opacity(0.1) : Color.clear)
        )
        .onHover { inside in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = inside
            }
        }
        .padding(.horizontal, 8)
    }
}

struct DownloadProgressDialog: View {
    var text: String

    @Binding var value: Double
    @Binding var canceled: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(text)

                Spacer()
            }

            ProgressView(value: value)

            HStack {
                Spacer()
                Button(canceled ? "Canceling" : "Cancel") {
                    canceled = true
                }
            }
        }
        .padding(20)
        .frame(width: 300, height: 100)
    }
}

// MARK: - UIKit Table Cell Views

class SongFavoriteTableCellView: NSTableCellView {
    private let favoriteButton = NSButton()
    private var song: CloudMusicApi.Song?
    private weak var userInfo: UserInfo?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        favoriteButton.isBordered = false
        favoriteButton.target = self
        favoriteButton.action = #selector(toggleFavorite)
        addSubview(favoriteButton)

        favoriteButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            favoriteButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            favoriteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            favoriteButton.widthAnchor.constraint(equalToConstant: 16),
            favoriteButton.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    func configure(with song: CloudMusicApi.Song, userInfo: UserInfo) {
        self.song = song
        self.userInfo = userInfo
        updateButton()
    }

    private func updateButton() {
        guard let song = song, let userInfo = userInfo else { return }
        let isFavorite = userInfo.likelist.contains(song.id)
        favoriteButton.image = NSImage(
            systemSymbolName: isFavorite ? "heart.fill" : "heart", accessibilityDescription: nil)
        favoriteButton.toolTip = isFavorite ? "Unfavor" : "Favor"
    }

    @objc private func toggleFavorite() {
        guard let song = song, let userInfo = userInfo else { return }
        let isFavorite = userInfo.likelist.contains(song.id)

        Task {
            var likelist = userInfo.likelist
            await likeSong(likelist: &likelist, songId: song.id, favored: isFavorite)
            await MainActor.run {
                if isFavorite {
                    userInfo.likelist.remove(song.id)
                } else {
                    userInfo.likelist.insert(song.id)
                }
                updateButton()
            }
        }
    }
}

class SongTitleTableCellView: NSTableCellView {
    private let titleLabel = NSTextField()
    private let aliasLabel = NSTextField()
    private let speakerIcon = NSImageView()
    private let statusIcon = NSImageView()
    private let stackView = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        aliasLabel.isBezeled = false
        aliasLabel.drawsBackground = false
        aliasLabel.isEditable = false
        aliasLabel.isSelectable = false
        aliasLabel.textColor = .secondaryLabelColor
        aliasLabel.lineBreakMode = .byTruncatingTail
        aliasLabel.maximumNumberOfLines = 1

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 4

        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(aliasLabel)

        let spacer = NSView()
        stackView.addArrangedSubview(spacer)
        stackView.addArrangedSubview(speakerIcon)
        stackView.addArrangedSubview(statusIcon)

        addSubview(stackView)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
            speakerIcon.widthAnchor.constraint(equalToConstant: 16),
            speakerIcon.heightAnchor.constraint(equalToConstant: 16),
            statusIcon.widthAnchor.constraint(equalToConstant: 18),
            statusIcon.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    func configure(
        with song: CloudMusicApi.Song,
        playlistStatus: PlaylistStatus,
        playlistMetadata: PlaylistMetadata? = nil,
        playNextPosition: Int? = nil
    ) {
        titleLabel.stringValue = song.name

        if let alias = song.tns?.first ?? song.alia.first {
            aliasLabel.stringValue = "( \(alias) )"
            aliasLabel.isHidden = false
        } else {
            aliasLabel.isHidden = true
        }

        // Speaker icon for currently playing
        if song.id == playlistStatus.currentItem?.id {
            speakerIcon.image = NSImage(
                systemSymbolName: "speaker.3.fill", accessibilityDescription: nil)
            speakerIcon.contentTintColor = .controlAccentColor
            speakerIcon.isHidden = false
        } else {
            // Check if song is in play next items (only if we're viewing the Now Playing playlist)
            if case .songs = playlistMetadata, let playNextPosition {
                speakerIcon.image = NSImage(
                    systemSymbolName: "text.badge.plus", accessibilityDescription: nil)
                speakerIcon.contentTintColor = .systemOrange
                speakerIcon.isHidden = false
                speakerIcon.toolTip = "Play next: #\(playNextPosition)"
            } else {
                speakerIcon.isHidden = true
                speakerIcon.toolTip = nil
            }
        }

        // Status icon
        if song.pc != nil {
            statusIcon.image = NSImage(systemSymbolName: "cloud", accessibilityDescription: nil)
            statusIcon.toolTip = "Cloud"
            statusIcon.isHidden = false
        } else {
            switch song.fee {
            case .vip:
                statusIcon.image = NSImage(
                    systemSymbolName: "crown.fill", accessibilityDescription: nil)
                statusIcon.toolTip = "VIP required"
                statusIcon.isHidden = false
            case .album:
                statusIcon.image = NSImage(
                    systemSymbolName: "opticaldisc", accessibilityDescription: nil)
                statusIcon.toolTip = "Purchase album"
                statusIcon.isHidden = false
            case .trial:
                statusIcon.image = NSImage(
                    systemSymbolName: "waveform.path", accessibilityDescription: nil)
                statusIcon.toolTip = "Free trial quality"
                statusIcon.isHidden = false
            default:
                statusIcon.isHidden = true
            }
        }
    }
}

class SongArtistTableCellView: NSTableCellView {
    private let artistLabel = NSTextField()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        artistLabel.isBezeled = false
        artistLabel.drawsBackground = false
        artistLabel.isEditable = false
        artistLabel.isSelectable = false
        artistLabel.lineBreakMode = .byTruncatingTail
        artistLabel.maximumNumberOfLines = 1

        addSubview(artistLabel)
        artistLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            artistLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            artistLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            artistLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(with song: CloudMusicApi.Song) {
        artistLabel.stringValue = song.ar.compactMap(\.name).joined(separator: ", ")
    }
}

class SongAlbumTableCellView: NSTableCellView {
    private let albumLabel = NSTextField()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        albumLabel.isBezeled = false
        albumLabel.drawsBackground = false
        albumLabel.isEditable = false
        albumLabel.isSelectable = false
        albumLabel.lineBreakMode = .byTruncatingTail
        albumLabel.maximumNumberOfLines = 1

        addSubview(albumLabel)
        albumLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            albumLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            albumLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            albumLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(with song: CloudMusicApi.Song) {
        albumLabel.stringValue = song.albumName.isEmpty ? "Unknown Album" : song.albumName
    }
}

class SongDurationTableCellView: NSTableCellView {
    private let durationLabel = NSTextField()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        durationLabel.isBezeled = false
        durationLabel.drawsBackground = false
        durationLabel.isEditable = false
        durationLabel.isSelectable = false
        durationLabel.alignment = .right
        durationLabel.lineBreakMode = .byTruncatingTail
        durationLabel.maximumNumberOfLines = 1

        addSubview(durationLabel)
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            durationLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            durationLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            durationLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(with song: CloudMusicApi.Song) {
        let duration = song.parseDuration()
        durationLabel.stringValue = String(format: "%02d:%02d", duration.minute, duration.second)
    }
}

// MARK: - UIKit Table View Controller

class SongTableViewController: NSViewController {
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    private enum CellIdentifier {
        static let favorite = NSUserInterfaceItemIdentifier("SongFavoriteCell")
        static let title = NSUserInterfaceItemIdentifier("SongTitleCell")
        static let artist = NSUserInterfaceItemIdentifier("SongArtistCell")
        static let album = NSUserInterfaceItemIdentifier("SongAlbumCell")
        static let duration = NSUserInterfaceItemIdentifier("SongDurationCell")
    }

    private struct PlayNextCacheKey: Equatable {
        let currentIndex: Int?
        let playNextCount: Int
        let ids: [UInt64]
    }

    private var playNextCacheKey: PlayNextCacheKey?
    private var playNextPositionLookup: [UInt64: Int] = [:]
    private var pendingDropURLs: [URL] = []
    private let fallbackAudioExtensions: Set<String> = [
        "mp3", "aac", "m4a", "wav", "flac", "ogg", "oga", "ape", "alac", "aiff", "aif", "aifc"
    ]

    var songs: [CloudMusicApi.Song]? {
        didSet {
            let previousCount = oldValue?.count ?? 0
            let newCount = songs?.count ?? 0

            let isAppending: Bool
            if let oldSongs = oldValue, let newSongs = songs, newCount > previousCount, previousCount > 0 {
                let prefixMatches = newSongs.prefix(previousCount).enumerated().allSatisfy { index, element in
                    return element.id == oldSongs[index].id
                }
                isAppending = prefixMatches
            } else {
                isAppending = false
            }

            if isAppending && newCount > previousCount {
                let newRows = IndexSet(integersIn: previousCount..<newCount)
                tableView.beginUpdates()
                tableView.insertRows(at: newRows, withAnimation: [])
                tableView.endUpdates()
            } else {
                tableView.reloadData()
            }

            playNextCacheKey = nil
        }
    }

    var selectedItem: CloudMusicApi.Song.ID? {
        didSet {
            updateSelection()
        }
    }

    var sortOrder: [KeyPathComparator<CloudMusicApi.Song>] = [] {
        didSet {
            updateSortDescriptors()
        }
    }

    weak var userInfo: UserInfo?
    weak var playlistStatus: PlaylistStatus?
    var playlistMetadata: PlaylistMetadata?
    var onSortChange: (([KeyPathComparator<CloudMusicApi.Song>]) -> Void)?
    var selectedSongToAdd: ((CloudMusicApi.Song) -> Void)?
    var onDeleteFromPlaylist: ((CloudMusicApi.Song) -> Void)?
    var onUploadToCloud: ((CloudMusicApi.Song, URL) -> Void)?

    // Incremental loading related properties
    var onLoadMore: (() -> Void)?
    var isLoadingMore: Bool = false
    var hasMoreSongs: Bool = false
    private let pageSize = 100

    // Bottom padding configuration - number of blank rows to add at the bottom
    private let bottomPaddingRows = 3

    private var focusCurrentPlayingItemObserver: NSObjectProtocol?

    override func loadView() {
        view = NSView()
        setupTableView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupColumns()
        setupNotificationObservers()
    }

    private func setupTableView() {
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        // Add scroll notification observer for infinite scrolling
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )

        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsColumnSelection = false
        tableView.allowsMultipleSelection = false
        tableView.allowsColumnReordering = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowSizeStyle = .default
        tableView.doubleAction = #selector(handleDoubleClick(_:))
        tableView.target = self
        tableView.registerForDraggedTypes([.fileURL])

        view.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupColumns() {
        // Favorite column
        let favoriteColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("favorite"))
        favoriteColumn.title = ""
        favoriteColumn.width = 16
        favoriteColumn.minWidth = 16
        favoriteColumn.maxWidth = 16
        favoriteColumn.resizingMask = []
        tableView.addTableColumn(favoriteColumn)

        // Title column - primary expanding column with manual resize capability
        let titleColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        titleColumn.title = "Title"
        titleColumn.width = 200
        titleColumn.minWidth = 150
        titleColumn.resizingMask = [.autoresizingMask, .userResizingMask]
        tableView.addTableColumn(titleColumn)

        // Artist column - manually resizable
        let artistColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("artist"))
        artistColumn.title = "Artist"
        artistColumn.width = 100
        artistColumn.minWidth = 80
        artistColumn.resizingMask = [.userResizingMask]
        tableView.addTableColumn(artistColumn)

        // Album column - manually resizable
        let albumColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("album"))
        albumColumn.title = "Album"
        albumColumn.width = 100
        albumColumn.minWidth = 80
        albumColumn.resizingMask = [.userResizingMask]
        tableView.addTableColumn(albumColumn)

        // Duration column
        let durationColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("duration"))
        durationColumn.title = "Duration"
        durationColumn.width = 60
        durationColumn.minWidth = 60
        durationColumn.maxWidth = 60
        durationColumn.resizingMask = []
        tableView.addTableColumn(durationColumn)

        updateColumnSortingCapability()
    }

    func updateColumnSortingCapability() {
        let shouldEnableSorting: Bool
        if case .songs = playlistMetadata {
            shouldEnableSorting = false
        } else {
            shouldEnableSorting = true
        }

        for column in tableView.tableColumns {
            switch column.identifier.rawValue {
            case "title":
                column.sortDescriptorPrototype =
                    shouldEnableSorting ? NSSortDescriptor(key: "name", ascending: true) : nil
            case "artist":
                column.sortDescriptorPrototype =
                    shouldEnableSorting ? NSSortDescriptor(key: "ar.0.name", ascending: true) : nil
            case "album":
                column.sortDescriptorPrototype =
                    shouldEnableSorting ? NSSortDescriptor(key: "al.name", ascending: true) : nil
            case "duration":
                column.sortDescriptorPrototype =
                    shouldEnableSorting ? NSSortDescriptor(key: "dt", ascending: true) : nil
            default:
                break
            }
        }
    }

    private func updatePlayNextLookupIfNeeded() {
        guard case .songs = playlistMetadata else {
            if !playNextPositionLookup.isEmpty {
                playNextPositionLookup.removeAll(keepingCapacity: false)
                playNextCacheKey = nil
            }
            return
        }

        guard let playlistStatus = playlistStatus else {
            playNextPositionLookup.removeAll(keepingCapacity: false)
            playNextCacheKey = nil
            return
        }

        let currentIndex = playlistStatus.currentItemIndex
        let playNextCount = playlistStatus.playNextItemsCount

        guard let currentIndex, playNextCount > 0 else {
            if !playNextPositionLookup.isEmpty {
                playNextPositionLookup.removeAll(keepingCapacity: false)
            }
            playNextCacheKey = PlayNextCacheKey(currentIndex: playlistStatus.currentItemIndex, playNextCount: playNextCount, ids: [])
            return
        }

        let playlist = playlistStatus.playlist
        let start = currentIndex + 1
        guard start < playlist.count else {
            playNextPositionLookup.removeAll(keepingCapacity: false)
            playNextCacheKey = PlayNextCacheKey(currentIndex: currentIndex, playNextCount: playNextCount, ids: [])
            return
        }

        let end = min(start + playNextCount - 1, playlist.count - 1)
        let ids = playlist[start...end].map { $0.id }
        let newKey = PlayNextCacheKey(currentIndex: currentIndex, playNextCount: playNextCount, ids: ids)

        if newKey == playNextCacheKey {
            return
        }

        playNextCacheKey = newKey
        playNextPositionLookup.removeAll(keepingCapacity: true)
        for (offset, id) in ids.enumerated() {
            playNextPositionLookup[id] = offset + 1
        }
    }

    private func setupNotificationObservers() {
        focusCurrentPlayingItemObserver = NotificationCenter.default.addObserver(
            forName: .focusCurrentPlayingItem,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.focusCurrentPlayingItem()
        }
    }

    private func focusCurrentPlayingItem() {
        guard let songs = songs,
            let playlistStatus = playlistStatus,
            let currentItem = playlistStatus.currentItem,
            case .songs = playlistMetadata
        else { return }

        if let index = songs.firstIndex(where: { $0.id == currentItem.id }) {
            // Scroll to center the selected row
            let visibleRect = tableView.visibleRect
            let rowHeight = tableView.rowHeight
            let visibleRows = Int(visibleRect.height / rowHeight)
            let halfVisibleRows = visibleRows / 2

            // Handle beginning of list properly to avoid unwanted scrolling
            if index < halfVisibleRows {
                // For songs near the beginning, scroll to the top
                tableView.scroll(NSPoint(x: 0, y: 0))
            } else {
                // For other songs, center them
                let targetRow = index - halfVisibleRows
                let targetRect = tableView.rect(ofRow: targetRow)
                tableView.scroll(NSPoint(x: 0, y: targetRect.minY))
            }

            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    deinit {
        if let observer = focusCurrentPlayingItemObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        NotificationCenter.default.removeObserver(self)
    }

    private func updateSelection() {
        guard let songs = songs, let selectedItem = selectedItem else {
            tableView.deselectAll(nil)
            return
        }

        if let index = songs.firstIndex(where: { $0.id == selectedItem }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    private func updateSortDescriptors() {
        // Convert KeyPathComparator to NSSortDescriptor
        var descriptors: [NSSortDescriptor] = []

        for comparator in sortOrder {
            var keyPath: String = ""
            let ascending = comparator.order == .forward

            // Manually map KeyPath to string based on the known sorting keys
            if comparator.keyPath == \CloudMusicApi.Song.name {
                keyPath = "name"
            } else if comparator.keyPath == \CloudMusicApi.Song.ar[0].name {
                keyPath = "ar.0.name"
            } else if comparator.keyPath == \CloudMusicApi.Song.albumName {
                keyPath = "al.name"
            } else if comparator.keyPath == \CloudMusicApi.Song.dt {
                keyPath = "dt"
            }

            if !keyPath.isEmpty {
                descriptors.append(NSSortDescriptor(key: keyPath, ascending: ascending))
            }
        }

        tableView.sortDescriptors = descriptors
    }

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        guard let scrollView = notification.object as? NSScrollView else { return }

        let visibleRect = scrollView.documentVisibleRect
        let rowHeight: CGFloat = 24  // 根据实际行高定义
        let totalRows = songs?.count ?? 0
        let visibleRowsFromTop = Int(visibleRect.minY / rowHeight)
        let visibleRowsCount = Int(visibleRect.height / rowHeight)
        let lastVisibleRow = visibleRowsFromTop + visibleRowsCount

        // When remaining rows are less than or equal to pageSize/3, trigger loading
        let remainingRows = totalRows - lastVisibleRow
        let loadThreshold = pageSize / 3  // About 33 rows if pageSize=100
        let shouldLoadMore = remainingRows <= loadThreshold

        if shouldLoadMore && hasMoreSongs && !isLoadingMore {
            onLoadMore?()
        }
    }

    @objc private func handleDoubleClick(_ sender: NSTableView) {
        let clickedRow = sender.clickedRow
        guard clickedRow >= 0, let songs = songs, clickedRow < songs.count else { return }

        let song = songs[clickedRow]

        // 播放选中的歌曲
        Task { @MainActor in
            // Clear play next items when playing immediately
            playlistStatus?.clearPlayNext()
            let newItem = loadItem(song: song)
            let _ = await playlistStatus?.addItemAndSeekTo(newItem, shouldPlay: true)
        }
    }
}

// MARK: - NSTableViewDataSource

extension SongTableViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        // 如果有歌曲，添加额外的空白行用于底部填充
        let songCount = songs?.count ?? 0
        return songCount > 0 ? songCount + bottomPaddingRows : 0
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard let songs = songs, !songs.isEmpty else {
            pendingDropURLs = []
            return []
        }

        let urls = extractAudioFileURLs(from: info)
        pendingDropURLs = urls

        guard !urls.isEmpty else {
            return []
        }

        var targetRow = row
        if targetRow < 0 {
            targetRow = 0
        }
        if targetRow >= songs.count {
            targetRow = songs.count - 1
        }

        tableView.setDropRow(targetRow, dropOperation: .on)
        return .copy
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard dropOperation == .on, let songs = songs, !songs.isEmpty,
            row >= 0, row < songs.count
        else {
            pendingDropURLs = []
            return false
        }

        let urls = pendingDropURLs.isEmpty ? extractAudioFileURLs(from: info) : pendingDropURLs
        pendingDropURLs = []

        guard let fileURL = urls.first else {
            return false
        }

        onUploadToCloud?(songs[row], fileURL)
        return true
    }

    private func extractAudioFileURLs(from draggingInfo: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]

        guard let urls = draggingInfo.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL] else {
            return []
        }

        return urls.filter { isAudioFileURL($0) }
    }

    private func isAudioFileURL(_ url: URL) -> Bool {
        if #available(macOS 11.0, *) {
            if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
                contentType.conforms(to: .audio)
            {
                return true
            }
        }

        let ext = url.pathExtension.lowercased()
        return fallbackAudioExtensions.contains(ext)
    }
}

// MARK: - NSTableViewDelegate

extension SongTableViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard let songs = songs, !songs.isEmpty else { return nil }

        // 判断是否为最后一行（我们的空白填充行）
        if row >= songs.count {
            // 如果是，为所有列返回一个空的视图即可
            return NSView()
        }

        let song = songs[row]
        guard let identifier = tableColumn?.identifier else { return nil }

        updatePlayNextLookupIfNeeded()

        switch identifier.rawValue {
        case "favorite":
            let cellView: SongFavoriteTableCellView
            if let reused = tableView.makeView(withIdentifier: CellIdentifier.favorite, owner: self) as? SongFavoriteTableCellView {
                cellView = reused
            } else {
                let newView = SongFavoriteTableCellView()
                newView.identifier = CellIdentifier.favorite
                cellView = newView
            }

            if let userInfo = userInfo {
                cellView.configure(with: song, userInfo: userInfo)
            }
            return cellView

        case "title":
            guard let playlistStatus else { return nil }

            let cellView: SongTitleTableCellView
            if let reused = tableView.makeView(withIdentifier: CellIdentifier.title, owner: self) as? SongTitleTableCellView {
                cellView = reused
            } else {
                let newView = SongTitleTableCellView()
                newView.identifier = CellIdentifier.title
                cellView = newView
            }

            let playNextPosition = playNextPositionLookup[song.id]
            cellView.configure(
                with: song,
                playlistStatus: playlistStatus,
                playlistMetadata: playlistMetadata,
                playNextPosition: playNextPosition
            )
            return cellView

        case "artist":
            let cellView: SongArtistTableCellView
            if let reused = tableView.makeView(withIdentifier: CellIdentifier.artist, owner: self) as? SongArtistTableCellView {
                cellView = reused
            } else {
                let newView = SongArtistTableCellView()
                newView.identifier = CellIdentifier.artist
                cellView = newView
            }
            cellView.configure(with: song)
            return cellView

        case "album":
            let cellView: SongAlbumTableCellView
            if let reused = tableView.makeView(withIdentifier: CellIdentifier.album, owner: self) as? SongAlbumTableCellView {
                cellView = reused
            } else {
                let newView = SongAlbumTableCellView()
                newView.identifier = CellIdentifier.album
                cellView = newView
            }
            cellView.configure(with: song)
            return cellView

        case "duration":
            let cellView: SongDurationTableCellView
            if let reused = tableView.makeView(withIdentifier: CellIdentifier.duration, owner: self) as? SongDurationTableCellView {
                cellView = reused
            } else {
                let newView = SongDurationTableCellView()
                newView.identifier = CellIdentifier.duration
                cellView = newView
            }
            cellView.configure(with: song)
            return cellView

        default:
            return nil
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selectedRow = tableView.selectedRow
        if selectedRow >= 0, let songs = songs, selectedRow < songs.count {
            selectedItem = songs[selectedRow].id
        } else {
            selectedItem = nil
        }
    }

    func tableView(
        _ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) {
        // Check if sorting should be disabled for .songs playlist
        if case .songs = playlistMetadata {
            // Reset sort descriptors and return early to prevent sorting
            tableView.sortDescriptors = []
            return
        }

        // Get the clicked column key
        guard let newDescriptor = tableView.sortDescriptors.first,
            let clickedKey = newDescriptor.key
        else {
            sortOrder = []
            onSortChange?(sortOrder)
            return
        }

        // Determine current state and next state for the clicked column
        let currentSortKey = sortOrder.first?.keyPath
        let nextSortOrder: [KeyPathComparator<CloudMusicApi.Song>]

        // Check if we're clicking on the same column that's currently sorted
        let isSameColumn =
            (clickedKey == "name" && currentSortKey == \CloudMusicApi.Song.name)
            || (clickedKey == "ar.0.name" && currentSortKey == \CloudMusicApi.Song.ar[0].name)
            || (clickedKey == "al.name" && currentSortKey == \CloudMusicApi.Song.albumName)
            || (clickedKey == "dt" && currentSortKey == \CloudMusicApi.Song.dt)

        if isSameColumn {
            // Same column clicked - cycle through states
            if let currentOrder = sortOrder.first?.order {
                if currentOrder == .forward {
                    // Was ascending, now make it descending
                    nextSortOrder = createSortOrder(for: clickedKey, ascending: false)
                } else {
                    // Was descending, now clear sort
                    nextSortOrder = []
                }
            } else {
                // No current sort, start with ascending
                nextSortOrder = createSortOrder(for: clickedKey, ascending: true)
            }
        } else {
            // Different column clicked - start with ascending
            nextSortOrder = createSortOrder(for: clickedKey, ascending: true)
        }

        // Update table view descriptors to match our decision
        if nextSortOrder.isEmpty {
            tableView.sortDescriptors = []
        } else {
            let ascending = nextSortOrder.first?.order == .forward
            tableView.sortDescriptors = [NSSortDescriptor(key: clickedKey, ascending: ascending)]
        }

        sortOrder = nextSortOrder
        onSortChange?(sortOrder)
    }

    private func createSortOrder(for keyPath: String, ascending: Bool) -> [KeyPathComparator<
        CloudMusicApi.Song
    >] {
        let order: SortOrder = ascending ? .forward : .reverse

        switch keyPath {
        case "name":
            return [KeyPathComparator(\CloudMusicApi.Song.name, order: order)]
        case "ar.0.name":
            return [KeyPathComparator(\CloudMusicApi.Song.ar[0].name, order: order)]
        case "al.name":
            return [KeyPathComparator(\CloudMusicApi.Song.albumName, order: order)]
        case "dt":
            return [KeyPathComparator(\CloudMusicApi.Song.dt, order: order)]
        default:
            return []
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        // 只允许选中歌曲行，不允许选中最后的空白行
        return row < (songs?.count ?? 0)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        return NSTableRowView()
    }
}

// MARK: - Context Menu Support

extension SongTableViewController {
    override func rightMouseDown(with event: NSEvent) {
        let point = tableView.convert(event.locationInWindow, from: nil)
        let row = tableView.row(at: point)

        guard row >= 0, let songs = songs, row < songs.count else { return }

        // Select the row if it's not already selected
        if !tableView.selectedRowIndexes.contains(row) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        let song = songs[row]
        let menu = createContextMenu(for: song)

        NSMenu.popUpContextMenu(menu, with: event, for: tableView)
    }

    private func createContextMenu(for song: CloudMusicApi.Song) -> NSMenu {
        let menu = NSMenu()
        let makeIcon: (String, String) -> NSImage? = { systemName, description in
            guard #available(macOS 11.0, *) else { return nil }
            let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            let image = NSImage(systemSymbolName: systemName, accessibilityDescription: description)
            return image?.withSymbolConfiguration(configuration)
        }
        // Play
        let playItem = NSMenuItem(title: "Play", action: #selector(playSong(_:)), keyEquivalent: "")
        playItem.target = self
        playItem.representedObject = song
        playItem.image = makeIcon("play.fill", "Play song")
        menu.addItem(playItem)

        // Play Next
        let playNextItem = NSMenuItem(title: "Play Next", action: #selector(playNext(_:)), keyEquivalent: "")
        playNextItem.target = self
        playNextItem.representedObject = song
        playNextItem.image = makeIcon("text.badge.plus", "Play next")
        menu.addItem(playNextItem)

        // Add to Now Playing
        let addToNowPlayingItem = NSMenuItem(
            title: "Add to Now Playing", action: #selector(addToNowPlaying(_:)), keyEquivalent: "")
        addToNowPlayingItem.target = self
        addToNowPlayingItem.representedObject = song
        addToNowPlayingItem.image = makeIcon("music.note.list", "Add to now playing queue")
        menu.addItem(addToNowPlayingItem)

        // Add to Playlist
        let addToPlaylistItem = NSMenuItem(
            title: "Add to Playlist", action: #selector(addToPlaylist(_:)), keyEquivalent: "")
        addToPlaylistItem.target = self
        addToPlaylistItem.representedObject = song
        addToPlaylistItem.image = makeIcon("plus.rectangle.on.rectangle", "Add to playlist")
        menu.addItem(addToPlaylistItem)

        // Delete from Playlist (if applicable)
        if case .netease = playlistMetadata {
            let deleteItem = NSMenuItem(
                title: "Delete from Playlist", action: #selector(deleteFromPlaylist(_:)),
                keyEquivalent: "")
            deleteItem.target = self
            deleteItem.representedObject = song
            deleteItem.image = makeIcon("trash", "Delete from playlist")
            menu.addItem(deleteItem)
        }

        // Upload to Cloud
        let uploadItem = NSMenuItem(
            title: "Upload to Cloud", action: #selector(uploadToCloud(_:)), keyEquivalent: "")
        uploadItem.target = self
        uploadItem.representedObject = song
        uploadItem.image = makeIcon("icloud.and.arrow.up", "Upload to cloud")
        menu.addItem(uploadItem)

        // Copy Title
        let copyTitleItem = NSMenuItem(
            title: "Copy Title", action: #selector(copyTitle(_:)), keyEquivalent: "")
        copyTitleItem.target = self
        copyTitleItem.representedObject = song
        copyTitleItem.image = makeIcon("doc.on.doc", "Copy title")
        menu.addItem(copyTitleItem)

        // Copy Link
        let copyLinkItem = NSMenuItem(
            title: "Copy Link", action: #selector(copyLink(_:)), keyEquivalent: "")
        copyLinkItem.target = self
        copyLinkItem.representedObject = song
        copyLinkItem.image = makeIcon("link", "Copy link")
        menu.addItem(copyLinkItem)

        return menu
    }

    @objc private func playSong(_ sender: NSMenuItem) {
        guard let song = sender.representedObject as? CloudMusicApi.Song else { return }
        Task { @MainActor in
            // Clear play next items when playing immediately
            playlistStatus?.clearPlayNext()
            let newItem = loadItem(song: song)
            let _ = await playlistStatus?.addItemAndSeekTo(newItem, shouldPlay: true)
        }
    }
    
    @objc private func playNext(_ sender: NSMenuItem) {
        guard let song = sender.representedObject as? CloudMusicApi.Song else { return }
        Task {
            let newItem = loadItem(song: song)
            await playlistStatus?.addToPlayNext(newItem)
        }
    }

    @objc private func addToNowPlaying(_ sender: NSMenuItem) {
        guard let song = sender.representedObject as? CloudMusicApi.Song else { return }
        Task {
            let newItem = loadItem(song: song)
            await playlistStatus?.addToPlayNext(newItem)
        }
    }

    @objc private func addToPlaylist(_ sender: NSMenuItem) {
        guard let song = sender.representedObject as? CloudMusicApi.Song else { return }
        selectedSongToAdd?(song)
    }

    @objc private func deleteFromPlaylist(_ sender: NSMenuItem) {
        guard let song = sender.representedObject as? CloudMusicApi.Song else { return }
        onDeleteFromPlaylist?(song)
    }

    @objc private func uploadToCloud(_ sender: NSMenuItem) {
        guard let song = sender.representedObject as? CloudMusicApi.Song else { return }
        Task {
            if let url = await selectAudioFile(forSong: song.name) {
                onUploadToCloud?(song, url)
            }
        }
    }

    @objc private func copyTitle(_ sender: NSMenuItem) {
        guard let song = sender.representedObject as? CloudMusicApi.Song else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(song.name, forType: .string)
    }

    @objc private func copyLink(_ sender: NSMenuItem) {
        guard let song = sender.representedObject as? CloudMusicApi.Song else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            "https://music.163.com/#/song?id=\(song.id)", forType: .string)
    }
}

// MARK: - SwiftUI Wrapper

struct SongTableView: NSViewControllerRepresentable {
    let songs: [CloudMusicApi.Song]?
    @Binding var selectedItem: CloudMusicApi.Song.ID?
    @Binding var sortOrder: [KeyPathComparator<CloudMusicApi.Song>]
    let userInfo: UserInfo
    let playlistStatus: PlaylistStatus
    let playlistMetadata: PlaylistMetadata?
    let onSortChange: ([KeyPathComparator<CloudMusicApi.Song>]) -> Void
    @Binding var selectedSongToAdd: CloudMusicApi.Song?
    let onDeleteFromPlaylist: (CloudMusicApi.Song) -> Void
    let onUploadToCloud: (CloudMusicApi.Song, URL) -> Void
    let onLoadMore: () -> Void
    let isLoadingMore: Bool
    let hasMoreSongs: Bool

    func makeNSViewController(context: Context) -> SongTableViewController {
        let controller = SongTableViewController()
        controller.userInfo = userInfo
        controller.playlistStatus = playlistStatus
        controller.playlistMetadata = playlistMetadata
        controller.onSortChange = onSortChange
        controller.selectedSongToAdd = { song in
            selectedSongToAdd = song
        }
        controller.onDeleteFromPlaylist = onDeleteFromPlaylist
        controller.onUploadToCloud = onUploadToCloud
        controller.onLoadMore = onLoadMore
        return controller
    }

    func updateNSViewController(_ nsViewController: SongTableViewController, context: Context) {
        nsViewController.songs = songs
        nsViewController.selectedItem = selectedItem
        nsViewController.sortOrder = sortOrder
        nsViewController.playlistMetadata = playlistMetadata
        nsViewController.isLoadingMore = isLoadingMore
        nsViewController.hasMoreSongs = hasMoreSongs
        nsViewController.updateColumnSortingCapability()
    }
}

struct PlaylistToolbar: ToolbarContent {
    @ObservedObject var model: PlaylistDetailModel
    let songs: [CloudMusicApi.Song]
    let playlistMetadata: PlaylistMetadata?
    let playlistStatus: PlaylistStatus
    let userInfo: UserInfo
    let onRefresh: () -> Void

    var body: some ToolbarContent {
        if case .songs = playlistMetadata {
            ToolbarItemGroup {
                // No toolbar items for .songs type (Now Playing)
            }
        } else {
            ToolbarItemGroup {
                DownloadAllButton(songs: songs)

                UploadButton(userInfo: userInfo, onRefresh: onRefresh)

                Menu {
                    Button(action: {
                        Task {
                            func playUsingPrefetchedSongs(_ songs: [CloudMusicApi.Song]) async {
                                guard !songs.isEmpty else { return }

                                let newItems = songs.map { song in
                                    loadItem(song: song)
                                }

                                guard !newItems.isEmpty else { return }

                                let startIndex =
                                    (await MainActor.run(resultType: Bool.self) {
                                        playlistStatus.loopMode == .shuffle
                                    } && newItems.count > 1)
                                    ? Int.random(in: 0..<newItems.count)
                                    : 0

                                await playlistStatus.replacePlaylist(
                                    newItems,
                                    continuePlaying: true,
                                    shouldSaveState: true,
                                    startIndex: startIndex
                                )
                            }

                            if model.hasActiveFilters {
                                let songsToPlay = await model.songsForPlayback(loadEntirePlaylist: true)
                                await playUsingPrefetchedSongs(songsToPlay)
                            } else {
                                let totalCount = await model.totalTrackCount()

                                if totalCount == 0 {
                                    let songsToPlay = await model.songsForPlayback(loadEntirePlaylist: true)
                                    await playUsingPrefetchedSongs(songsToPlay)
                                    return
                                }

                                let startIndex =
                                    (await MainActor.run(resultType: Bool.self) {
                                        playlistStatus.loopMode == .shuffle
                                    } && totalCount > 1)
                                    ? Int.random(in: 0..<totalCount)
                                    : 0

                                let songStream = model.streamSongsForPlayback(loadEntirePlaylist: true)
                                let itemStream = AsyncStream<[PlaylistItem]> { continuation in
                                    let streamTask = Task {
                                        for await chunk in songStream {
                                            let items = chunk.map { song in
                                                loadItem(song: song)
                                            }
                                            continuation.yield(items)
                                        }
                                        continuation.finish()
                                    }

                                    continuation.onTermination = { _ in
                                        streamTask.cancel()
                                    }
                                }

                                await playlistStatus.replacePlaylistStreaming(
                                    totalCount: totalCount,
                                    startIndex: startIndex,
                                    continuePlaying: true,
                                    shouldSaveState: true,
                                    itemStream: itemStream
                                )
                            }
                        }
                    }) {
                        Label("Play All", systemImage: "play")
                    }

                    Button(action: {
                        Task {
                            let songsToAdd = await model.songsForPlayback(loadEntirePlaylist: true)
                            guard !songsToAdd.isEmpty else { return }

                            let newItems = songsToAdd.map { song in
                                loadItem(song: song)
                            }

                            guard !newItems.isEmpty else { return }

                            let _ = await playlistStatus.addItemsToPlaylist(
                                newItems, continuePlaying: false, shouldSaveState: true)
                        }
                    }) {
                        Label("Add All to Playlist", systemImage: "plus")
                    }

                    if case .netease = playlistMetadata {
                        Button(action: onRefresh) {
                            Label("Refresh Playlist", systemImage: "arrow.clockwise")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .help("More Actions")
            }
        }
    }
}

struct UploadQueueItem: Identifiable {
    let id = UUID()
    let songId: UInt64
    let songName: String
    let url: URL
    var isCompleted: Bool = false
    var isFailed: Bool = false
    var isUploading: Bool = false
    var errorMessage: String?
}

struct UploadProgressRow: View {
    let item: UploadQueueItem
    let onRetry: (() -> Void)?

    private var truncatedErrorMessage: String {
        guard let errorMessage = item.errorMessage else { return "Upload failed" }
        return errorMessage.count > 25 ? String(errorMessage.prefix(25)) + "..." : errorMessage
    }

    var body: some View {
        HStack {
            Text(item.songName)
                .lineLimit(1)

            Spacer()

            if item.isCompleted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else if item.isFailed {
                HStack(spacing: 8) {
                    Text(truncatedErrorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                        .lineLimit(1)
                        .frame(maxWidth: 220, alignment: .trailing)
                        .help(item.errorMessage ?? "Upload failed")

                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                        .help(item.errorMessage ?? "Upload failed")
                    
                    Button(action: {
                        onRetry?()
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.borderless)
                    .help("Retry upload")
                }
            } else if item.isUploading {
                ProgressView()
                    .progressViewStyle(LinearProgressViewStyle())
                    .frame(width: 300)
            } else {
                HStack {
                    Image(systemName: "clock")
                        .foregroundColor(.orange)
                        .font(.system(size: 16))
                    Text("Waiting")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .frame(width: 300, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

struct UploadProgressDialog: View {
    @ObservedObject var uploadManager: UploadManager
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Upload to Cloud")
                    .font(.headline)
                Spacer()
            }

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(uploadManager.uploadQueue) { item in
                        UploadProgressRow(item: item) {
                            uploadManager.retryUpload(for: item)
                        }
                    }
                }
            }
            .frame(maxHeight: 200)

            HStack {
                Text("Completed: \(uploadManager.completedCount), Failed: \(uploadManager.failedCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                if uploadManager.isUploading {
                    Button(uploadManager.canceled ? "Canceling" : "Cancel") {
                        uploadManager.canceled = true
                    }
                    .disabled(uploadManager.canceled)
                }
            }
        }
        .padding(20)
        .frame(width: 500)
        .frame(minHeight: 150)
    }
}

@MainActor
class UploadManager: ObservableObject {
    @Published var uploadQueue: [UploadQueueItem] = []
    @Published var isUploading: Bool = false
    @Published var canceled: Bool = false

    private let userInfo: UserInfo
    private let onRefresh: (() -> Void)?

    init(userInfo: UserInfo, onRefresh: (() -> Void)? = nil) {
        self.userInfo = userInfo
        self.onRefresh = onRefresh
    }

    var completedCount: Int {
        uploadQueue.filter { $0.isCompleted }.count
    }

    var failedCount: Int {
        uploadQueue.filter { $0.isFailed }.count
    }

    var totalCount: Int {
        uploadQueue.count
    }

    var progress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(completedCount) / Double(totalCount)
    }

    func addUploadTask(songId: UInt64, songName: String, url: URL) {
        let item = UploadQueueItem(songId: songId, songName: songName, url: url)
        uploadQueue.append(item)

        if !isUploading {
            startUploading()
        }
    }
    
    func retryUpload(for item: UploadQueueItem) {
        guard let index = uploadQueue.firstIndex(where: { $0.id == item.id }) else { return }

        // Reset the item's state
        uploadQueue[index].isFailed = false
        uploadQueue[index].isCompleted = false
        uploadQueue[index].isUploading = false
        uploadQueue[index].errorMessage = nil

        // If not currently uploading, start the upload process
        if !isUploading {
            startUploading()
        }
    }

    private func startUploading() {
        isUploading = true
        canceled = false

        Task {
            await processUploadQueue()
        }
    }

    private func handleUploadError(index: Int, error: String) async {
        await MainActor.run {
            uploadQueue[index].isUploading = false
            uploadQueue[index].isFailed = true
            uploadQueue[index].errorMessage = error
        }
    }
    
    private func processUploadQueue() async {
        var hasAnySuccess = false

        while !canceled {
            // Find the next item that needs to be processed
            guard let nextIndex = await MainActor.run(body: {
                uploadQueue.firstIndex { item in
                    !item.isCompleted && !item.isUploading && !item.isFailed
                }
            }) else {
                // No more items to process
                break
            }

            // Mark current item as uploading
            await MainActor.run {
                uploadQueue[nextIndex].isUploading = true
            }

            let item = uploadQueue[nextIndex]

            do {
                let success = try await uploadCloudFile(
                    songId: item.songId, url: item.url, userInfo: userInfo)

                await MainActor.run {
                    uploadQueue[nextIndex].isUploading = false
                    uploadQueue[nextIndex].isCompleted = success
                    if !success {
                        uploadQueue[nextIndex].isFailed = true
                        uploadQueue[nextIndex].errorMessage = "Upload failed"
                    } else {
                        hasAnySuccess = true
                    }
                }
            } catch let error as RequestError {
                await handleUploadError(index: nextIndex, error: error.localizedDescription)
            } catch {
                await handleUploadError(index: nextIndex, error: error.localizedDescription)
            }
        }

        await MainActor.run {
            isUploading = false
            canceled = false

            // 如果有任何成功上传，发送刷新通知
            if hasAnySuccess {
                NotificationCenter.default.post(name: .refreshPlaylist, object: nil)
            }
        }
    }

    func clearCompleted() {
        uploadQueue.removeAll { $0.isCompleted }
    }

    func clearAll() {
        uploadQueue.removeAll()
        isUploading = false
        canceled = false
    }
}

struct UploadButton: View {
    let userInfo: UserInfo
    let onRefresh: (() -> Void)?

    @StateObject private var uploadManager: UploadManager
    @State private var showUploadDialog = false

    init(userInfo: UserInfo, onRefresh: (() -> Void)? = nil) {
        self.userInfo = userInfo
        self.onRefresh = onRefresh
        self._uploadManager = StateObject(
            wrappedValue: UploadManager(userInfo: userInfo, onRefresh: onRefresh))
    }

    var body: some View {
        Button(action: {
            showUploadDialog.toggle()
        }) {
            if uploadManager.isUploading && uploadManager.totalCount > 0 {
                // 显示上传中图标
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundColor(.blue)
                    .symbolEffect(.pulse, options: .repeating)
            } else if uploadManager.totalCount > 0 {
                // 根据成功和失败的数量显示不同的完成状态
                if uploadManager.failedCount > 0 && uploadManager.completedCount > 0 {
                    // 部分成功：有成功也有失败
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                } else if uploadManager.failedCount > 0 {
                    // 全部失败
                    Image(systemName: "xmark.circle")
                        .foregroundColor(.red)
                } else {
                    // 全部成功
                    Image(systemName: "checkmark.circle")
                        .foregroundColor(.green)
                }
            } else {
                // 默认状态
                Image(systemName: "icloud.and.arrow.up")
            }
        }
        .help(
            uploadManager.isUploading
                ? "Uploading \(uploadManager.completedCount)/\(uploadManager.totalCount)"
                : uploadManager.totalCount > 0
                    ? (uploadManager.failedCount > 0 && uploadManager.completedCount > 0
                        ? "Upload partially completed: \(uploadManager.completedCount) succeeded, \(uploadManager.failedCount) failed"
                        : uploadManager.failedCount > 0
                            ? "Upload completed with \(uploadManager.failedCount) failed"
                            : "Upload completed successfully")
                    : "Upload to Cloud"
        )
        .popover(isPresented: $showUploadDialog) {
            UploadProgressDialog(
                uploadManager: uploadManager,
                isPresented: $showUploadDialog
            )
        }
        .environmentObject(uploadManager)
        .onReceive(NotificationCenter.default.publisher(for: .uploadToCloud)) { notification in
            if let userInfo = notification.userInfo,
                let songId = userInfo["songId"] as? UInt64,
                let songName = userInfo["songName"] as? String,
                let url = userInfo["url"] as? URL
            {
                uploadManager.addUploadTask(songId: songId, songName: songName, url: url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshPlaylist)) { _ in
            onRefresh?()
        }
    }
}

struct DownloadAllButton: View {
    @State private var presentDownloadAllSongDialog = false
    @State private var canceledDownloadAllSong = false
    @State private var downloadProgress: Double = 0.0

    @State private var downloading = false
    @State private var showConfirmationPopover = false

    @State private var text: String = "Downloading"

    var songs: [CloudMusicApi.Song]

    var body: some View {
        Button(action: {
            if downloading {
                presentDownloadAllSongDialog.toggle()
                return
            }
            showConfirmationPopover = true
        }) {
            if downloading {
                ProgressView(value: downloadProgress)
                    .progressViewStyle(CircularProgressViewStyle())
                    .controlSize(.small)
            } else {
                Image(systemName: "square.and.arrow.down")
            }
        }
        .help(downloading ? "Downloading" : "Download All")
        .popover(
            isPresented: $showConfirmationPopover
        ) {
            VStack(spacing: 15) {
                Text("Download All Songs")
                    .font(.headline)

                Text("Are you sure you want to download all \(songs.count) songs?")
                    .multilineTextAlignment(.center)

                HStack(spacing: 10) {
                    Button("Cancel") {
                        showConfirmationPopover = false
                    }
                    .buttonStyle(.borderless)

                    Button("Download") {
                        showConfirmationPopover = false
                        presentDownloadAllSongDialog = true
                        downloading = true

                        Task {
                            let totalCnt = songs.count

                            for (idx, song) in songs.enumerated() {
                                text = "Downloading \(idx + 1) / \(totalCnt)"
                                if getCachedMusicFile(id: song.id) != nil {
                                } else {
                                    if let songData = await CloudMusicApi().song_url_v1(id: [
                                        song.id
                                    ]) {
                                        let songData = songData[0]
                                        let ext = songData.type
                                        if let url = URL(string: songData.url.https) {
                                            let _ = await downloadMusicFile(
                                                url: url, id: song.id, ext: ext)
                                        }
                                    }
                                }

                                downloadProgress = Double(idx + 1) / Double(totalCnt)

                                if canceledDownloadAllSong {
                                    break
                                }
                            }
                            canceledDownloadAllSong = false
                            presentDownloadAllSongDialog = false
                            downloading = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(width: 400)
        }
        .popover(
            isPresented: $presentDownloadAllSongDialog
        ) {
            DownloadProgressDialog(
                text: text,
                value: $downloadProgress,
                canceled: $canceledDownloadAllSong
            )
        }
    }
}

struct PlayListView: View {
    @StateObject var model = PlaylistDetailModel()

    @EnvironmentObject private var userInfo: UserInfo
    @EnvironmentObject var playlistStatus: PlaylistStatus

    @State private var selectedItem: CloudMusicApi.Song.ID?
    @State private var sortOrder = [KeyPathComparator<CloudMusicApi.Song>]()
    @State private var loadingTask: Task<Void, Never>? = nil
    @State private var currentLoadingTaskId = UUID()

    @State private var searchText = ""
    @State private var searchDebounceTask: Task<Void, Never>? = nil
    @State private var selectedSongToAdd: CloudMusicApi.Song?

    var playlistMetadata: PlaylistMetadata?
    var onLoadComplete: (() -> Void)?

    private func handleUploadToCloud(song: CloudMusicApi.Song, url: URL) async {
        // 发送通知给 UploadButton 来处理上传队列
        NotificationCenter.default.post(
            name: .uploadToCloud,
            object: nil,
            userInfo: [
                "songId": song.id,
                "songName": song.name,
                "url": url,
            ]
        )
    }

    var body: some View {
        ZStack {
            SongTableView(
                songs: model.songs,
                selectedItem: $selectedItem,
                sortOrder: $sortOrder,
                userInfo: userInfo,
                playlistStatus: playlistStatus,
                playlistMetadata: playlistMetadata,
                onSortChange: handleSortChange,
                selectedSongToAdd: $selectedSongToAdd,
                onDeleteFromPlaylist: { song in
                    Task {
                        if case .netease(let songId, _) = playlistMetadata {
                            do {
                                try await CloudMusicApi(cacheTtl: 0).playlist_tracks(
                                    op: .del, playlistId: songId,
                                    trackIds: [song.id])
                                NotificationCenter.default.post(
                                    name: .refreshPlaylist,
                                    object: nil,
                                )

                                updatePlaylist(force: true)
                            } catch let error as RequestError {
                                AlertModal.showAlert(error.localizedDescription)
                            } catch {
                                AlertModal.showAlert(error.localizedDescription)
                            }
                        }
                    }
                },
                onUploadToCloud: { song, url in
                    // 暂时保持原来的上传方法
                    Task {
                        await handleUploadToCloud(song: song, url: url)
                    }
                },
                onLoadMore: {
                    // Incremental loading callback
                    if model.hasMoreSongs && !model.isLoadingMore {
                        Task {
                            await model.loadMoreSongs()
                        }
                    }
                },
                isLoadingMore: model.isLoadingMore,
                hasMoreSongs: model.hasMoreSongs
            )
            .onChange(of: searchText) { _, newValue in
                searchDebounceTask?.cancel()
                let query = newValue
                searchDebounceTask = Task {
                    try? await Task.sleep(nanoseconds: 220_000_000)
                    if Task.isCancelled { return }

                    await MainActor.run {
                        model.applySearch(by: query)
                        model.update()
                    }

                    if !query.isEmpty && !model.allSongsLoaded {
                        await model.loadAllSongsInBackground()
                    }
                }
            }
            .sheet(
                isPresented: Binding<Bool>(
                    get: { selectedSongToAdd != nil },
                    set: { if !$0 { selectedSongToAdd = nil } }
                )
            ) {
                if let selectedSong = selectedSongToAdd {
                    ListPlaylistDialogView { selectedPlaylist in
                        Task {
                            do {
                                try await CloudMusicApi(cacheTtl: 0).playlist_tracks(
                                    op: .add, playlistId: selectedPlaylist.id,
                                    trackIds: [selectedSong.id])

                                if playlistMetadata?.id == selectedPlaylist.id {
                                    NotificationCenter.default.post(
                                        name: .refreshPlaylist,
                                        object: nil
                                    )
                                }
                            } catch let error as RequestError {
                                AlertModal.showAlert(error.localizedDescription)
                            } catch {
                                AlertModal.showAlert(error.localizedDescription)
                            }
                        }
                    }
                }
            }
            .navigationTitle((playlistMetadata?.name) ?? "Playlist")
            .searchable(text: $searchText, prompt: "Search in Playlist")
            .toolbar {
                PlaylistToolbar(
                    model: model,
                    songs: model.songs ?? [],
                    playlistMetadata: playlistMetadata,
                    playlistStatus: playlistStatus,
                    userInfo: userInfo,
                    onRefresh: {
                        Task {
                            updatePlaylist(force: true)
                        }
                    }
                )
            }
            .onChange(of: playlistMetadata?.id) {
                clearExistingData()
                updatePlaylist()
            }
            .task {
                updatePlaylist()
            }
            .onDisappear {
                loadingTask?.cancel()
                searchDebounceTask?.cancel()
            }
            .onReceive(NotificationCenter.default.publisher(for: .refreshPlaylist)) { _ in
                Task {
                    updatePlaylist(force: true)
                }
            }

            if model.isLoading {
                LoadingIndicatorView()
            }
        }
    }

    private func clearExistingData() {
        model.songs = nil
        model.originalSongs = nil
        model.curId = nil

        // Reset incremental loading state
        model.isLoading = false
        model.isLoadingMore = false
        model.hasMoreSongs = false
        model.allSongsLoaded = false

        searchText = ""
        sortOrder = []
        searchDebounceTask?.cancel()
    }

    private func updatePlaylist(force: Bool = false) {
        if let playlistMetadata = playlistMetadata {
            // Use model's isLoading property instead of local isLoading
            model.isLoading = true

            model.curId = playlistMetadata.id
            loadingTask?.cancel()

            // Generate a new task ID for this loading operation
            let taskId = UUID()
            currentLoadingTaskId = taskId

            loadingTask = Task {
                await model.updatePlaylistDetail(metadata: playlistMetadata, force: force)

                // Only update loading state if this is still the current task
                if taskId == currentLoadingTaskId {
                    // Call the completion callback on main actor
                    await MainActor.run {
                        onLoadComplete?()
                    }
                }

                searchText = ""
            }
        }
    }

    private func handleSortChange(sortOrder: [KeyPathComparator<CloudMusicApi.Song>]) {
        guard !sortOrder.isEmpty else {
            DispatchQueue.main.async { self.sortOrder = [] }
            model.resetSorting()
            model.update()
            return
        }

        DispatchQueue.main.async { self.sortOrder = sortOrder }
        model.applySorting(by: [sortOrder[0]])
        model.update()
    }
}
