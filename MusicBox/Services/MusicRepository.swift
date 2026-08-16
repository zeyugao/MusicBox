import AVFoundation
import Foundation

@MainActor
protocol AccountRepository: AnyObject {
    func loginStatus() async -> CloudMusicApi.Profile?
    func userPlaylists(for userID: UInt64) async throws -> [CloudMusicApi.PlayListItem]?
    func likedSongIDs(for userID: UInt64) async -> [UInt64]?
    func setLiked(songID: UInt64, liked: Bool) async throws
    func setCookie(_ cookie: String)
    func currentCookie() -> String?
    func logout() async
}

@MainActor
protocol CatalogRepository: AnyObject {
    func recommendedResources() async -> [CloudMusicApi.RecommandPlaylistItem]?
    func searchSuggestions(for query: String) async -> [CloudMusicApi.SearchResult.Song]?
    func searchSongs(_ query: String, limit: Int, offset: Int) async -> [CloudMusicApi.SearchResult.Song]?
    func playlistDetail(id: UInt64) async -> (tracks: [CloudMusicApi.Song], trackIDs: [UInt64])?
    func songs(ids: [UInt64]) async -> [CloudMusicApi.Song]?
    func updatePlaylistTracks(
        _ operation: CloudMusicApi.PlaylistTracksOp,
        playlistID: UInt64,
        trackIDs: [UInt64]
    ) async throws
}

@MainActor
protocol CloudRepository: AnyObject {
    func cloudFiles(limit: Int, offset: Int) async -> [CloudMusicApi.CloudFile]?
    func uploadCloudFile(
        _ fileURL: URL,
        title: String?,
        artist: String?,
        album: String?,
        progress: @escaping TransferProgressHandler
    ) async throws -> UInt64?
    func matchCloudFile(userID: UInt64, songID: UInt64, adjustedSongID: UInt64) async throws
}

extension CloudRepository {
    func uploadCloudFile(
        _ fileURL: URL,
        title: String?,
        artist: String?,
        album: String?
    ) async throws -> UInt64? {
        try await uploadCloudFile(
            fileURL,
            title: title,
            artist: artist,
            album: album,
            progress: { _ in }
        )
    }
}

@MainActor
protocol CommentsRepository: AnyObject {
    func comments(
        type: CloudMusicApi.CommentResourceType,
        id: UInt64,
        page: Int,
        pageSize: Int,
        sort: CloudMusicApi.CommentNewSortType,
        cursor: Int64?
    ) async throws -> CloudMusicApi.CommentNewPage.DataPayload
    func commentFloor(
        parentCommentID: UInt64,
        resourceID: UInt64,
        type: CloudMusicApi.CommentResourceType,
        limit: Int,
        time: Int64?
    ) async throws -> CloudMusicApi.FloorCommentsPage.DataPayload
}

@MainActor
protocol PlaybackResourceServing: AnyObject {
    func audioURL(for songID: UInt64) async -> CloudMusicApi.SongData?
    func lyrics(for songID: UInt64) async -> CloudMusicApi.LyricNew?
}

typealias MusicRepository = AccountRepository & CatalogRepository & CloudRepository & CommentsRepository & PlaybackResourceServing
typealias PlaylistRepository = CatalogRepository & CloudRepository & PlaybackResourceServing

@MainActor
final class NeteaseMusicRepository: MusicRepository {
    private func api(cacheTTL: TimeInterval = 0) -> CloudMusicApi {
        CloudMusicApi(cacheTtl: cacheTTL)
    }

    func loginStatus() async -> CloudMusicApi.Profile? {
        await api().login_status()
    }

    func userPlaylists(for userID: UInt64) async throws -> [CloudMusicApi.PlayListItem]? {
        try await api().user_playlist(uid: userID)
    }

    func likedSongIDs(for userID: UInt64) async -> [UInt64]? {
        await api().likelist(userId: userID)
    }

    func setCookie(_ cookie: String) {
        api().setCookie(cookie)
    }

    func currentCookie() -> String? {
        api().getCookie()
    }

    func logout() async {
        await api().logout()
    }

    func recommendedResources() async -> [CloudMusicApi.RecommandPlaylistItem]? {
        await api(cacheTTL: 5 * 60).recommend_resource()
    }

    func searchSuggestions(for query: String) async -> [CloudMusicApi.SearchResult.Song]? {
        await api(cacheTTL: 60).search_suggest(keyword: query)
    }

    func searchSongs(_ query: String, limit: Int = 30, offset: Int = 0) async -> [CloudMusicApi.SearchResult.Song]? {
        await api(cacheTTL: 60).search(keyword: query, limit: limit, offset: offset)
    }

    func playlistDetail(id: UInt64) async -> (tracks: [CloudMusicApi.Song], trackIDs: [UInt64])? {
        guard let detail = await api(cacheTTL: 60).playlist_detail(id: id) else { return nil }
        return (tracks: detail.tracks, trackIDs: detail.trackIds)
    }

    func songs(ids: [UInt64]) async -> [CloudMusicApi.Song]? {
        await api(cacheTTL: 60).song_detail(ids: ids)
    }

    func setLiked(songID: UInt64, liked: Bool) async throws {
        try await api().like(id: songID, like: liked)
    }

    func updatePlaylistTracks(
        _ operation: CloudMusicApi.PlaylistTracksOp,
        playlistID: UInt64,
        trackIDs: [UInt64]
    ) async throws {
        try await api().playlist_tracks(op: operation, playlistId: playlistID, trackIds: trackIDs)
    }

    func cloudFiles(limit: Int, offset: Int) async -> [CloudMusicApi.CloudFile]? {
        await api().user_cloud(limit: limit, offset: offset)
    }

    func uploadCloudFile(
        _ fileURL: URL,
        title: String?,
        artist: String?,
        album: String?,
        progress: @escaping TransferProgressHandler
    ) async throws -> UInt64? {
        try await api().cloud(
            filePath: fileURL,
            songName: title,
            artist: artist,
            album: album,
            progress: progress
        )
    }

    func matchCloudFile(userID: UInt64, songID: UInt64, adjustedSongID: UInt64) async throws {
        try await api().cloud_match(userId: userID, songId: songID, adjustSongId: adjustedSongID)
    }

    func comments(
        type: CloudMusicApi.CommentResourceType,
        id: UInt64,
        page: Int,
        pageSize: Int,
        sort: CloudMusicApi.CommentNewSortType,
        cursor: Int64?
    ) async throws -> CloudMusicApi.CommentNewPage.DataPayload {
        try await api(cacheTTL: 15).comment_new(
            type: type,
            id: id,
            pageNo: page,
            pageSize: pageSize,
            sortType: sort,
            cursor: cursor
        )
    }

    func commentFloor(
        parentCommentID: UInt64,
        resourceID: UInt64,
        type: CloudMusicApi.CommentResourceType,
        limit: Int,
        time: Int64?
    ) async throws -> CloudMusicApi.FloorCommentsPage.DataPayload {
        try await api(cacheTTL: 15).comment_floor(
            parentCommentId: parentCommentID,
            id: resourceID,
            type: type,
            limit: limit,
            time: time
        )
    }

    func audioURL(for songID: UInt64) async -> CloudMusicApi.SongData? {
        await api().song_url_v1(id: [songID])?.first
    }

    func lyrics(for songID: UInt64) async -> CloudMusicApi.LyricNew? {
        await api(cacheTTL: -1).lyric_new(id: songID)
    }
}

enum PlaylistItemFactory {
    static func make(
        song: CloudMusicApi.Song,
        audio: CloudMusicApi.SongData? = nil,
        sourcePlaylist: PlaybackSourcePlaylist? = nil
    ) -> PlaylistItem {
        let extensionName = audio.map { $0.type.isEmpty ? $0.encodeType : $0.type }
        return PlaylistItem(
            id: song.id,
            url: audio.flatMap { URL(string: $0.url.https) },
            title: song.name,
            artist: song.ar.compactMap(\.name).joined(separator: ", "),
            albumId: song.al.id,
            ext: extensionName,
            duration: CMTime(seconds: Double(song.dt) / 1_000, preferredTimescale: 1_000),
            artworkUrl: URL(string: song.al.picUrl.https),
            nsSong: song,
            sourcePlaylist: sourcePlaylist
        )
    }
}

enum MusicLibraryCache {
    private static let supportedExtensions = [
        "mp3", "MP3", "flac", "FLAC", "m4a", "M4A", "aac", "AAC", "wav", "WAV", "ogg", "OGG",
        "alac", "ALAC", "aiff", "AIFF", "caf", "CAF", "opus", "OPUS", "wma", "WMA", "mp4", "MP4",
        "webm", "WEBM", "aax", "AAX", "aa", "AA", "dsd", "DSD", "dff", "DFF", "dsf", "DSF", "pcm", "PCM"
    ]

    static func directory(createIfNeeded: Bool = true) -> URL? {
        guard let musicDirectory = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = musicDirectory.appendingPathComponent("MusicBox", isDirectory: true)
        if createIfNeeded, !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    static func existingFile(for songID: UInt64) -> URL? {
        guard let directory = directory(createIfNeeded: false) else { return nil }
        for fileExtension in supportedExtensions {
            let candidate = directory.appendingPathComponent("\(songID).\(fileExtension)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func destination(for songID: UInt64, fileExtension: String) -> URL? {
        directory()?.appendingPathComponent("\(songID).\(fileExtension)")
    }

    static func clear() throws {
        guard let directory = directory(createIfNeeded: false), FileManager.default.fileExists(atPath: directory.path) else {
            return
        }
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in contents {
            try FileManager.default.removeItem(at: file)
        }
    }
}

enum ResolvedAudioSource {
    case local(URL)
    case remote(url: URL, cacheURL: URL, fileExtension: String, expectedSize: Int64?)
}

@MainActor
final class AudioSourceResolver {
    private let repository: (any PlaybackResourceServing)?
    private let override: ((PlaylistItem) async throws -> ResolvedAudioSource)?
    private let session: URLSession

    init(repository: any PlaybackResourceServing, session: URLSession = .shared) {
        self.repository = repository
        self.session = session
        override = nil
    }

    init(resolve: @escaping (PlaylistItem) async throws -> ResolvedAudioSource) {
        repository = nil
        session = .shared
        override = resolve
    }

    func resolve(_ item: PlaylistItem) async throws -> ResolvedAudioSource {
        if let override {
            return try await override(item)
        }
        if let cached = MusicLibraryCache.existingFile(for: item.id) {
            return .local(cached)
        }
        if let url = item.url {
            return try source(for: url, item: item, fallbackExtension: item.ext, expectedSize: nil)
        }
        guard let repository,
            let data = await repository.audioURL(for: item.id),
            let url = URL(string: data.url.https)
        else {
            throw RequestError.Request("Unable to resolve an audio source")
        }
        let fileExtension = data.type.isEmpty ? data.encodeType : data.type
        return try source(
            for: url,
            item: item,
            fallbackExtension: fileExtension,
            expectedSize: Int64(exactly: data.size)
        )
    }

    func download(
        _ item: PlaylistItem,
        progress: @escaping TransferProgressHandler = { _ in }
    ) async throws -> URL {
        switch try await resolve(item) {
        case .local(let url):
            return url
        case .remote(let url, let cacheURL, _, let expectedSize):
            progress(
                TransferProgress(
                    completedBytes: 0,
                    totalBytes: expectedSize,
                    stage: .preparing
                )
            )
            let stagingURL = cacheURL.deletingLastPathComponent()
                .appendingPathComponent(".\(cacheURL.lastPathComponent).\(UUID().uuidString).download")
            let downloader = URLSessionFileDownloader(
                configuration: session.configuration,
                destinationURL: stagingURL,
                expectedTotalBytes: expectedSize,
                progress: progress
            )
            defer { try? FileManager.default.removeItem(at: stagingURL) }

            let response = try await downloader.download(from: url)
            try Task.checkCancellation()

            let responseSize = response.expectedContentLength > 0 ? response.expectedContentLength : nil
            let totalBytes = expectedSize ?? responseSize
            progress(
                TransferProgress(
                    completedBytes: totalBytes ?? 0,
                    totalBytes: totalBytes,
                    stage: .finalizing
                )
            )

            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: cacheURL.path) {
                _ = try fileManager.replaceItemAt(cacheURL, withItemAt: stagingURL)
            } else {
                try fileManager.moveItem(at: stagingURL, to: cacheURL)
            }
            return cacheURL
        }
    }

    private func source(
        for url: URL,
        item: PlaylistItem,
        fallbackExtension: String?,
        expectedSize: Int64?
    ) throws -> ResolvedAudioSource {
        if url.isFileURL {
            return .local(url)
        }
        let fileExtension = nonEmptyExtension(fallbackExtension) ?? nonEmptyExtension(url.pathExtension) ?? "mp3"
        guard let cacheURL = MusicLibraryCache.destination(for: item.id, fileExtension: fileExtension) else {
            throw RequestError.Request("Unable to create the music cache directory")
        }
        return .remote(
            url: url,
            cacheURL: cacheURL,
            fileExtension: fileExtension,
            expectedSize: expectedSize
        )
    }

    private func nonEmptyExtension(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

final class URLSessionFileDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let destinationURL: URL
    private let expectedTotalBytes: Int64?
    private let progress: TransferProgressHandler
    private let lock = NSLock()

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<URLResponse, Error>?
    private var response: URLResponse?
    private var fileHandle: FileHandle?
    private var completedBytes: Int64 = 0
    private var terminalError: Error?
    private var isCancelled = false
    private var isCompleted = false

    init(
        configuration: URLSessionConfiguration,
        destinationURL: URL,
        expectedTotalBytes: Int64?,
        progress: @escaping TransferProgressHandler
    ) {
        self.configuration = configuration
        self.destinationURL = destinationURL
        self.expectedTotalBytes = expectedTotalBytes
        self.progress = progress
    }

    func download(from url: URL) async throws -> URLResponse {
        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        fileHandle = try FileHandle(forWritingTo: destinationURL)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: url)

                lock.lock()
                self.continuation = continuation
                self.session = session
                self.task = task
                let shouldCancel = isCancelled
                lock.unlock()

                if shouldCancel {
                    task.cancel()
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        self.response = response
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try fileHandle?.write(contentsOf: data)
            completedBytes += Int64(data.count)
            let responseTotal = response?.expectedContentLength ?? NSURLSessionTransferSizeUnknown
            let totalBytes = expectedTotalBytes ?? (responseTotal > 0 ? responseTotal : nil)
            progress(
                TransferProgress(
                    completedBytes: completedBytes,
                    totalBytes: totalBytes,
                    stage: .transferring
                )
            )
        } catch {
            terminalError = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let closeError: Error?
        do {
            try fileHandle?.close()
            closeError = nil
        } catch {
            closeError = error
        }
        fileHandle = nil

        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        isCompleted = true
        let continuation = self.continuation
        self.continuation = nil
        let response = self.response
        let terminalError = self.terminalError ?? error ?? closeError
        lock.unlock()

        session.finishTasksAndInvalidate()
        if let terminalError {
            continuation?.resume(throwing: terminalError)
        } else if let response {
            continuation?.resume(returning: response)
        } else {
            continuation?.resume(throwing: URLError(.badServerResponse))
        }
    }

    private func cancel() {
        lock.lock()
        isCancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

final class URLSessionTransferProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let expectedTotalBytes: Int64?
    private let progress: TransferProgressHandler

    init(
        expectedTotalBytes: Int64?,
        progress: @escaping TransferProgressHandler
    ) {
        self.expectedTotalBytes = expectedTotalBytes
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        report(completedBytes: totalBytesSent, reportedTotalBytes: totalBytesExpectedToSend)
    }

    private func report(completedBytes: Int64, reportedTotalBytes: Int64) {
        let totalBytes = reportedTotalBytes > 0 ? reportedTotalBytes : expectedTotalBytes
        progress(
            TransferProgress(
                completedBytes: completedBytes,
                totalBytes: totalBytes,
                stage: .transferring
            )
        )
    }
}
