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
    var results: [CloudMusicApi.Song] = []
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
                name: "每日歌曲推荐",
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
            try? await Task.sleep(for: .milliseconds(180))
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
            guard let self,
                  !Task.isCancelled,
                  self.query.trimmingCharacters(in: .whitespacesAndNewlines) == query
            else { return }
            self.results = response?.map { $0.convertToSong() } ?? []
            self.isSearching = false
            if response == nil {
                self.errorMessage = String(localized: "search.failed")
            }
        }
    }

    func submitSearch() {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        if query.hasPrefix("##%%ID"), let id = UInt64(query.dropFirst(6)) {
            searchSong(id: id)
            self.query = ""
        } else {
            search()
        }
    }

    func searchSong(id: UInt64) {
        searchTask?.cancel()
        isSearching = true
        errorMessage = nil
        searchTask = Task { [weak self, repository] in
            let response = await repository.songs(ids: [id])
            guard let self, !Task.isCancelled else { return }
            self.results = response ?? []
            self.isSearching = false
            if response == nil {
                self.errorMessage = String(localized: "search.failed")
            }
        }
    }
}
