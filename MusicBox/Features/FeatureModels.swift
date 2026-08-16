import Foundation
import Observation

@MainActor
@Observable
final class ExploreFeatureModel {
    private let repository: any CatalogRepository
    private var recommendationTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    var recommendations: [CloudMusicApi.RecommandPlaylistItem]
    var query = ""
    var suggestions: [CloudMusicApi.SearchResult.Song] = []
    var results: [CloudMusicApi.SearchResult.Song] = []
    var isLoadingRecommendations = false
    var isSearching = false
    var errorMessage: String?

    init(repository: any CatalogRepository) {
        self.repository = repository
        let day = Calendar.current.component(.day, from: Date())
        recommendations = [
            CloudMusicApi.RecommandPlaylistItem(
                creator: nil,
                picUrl: "\(day).square",
                userId: nil,
                id: CloudMusicApi.RecommandSongPlaylistId,
                name: String(localized: "explore.daily_recommendations"),
                playcount: nil,
                trackCount: nil
            )
        ]
    }

    func loadRecommendations() {
        recommendationTask?.cancel()
        isLoadingRecommendations = true
        recommendationTask = Task { [weak self, repository] in
            let response = await repository.recommendedResources()
            guard let self, !Task.isCancelled else { return }
            if let response {
                self.recommendations = self.recommendations.prefix(1).map { $0 } + response
            }
            self.isLoadingRecommendations = false
        }
    }

    func updateQuery(_ query: String) {
        self.query = query
        searchTask?.cancel()
        suggestions = []
        results = []
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchTask = Task { [weak self, repository] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let suggestions = await repository.searchSuggestions(for: trimmed) ?? []
            guard let self, !Task.isCancelled, self.query == query else { return }
            self.suggestions = suggestions
        }
    }

    func search() {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchTask?.cancel()
        isSearching = true
        errorMessage = nil
        searchTask = Task { [weak self, repository] in
            let response = await repository.searchSongs(query, limit: 60, offset: 0)
            guard let self, !Task.isCancelled, self.query.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            self.results = response ?? []
            self.isSearching = false
            if response == nil {
                self.errorMessage = String(localized: "search.failed")
            }
        }
    }

}

@MainActor
@Observable
final class PlaylistFeatureModel {
    let destination: PlaylistDestination
    private let repository: any CatalogRepository
    private let pageSize = 100
    private var trackIDs: [UInt64] = []
    private var loadTask: Task<Void, Never>?
    private var moreTask: Task<Void, Never>?

    var songs: [CloudMusicApi.Song] = []
    var isLoading = false
    var isLoadingMore = false
    var hasMore = false
    var errorMessage: String?

    init(destination: PlaylistDestination, repository: any CatalogRepository) {
        self.destination = destination
        self.repository = repository
    }

    var items: [PlaylistItem] {
        let source = PlaybackSourcePlaylist(id: destination.id, name: destination.name)
        return songs.map { PlaylistItemFactory.make(song: $0, sourcePlaylist: source) }
    }

    func load() {
        loadTask?.cancel()
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

}

@MainActor
@Observable
final class CloudFilesFeatureModel {
    private let repository: any CloudRepository
    private let pageSize = 100
    private var queryTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    var files: [CloudMusicApi.CloudFile] = []
    var query = ""
    var isLoading = false
    var isLoadingMore = false
    var hasMore = true
    var errorMessage: String?

    init(repository: any CloudRepository) {
        self.repository = repository
    }

    var filteredFiles: [CloudMusicApi.CloudFile] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return files }
        return files.filter { file in
            file.fileName.lowercased().contains(query)
                || (file.simpleSong?.name?.lowercased().contains(query) ?? false)
        }
    }

    func updateQuery(_ query: String) {
        self.query = query
        queryTask?.cancel()
        queryTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
        }
    }

    func load(reset: Bool = false) {
        guard !isLoading else { return }
        if reset {
            files = []
            hasMore = true
        }
        isLoading = true
        errorMessage = nil
        loadTask?.cancel()
        loadTask = Task { [weak self, repository] in
            let response = await repository.cloudFiles(limit: self?.pageSize ?? 100, offset: 0)
            guard let self, !Task.isCancelled else { return }
            self.files = response ?? []
            self.hasMore = (response?.count ?? 0) == self.pageSize
            self.isLoading = false
            if response == nil { self.errorMessage = String(localized: "cloud.load.failed") }
        }
    }

    func loadMore() {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        let offset = files.count
        Task { [weak self, repository] in
            let response = await repository.cloudFiles(limit: self?.pageSize ?? 100, offset: offset)
            guard let self, !Task.isCancelled else { return }
            let newFiles = response ?? []
            let existing = Set(self.files.map(\.pcId))
            self.files.append(contentsOf: newFiles.filter { !existing.contains($0.pcId) })
            self.hasMore = newFiles.count == self.pageSize
            self.isLoadingMore = false
        }
    }

    func match(_ file: CloudMusicApi.CloudFile, to songID: UInt64, userID: UInt64) async throws {
        try await repository.matchCloudFile(userID: userID, songID: file.privateCloud.songId, adjustedSongID: songID)
        load(reset: true)
    }

}

@MainActor
@Observable
final class LoginFeatureModel {
    private let repository: any AccountRepository
    private var qrPollTask: Task<Void, Never>?

    var phone = ""
    var countryCode = "86"
    var password = ""
    var qrCodeURL: URL?
    var isSubmitting = false
    var errorMessage: String?

    init(repository: any AccountRepository) {
        self.repository = repository
    }

    func loginWithPassword(onSuccess: @escaping () async -> Void) {
        guard let countryCode = Int(countryCode.trimmingCharacters(in: .whitespacesAndNewlines)), countryCode > 0 else {
            errorMessage = String(localized: "login.country_code.invalid")
            return
        }
        isSubmitting = true
        errorMessage = nil
        Task { [weak self, repository] in
            guard let self else { return }
            let result = await repository.login(
                phone: self.phone.trimmingCharacters(in: .whitespacesAndNewlines),
                countryCode: countryCode,
                password: self.password
            )
            self.isSubmitting = false
            if let result {
                self.errorMessage = result
            } else {
                await onSuccess()
            }
        }
    }

    func beginQRCodeLogin(onSuccess: @escaping () async -> Void) {
        qrPollTask?.cancel()
        isSubmitting = true
        errorMessage = nil
        qrPollTask = Task { [weak self, repository] in
            guard let self else { return }
            do {
                let key = try await repository.requestQRCodeKey()
                self.qrCodeURL = URL(string: try await repository.qrCodeURL(for: key))
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    let result = try await repository.checkQRCode(key)
                    if result.code == 803 {
                        self.isSubmitting = false
                        await onSuccess()
                        return
                    }
                    if result.code == 800 || result.code == 802 {
                        self.errorMessage = result.message
                        self.isSubmitting = false
                        return
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                self.isSubmitting = false
            }
        }
    }

}

enum CommentsTargetKind: String, Codable, Hashable {
    case playlist
    case song
}

struct CommentsTarget: Hashable, Codable, Identifiable {
    let kind: CommentsTargetKind
    let resourceID: UInt64
    let name: String
    let subtitle: String?

    var id: String { "\(kind.rawValue)-\(resourceID)" }
    var resourceType: CloudMusicApi.CommentResourceType { kind == .playlist ? .playlist : .music }
    var title: String { subtitle.map { "\(name) - \($0)" } ?? name }
}

enum CommentsSort: CaseIterable, Identifiable, Equatable {
    case hot
    case recommend
    case time

    var id: Self { self }
    var apiValue: CloudMusicApi.CommentNewSortType {
        switch self {
        case .hot: return .hot
        case .recommend: return .recommend
        case .time: return .time
        }
    }
}

@MainActor
@Observable
final class CommentsFeatureModel {
    let target: CommentsTarget
    private let repository: any CommentsRepository
    private var loadTask: Task<Void, Never>?
    private let pageSize = 30
    private var page = 0
    private var cursor: Int64?
    private var seenCommentIDs: Set<UInt64> = []

    var comments: [CloudMusicApi.Comment] = []
    var sort = CommentsSort.hot
    var hasMore = false
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?

    init(target: CommentsTarget, repository: any CommentsRepository) {
        self.target = target
        self.repository = repository
    }

    func load(reset: Bool = true) {
        if reset {
            page = 0
            cursor = nil
            comments = []
            seenCommentIDs = []
        }
        guard !isLoading && !isLoadingMore else { return }
        isLoading = true
        errorMessage = nil
        fetch(nextPage: 1, cursor: nil, replacing: true)
    }

    func changeSort(_ sort: CommentsSort) {
        guard self.sort != sort else { return }
        self.sort = sort
        load()
    }

    func loadMore() {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        fetch(nextPage: page + 1, cursor: sort == .time ? cursor : nil, replacing: false)
    }

    private func fetch(nextPage: Int, cursor: Int64?, replacing: Bool) {
        loadTask?.cancel()
        let target = target
        let sort = sort
        loadTask = Task { [weak self, repository] in
            do {
                let response = try await repository.comments(
                    type: target.resourceType,
                    id: target.resourceID,
                    page: nextPage,
                    pageSize: self?.pageSize ?? 30,
                    sort: sort.apiValue,
                    cursor: cursor
                )
                guard let self, !Task.isCancelled, self.sort == sort else { return }
                let newComments = (response.comments ?? []).filter { self.seenCommentIDs.insert($0.commentId).inserted }
                if replacing {
                    self.comments = newComments
                } else {
                    self.comments.append(contentsOf: newComments)
                }
                self.page = nextPage
                self.hasMore = response.hasMore ?? false
                if case let .int(value)? = response.cursor {
                    self.cursor = Int64(value)
                } else if case let .string(value)? = response.cursor {
                    self.cursor = Int64(value)
                }
                self.isLoading = false
                self.isLoadingMore = false
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                self.isLoading = false
                self.isLoadingMore = false
            }
        }
    }

}
