import Foundation
import XCTest

@testable import MusicBox

final class FeatureModelsTests: XCTestCase {
    @MainActor
    func testSearchDebounceCancelsTheSupersededQuery() async {
        let repository = RecordingCatalogRepository()
        let model = ExploreFeatureModel(repository: repository)

        model.updateQuery("first")
        model.updateQuery("second")
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(repository.suggestionQueries, ["second"])
    }

    @MainActor
    func testSearchFailureClearsLoadingStateAndExposesRetryMessage() async {
        let repository = RecordingCatalogRepository()
        let model = ExploreFeatureModel(repository: repository)

        model.updateQuery("missing")
        model.search()
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(model.errorMessage, String(localized: "search.failed"))
    }
}

@MainActor
private final class RecordingCatalogRepository: CatalogRepository {
    private(set) var suggestionQueries: [String] = []

    func recommendedResources() async -> [CloudMusicApi.RecommandPlaylistItem]? {
        nil
    }

    func searchSuggestions(for query: String) async -> [CloudMusicApi.SearchResult.Song]? {
        suggestionQueries.append(query)
        return []
    }

    func searchSongs(_ query: String, limit _: Int, offset _: Int) async -> [CloudMusicApi.SearchResult.Song]? {
        nil
    }

    func playlistDetail(id _: UInt64) async -> (tracks: [CloudMusicApi.Song], trackIDs: [UInt64])? {
        nil
    }

    func songs(ids _: [UInt64]) async -> [CloudMusicApi.Song]? {
        nil
    }

    func updatePlaylistTracks(
        _: CloudMusicApi.PlaylistTracksOp,
        playlistID _: UInt64,
        trackIDs _: [UInt64]
    ) async throws {}
}
