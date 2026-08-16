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
    func requestQRCodeKey() async throws -> String
    func qrCodeURL(for key: String) async throws -> String
    func checkQRCode(_ key: String) async throws -> (code: Int, message: String, cookie: String?, redirectURL: String?)
    func login(phone: String, countryCode: Int, password: String) async -> String?
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
    func uploadCloudFile(_ fileURL: URL, title: String?, artist: String?, album: String?) async throws -> UInt64?
    func matchCloudFile(userID: UInt64, songID: UInt64, adjustedSongID: UInt64) async throws
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

    func requestQRCodeKey() async throws -> String {
        try await api().login_qr_key()
    }

    func qrCodeURL(for key: String) async throws -> String {
        try await api().login_qr_create(key: key)
    }

    func checkQRCode(_ key: String) async throws -> (code: Int, message: String, cookie: String?, redirectURL: String?) {
        let result = try await api().login_qr_check(key: key)
        return (result.code, result.message, result.cookie, result.redirectUrl)
    }

    func login(phone: String, countryCode: Int, password: String) async -> String? {
        await api().login_cellphone(phone: phone, countrycode: countryCode, password: password)
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

    func uploadCloudFile(_ fileURL: URL, title: String?, artist: String?, album: String?) async throws -> UInt64? {
        try await api().cloud(filePath: fileURL, songName: title, artist: artist, album: album)
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
    case remote(url: URL, cacheURL: URL, fileExtension: String)
}

@MainActor
final class AudioSourceResolver {
    private let repository: (any PlaybackResourceServing)?
    private let override: ((PlaylistItem) async throws -> ResolvedAudioSource)?

    init(repository: any PlaybackResourceServing) {
        self.repository = repository
        override = nil
    }

    init(resolve: @escaping (PlaylistItem) async throws -> ResolvedAudioSource) {
        repository = nil
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
            return try source(for: url, item: item, fallbackExtension: item.ext)
        }
        guard let repository,
            let data = await repository.audioURL(for: item.id),
            let url = URL(string: data.url.https)
        else {
            throw RequestError.Request("Unable to resolve an audio source")
        }
        let fileExtension = data.type.isEmpty ? data.encodeType : data.type
        return try source(for: url, item: item, fallbackExtension: fileExtension)
    }

    private func source(for url: URL, item: PlaylistItem, fallbackExtension: String?) throws -> ResolvedAudioSource {
        if url.isFileURL {
            return .local(url)
        }
        let fileExtension = nonEmptyExtension(fallbackExtension) ?? nonEmptyExtension(url.pathExtension) ?? "mp3"
        guard let cacheURL = MusicLibraryCache.destination(for: item.id, fileExtension: fileExtension) else {
            throw RequestError.Request("Unable to create the music cache directory")
        }
        return .remote(url: url, cacheURL: cacheURL, fileExtension: fileExtension)
    }

    private func nonEmptyExtension(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
