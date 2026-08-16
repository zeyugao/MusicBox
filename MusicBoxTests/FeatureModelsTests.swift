import AppKit
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

    @MainActor
    func testPlaylistLoadsInitialPageThenRemainingTracks() async {
        let repository = RecordingPlaylistRepository()
        repository.detail = (tracks: [makeSong(id: 1)], trackIDs: [1, 2])
        repository.songsByID = [2: makeSong(id: 2)]
        let model = PlaylistFeatureModel(
            destination: PlaylistDestination(id: 99, name: "Playlist"),
            repository: repository
        )

        model.load()
        await waitUntil { !model.isLoading }
        XCTAssertEqual(model.songs.map(\.id), [1])
        XCTAssertTrue(model.hasMore)

        model.loadMore()
        await waitUntil { !model.isLoadingMore }
        XCTAssertEqual(model.songs.map(\.id), [1, 2])
        XCTAssertFalse(model.hasMore)
    }

    @MainActor
    func testCloudSearchLoadsRemainingPagesBeforeFiltering() async {
        let repository = RecordingCloudRepository()
        repository.firstPage = (0..<100).map { makeCloudFile(id: UInt64($0), name: "file-\($0)") }
        repository.secondPage = [makeCloudFile(id: 100, name: "needle.flac")]
        let model = CloudFilesFeatureModel(repository: repository)

        model.load()
        await waitUntil { !model.isLoading }
        model.updateQuery("needle")
        await waitUntil { model.files.count == 101 }

        XCTAssertEqual(model.filteredFiles.map(\.fileName), ["needle.flac"])
        XCTAssertEqual(repository.offsets, [0, 100])
    }

    @MainActor
    func testCommentsSortReloadsAndFloorRepliesStayInModel() async {
        let repository = RecordingCommentsRepository()
        let target = CommentsTarget(kind: .song, resourceID: 7, name: "Song", subtitle: nil)
        let model = CommentsFeatureModel(target: target, repository: repository)

        model.load()
        await waitUntil { !model.isLoading }
        XCTAssertEqual(model.comments.map(\.commentId), [1])

        model.changeSort(.time)
        await waitUntil { !model.isLoading }
        XCTAssertEqual(model.comments.map(\.commentId), [2])
        XCTAssertEqual(repository.sorts, [.hot, .time])

        model.loadFloor(parentCommentID: 2)
        await waitUntil { !model.floorLoadingIDs.contains(2) }
        XCTAssertEqual(model.floorThreads[2]?.comments.map(\.commentId), [3])
    }

    @MainActor
    func testWebLoginOnlyAcceptsAnAuthenticatedMusicCookie() {
        let repository = RecordingAccountRepository()
        let model = WebLoginFeatureModel(repository: repository)
        let unauthenticated = makeCookie(name: "__csrf", value: "csrf")
        let authenticated = makeCookie(name: "MUSIC_U", value: "token")

        XCTAssertFalse(model.acceptLoginCookies([unauthenticated]))
        XCTAssertNil(repository.cookie)
        XCTAssertTrue(model.acceptLoginCookies([unauthenticated, authenticated]))
        XCTAssertEqual(repository.cookie, "__csrf=csrf; MUSIC_U=token")
        XCTAssertTrue(model.isLoggedIn)
    }

    @MainActor
    func testSongTableControllerOnlyEmitsActivationForAValidRow() {
        let controller = SongTableViewController()
        controller.songs = [makeSong(id: 10), makeSong(id: 11)]
        var activatedIDs: [UInt64] = []
        controller.onActivate = { activatedIDs.append($0.id) }

        controller.activateSong(at: -1)
        controller.activateSong(at: 1)
        controller.activateSong(at: 2)

        XCTAssertEqual(activatedIDs, [11])
        XCTAssertEqual(controller.numberOfRows(in: NSTableView()), 5)
        XCTAssertTrue(controller.tableView(NSTableView(), shouldSelectRow: 1))
        XCTAssertFalse(controller.tableView(NSTableView(), shouldSelectRow: 2))
    }

    @MainActor
    func testTransferCenterSerializesEachDirectionAndRunsDirectionsConcurrently() async {
        let harness = TransferOperationHarness()
        let center = makeTransferCenter(harness: harness)
        let firstUpload = URL(fileURLWithPath: "/tmp/first.flac")
        let secondUpload = URL(fileURLWithPath: "/tmp/second.flac")

        center.enqueueUpload(fileURL: firstUpload, title: nil, artist: nil, album: nil)
        center.enqueueUpload(fileURL: secondUpload, title: nil, artist: nil, album: nil)
        center.enqueueDownloads([
            PlaylistItemFactory.make(song: makeSong(id: 1)),
            PlaylistItemFactory.make(song: makeSong(id: 2)),
        ])

        await waitUntil { harness.uploadNames == ["first.flac"] && harness.downloadNames == ["Song 1"] }
        XCTAssertEqual(center.jobs.filter { $0.phase == .running }.count, 2)
        XCTAssertEqual(center.jobs.filter { $0.phase == .waiting }.count, 2)

        harness.reportUpload(completed: 40, total: 100)
        await waitUntil { center.jobs.first?.progress?.fraction == 0.4 }
        harness.finishUpload()
        harness.finishDownload()

        await waitUntil { harness.uploadNames.count == 2 && harness.downloadNames.count == 2 }
        harness.finishUpload()
        harness.finishDownload()
        await waitUntil { center.jobs.allSatisfy { $0.phase == .succeeded } }

        center.clearFinished(in: .upload)
        XCTAssertEqual(center.jobs.map(\.direction), [.download, .download])
    }

    @MainActor
    func testTransferCenterClampsProgressCancelsAndIgnoresStaleAttempts() async {
        let harness = TransferOperationHarness()
        let center = makeTransferCenter(harness: harness)
        center.enqueueUpload(
            fileURL: URL(fileURLWithPath: "/tmp/retry.flac"),
            title: nil,
            artist: nil,
            album: nil
        )
        center.enqueueUpload(
            fileURL: URL(fileURLWithPath: "/tmp/waiting.flac"),
            title: nil,
            artist: nil,
            album: nil
        )
        await waitUntil { harness.uploadProgressHandlers.count == 1 }

        let staleProgress = harness.uploadProgressHandlers[0]
        harness.reportUpload(completed: 80, total: 100)
        harness.reportUpload(completed: 30, total: 100)
        await waitUntil { center.jobs[0].progress?.fraction == 0.8 }

        center.cancel(.upload)
        harness.finishUpload()
        await waitUntil { center.jobs.allSatisfy { $0.phase == .cancelled } }

        let firstID = center.jobs[0].id
        center.retry(firstID)
        await waitUntil { harness.uploadProgressHandlers.count == 2 }
        staleProgress(TransferProgress(completedBytes: 100, totalBytes: 100, stage: .transferring))
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(center.jobs[0].progress?.completedBytes, 0)

        harness.reportUpload(completed: 150, total: 100)
        await waitUntil { center.jobs[0].progress?.fraction == 1 }
        harness.finishUpload()
        await waitUntil { center.jobs[0].phase == .succeeded }
        center.clearFinished()
        XCTAssertTrue(center.jobs.isEmpty)
    }

    @MainActor
    private func makeTransferCenter(harness: TransferOperationHarness) -> TransferCenter {
        TransferCenter(
            upload: { fileURL, _, _, _, progress in
                try await harness.upload(fileURL, progress: progress)
            },
            download: { item, progress in
                try await harness.download(item, progress: progress)
            }
        )
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }
}

@MainActor
private final class TransferOperationHarness {
    private var uploadContinuations: [CheckedContinuation<Void, Never>] = []
    private var downloadContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var uploadNames: [String] = []
    private(set) var downloadNames: [String] = []
    private(set) var uploadProgressHandlers: [TransferProgressHandler] = []

    func upload(_ fileURL: URL, progress: @escaping TransferProgressHandler) async throws {
        uploadNames.append(fileURL.lastPathComponent)
        uploadProgressHandlers.append(progress)
        await withCheckedContinuation { uploadContinuations.append($0) }
    }

    func download(_ item: PlaylistItem, progress: @escaping TransferProgressHandler) async throws {
        downloadNames.append(item.title)
        await withCheckedContinuation { downloadContinuations.append($0) }
    }

    func reportUpload(completed: Int64, total: Int64) {
        uploadProgressHandlers.last?(
            TransferProgress(
                completedBytes: completed,
                totalBytes: total,
                stage: .transferring
            )
        )
    }

    func finishUpload() {
        uploadContinuations.removeFirst().resume()
    }

    func finishDownload() {
        downloadContinuations.removeFirst().resume()
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

@MainActor
private final class RecordingAccountRepository: AccountRepository {
    var cookie: String?

    func loginStatus() async -> CloudMusicApi.Profile? { nil }
    func userPlaylists(for _: UInt64) async throws -> [CloudMusicApi.PlayListItem]? { nil }
    func likedSongIDs(for _: UInt64) async -> [UInt64]? { nil }
    func setLiked(songID _: UInt64, liked _: Bool) async throws {}
    func setCookie(_ cookie: String) { self.cookie = cookie }
    func currentCookie() -> String? { cookie }
    func logout() async { cookie = nil }
}

@MainActor
private final class RecordingPlaylistRepository: PlaylistRepository {
    var detail: (tracks: [CloudMusicApi.Song], trackIDs: [UInt64])?
    var songsByID: [UInt64: CloudMusicApi.Song] = [:]

    func recommendedResources() async -> [CloudMusicApi.RecommandPlaylistItem]? { nil }
    func searchSuggestions(for _: String) async -> [CloudMusicApi.SearchResult.Song]? { nil }
    func searchSongs(_: String, limit _: Int, offset _: Int) async -> [CloudMusicApi.SearchResult.Song]? { nil }
    func playlistDetail(id _: UInt64) async -> (tracks: [CloudMusicApi.Song], trackIDs: [UInt64])? { detail }
    func songs(ids: [UInt64]) async -> [CloudMusicApi.Song]? { ids.compactMap { songsByID[$0] } }
    func updatePlaylistTracks(
        _: CloudMusicApi.PlaylistTracksOp,
        playlistID _: UInt64,
        trackIDs _: [UInt64]
    ) async throws {}
    func cloudFiles(limit _: Int, offset _: Int) async -> [CloudMusicApi.CloudFile]? { nil }
    func uploadCloudFile(
        _: URL,
        title _: String?,
        artist _: String?,
        album _: String?,
        progress _: @escaping TransferProgressHandler
    ) async throws -> UInt64? { nil }
    func matchCloudFile(userID _: UInt64, songID _: UInt64, adjustedSongID _: UInt64) async throws {}
    func audioURL(for _: UInt64) async -> CloudMusicApi.SongData? { nil }
    func lyrics(for _: UInt64) async -> CloudMusicApi.LyricNew? { nil }
}

@MainActor
private final class RecordingCloudRepository: CloudRepository {
    var firstPage: [CloudMusicApi.CloudFile] = []
    var secondPage: [CloudMusicApi.CloudFile] = []
    private(set) var offsets: [Int] = []

    func cloudFiles(limit _: Int, offset: Int) async -> [CloudMusicApi.CloudFile]? {
        offsets.append(offset)
        return offset == 0 ? firstPage : secondPage
    }

    func uploadCloudFile(
        _: URL,
        title _: String?,
        artist _: String?,
        album _: String?,
        progress _: @escaping TransferProgressHandler
    ) async throws -> UInt64? { nil }
    func matchCloudFile(userID _: UInt64, songID _: UInt64, adjustedSongID _: UInt64) async throws {}
}

@MainActor
private final class RecordingCommentsRepository: CommentsRepository {
    private(set) var sorts: [CloudMusicApi.CommentNewSortType] = []

    func comments(
        type _: CloudMusicApi.CommentResourceType,
        id _: UInt64,
        page _: Int,
        pageSize _: Int,
        sort: CloudMusicApi.CommentNewSortType,
        cursor _: Int64?
    ) async throws -> CloudMusicApi.CommentNewPage.DataPayload {
        sorts.append(sort)
        let comment = makeComment(id: sort == .time ? 2 : 1)
        return CloudMusicApi.CommentNewPage.DataPayload(
            comments: [comment],
            hasMore: false,
            cursor: nil,
            totalCount: 1,
            sortType: sort.rawValue,
            commentsTitle: nil
        )
    }

    func commentFloor(
        parentCommentID _: UInt64,
        resourceID _: UInt64,
        type _: CloudMusicApi.CommentResourceType,
        limit _: Int,
        time _: Int64?
    ) async throws -> CloudMusicApi.FloorCommentsPage.DataPayload {
        CloudMusicApi.FloorCommentsPage.DataPayload(
            ownerComment: nil,
            bestComments: nil,
            comments: [makeComment(id: 3)],
            hasMore: false,
            time: nil,
            totalCount: 1,
            currentComment: nil
        )
    }
}

private func makeSong(id: UInt64) -> CloudMusicApi.Song {
    CloudMusicApi.Song(
        name: "Song \(id)",
        id: id,
        al: CloudMusicApi.Album(id: id, name: "Album", pic: 0, picUrl: "", tns: []),
        ar: [CloudMusicApi.Artist(id: id, name: "Artist")],
        alia: [],
        tns: nil,
        fee: .free,
        originCoverType: 0,
        mv: 0,
        dt: 180_000,
        hr: nil,
        sq: nil,
        h: nil,
        m: nil,
        l: nil,
        publishTime: 0,
        pc: nil
    )
}

private func makeCloudFile(id: UInt64, name: String) -> CloudMusicApi.CloudFile {
    CloudMusicApi.CloudFile(
        fileName: name,
        fileSize: 1,
        matchType: "matched",
        pcId: id,
        privateCloud: .init(songId: id),
        simpleSong: nil
    )
}

private func makeComment(id: UInt64) -> CloudMusicApi.Comment {
    CloudMusicApi.Comment(
        commentId: id,
        content: "Comment \(id)",
        richContent: nil,
        time: nil,
        timeStr: nil,
        likedCount: nil,
        liked: nil,
        ipLocation: nil,
        user: CloudMusicApi.CommentUser(userId: id, nickname: "User", avatarUrl: nil),
        beReplied: nil,
        showFloorComment: nil
    )
}

private func makeCookie(name: String, value: String) -> HTTPCookie {
    HTTPCookie(properties: [
        .domain: "music.163.com",
        .path: "/",
        .name: name,
        .value: value,
    ])!
}
