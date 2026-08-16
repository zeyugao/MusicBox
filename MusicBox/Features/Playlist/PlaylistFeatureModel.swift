import Foundation
import Observation

@MainActor
@Observable
final class PlaylistFeatureModel {
    let destination: PlaylistDestination
    private let repository: any PlaylistRepository
    private let pageSize = 100
    private var trackIDs: [UInt64] = []
    private var loadTask: Task<Void, Never>?
    private var moreTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private let usesInitialSongs: Bool
    private let playbackSource: PlaybackSourcePlaylist?

    var songs: [CloudMusicApi.Song] = []
    var query = ""
    var sort: PlaylistSongSort?
    var isLoading = false
    var isLoadingMore = false
    var hasMore = false
    var errorMessage: String?

    init(
        destination: PlaylistDestination,
        repository: any PlaylistRepository,
        initialSongs: [CloudMusicApi.Song]? = nil,
        sourcePlaylist: PlaybackSourcePlaylist? = nil
    ) {
        self.destination = destination
        self.repository = repository
        usesInitialSongs = initialSongs != nil
        songs = initialSongs ?? []
        playbackSource = sourcePlaylist ?? (initialSongs == nil
            ? PlaybackSourcePlaylist(id: destination.id, name: destination.name)
            : nil)
    }

    var items: [PlaylistItem] {
        songs.map { PlaylistItemFactory.make(song: $0, sourcePlaylist: playbackSource) }
    }

    var isRemotePlaylist: Bool { !usesInitialSongs }

    func item(for song: CloudMusicApi.Song) -> PlaylistItem {
        PlaylistItemFactory.make(song: song, sourcePlaylist: playbackSource)
    }

    var visibleSongs: [CloudMusicApi.Song] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var visible = normalizedQuery.isEmpty ? songs : songs.filter { song in
            song.name.lowercased().contains(normalizedQuery)
                || song.ar.compactMap(\.name).joined(separator: ", ").lowercased().contains(normalizedQuery)
                || song.albumName.lowercased().contains(normalizedQuery)
        }
        guard let sort else { return visible }
        visible.sort(using: sort.comparator)
        return visible
    }

    func load() {
        guard !usesInitialSongs else { return }
        loadTask?.cancel()
        moreTask?.cancel()
        isLoadingMore = false
        isLoading = true
        errorMessage = nil
        loadTask = Task { [weak self, repository] in
            let detail = await repository.playlistDetail(id: self?.destination.id ?? 0)
            guard let self, !Task.isCancelled else { return }
            guard let detail else {
                self.isLoading = false
                self.errorMessage = String(localized: "playlist.load.failed")
                return
            }
            self.songs = detail.tracks
            self.trackIDs = detail.trackIDs
            self.hasMore = detail.trackIDs.count > detail.tracks.count
            self.isLoading = false
        }
    }

    func loadMore() {
        guard hasMore, !isLoadingMore else { return }
        let loaded = Set(songs.map(\.id))
        let ids = trackIDs.filter { !loaded.contains($0) }.prefix(pageSize)
        guard !ids.isEmpty else {
            hasMore = false
            return
        }
        isLoadingMore = true
        moreTask = Task { [weak self, repository] in
            let fetched = await repository.songs(ids: Array(ids)) ?? []
            guard let self, !Task.isCancelled else { return }
            var existing = Set(self.songs.map(\.id))
            self.songs.append(contentsOf: fetched.filter { existing.insert($0.id).inserted })
            self.hasMore = self.songs.count < self.trackIDs.count
            self.isLoadingMore = false
        }
    }

    func retry() {
        load()
    }

    func updateQuery(_ query: String) {
        self.query = query
        searchTask?.cancel()
        let shouldLoadEverything = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard shouldLoadEverything, hasMore else { return }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard let self, !Task.isCancelled else { return }
            while self.hasMore, !Task.isCancelled {
                self.loadMore()
                while self.isLoadingMore, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }
    }

    func setSort(_ sort: PlaylistSongSort?) {
        self.sort = sort
    }

    func cycleSort(column: PlaylistSongSortColumn) {
        guard let sort, sort.column == column else {
            self.sort = PlaylistSongSort(column: column, order: .forward)
            return
        }
        self.sort = sort.order == .forward
            ? PlaylistSongSort(column: column, order: .reverse)
            : nil
    }

    func delete(_ songsToDelete: [CloudMusicApi.Song]) async throws {
        guard !usesInitialSongs, !songsToDelete.isEmpty else { return }
        let ids = songsToDelete.map(\.id)
        try await repository.updatePlaylistTracks(.del, playlistID: destination.id, trackIDs: ids)
        let idsToRemove = Set(ids)
        songs.removeAll { idsToRemove.contains($0.id) }
        trackIDs.removeAll { idsToRemove.contains($0) }
    }

    func add(_ songsToAdd: [CloudMusicApi.Song], to playlistID: UInt64) async throws {
        guard !songsToAdd.isEmpty else { return }
        try await repository.updatePlaylistTracks(
            .add,
            playlistID: playlistID,
            trackIDs: songsToAdd.map(\.id)
        )
    }

}

enum PlaylistSongSortColumn: String, CaseIterable, Identifiable {
    case title
    case artist
    case album
    case duration

    var id: String { rawValue }
}

struct PlaylistSongSort: Equatable {
    let column: PlaylistSongSortColumn
    let order: SortOrder

    var comparator: KeyPathComparator<CloudMusicApi.Song> {
        switch column {
        case .title:
            return KeyPathComparator(\.name, order: order)
        case .artist:
            return KeyPathComparator(\.ar[0].name, order: order)
        case .album:
            return KeyPathComparator(\.albumName, order: order)
        case .duration:
            return KeyPathComparator(\.dt, order: order)
        }
    }
}
