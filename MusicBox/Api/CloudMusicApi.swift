//
//  CloudMusicApi.swift
//  MusicBox
//
//  Created by Elsa on 2024/4/20.
//

import CryptoKit
import Foundation

enum RequestError: LocalizedError {
    case error(Error)
    case noData
    case errorCode((Int, String))
    case Request(String)
    case unknown

    public var localizedDescription: String {
        switch self {
        case .error(let error):
            return error.localizedDescription
        case .noData:
            return "No data"
        case .errorCode((let code, let message)):
            return "\(code): \(message)"
        case .Request(let message):
            return message
        case .unknown:
            return "Unknown error"
        }
    }

    var errorDescription: String? {
        localizedDescription
    }
}

struct ServerError: Decodable, Error {
    let code: Int
    let msg: String?
    let message: String?
}

enum IntOrString: Decodable, Hashable {
    case int(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
            return
        }
        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
            return
        }
        throw DecodingError.typeMismatch(
            IntOrString.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected a String or an Int but found neither"))
    }

    var stringValue: String {
        switch self {
        case .int(let value):
            return String(value)
        case .string(let value):
            return value
        }
    }
}

class SharedCacheManager {
    class CacheItem {
        let value: Any
        let expiryDate: Date?

        init(value: Any, ttl: TimeInterval) {
            self.value = value
            if ttl == -1 {
                self.expiryDate = nil
            } else {
                self.expiryDate = Date().addingTimeInterval(ttl)
            }
        }

        var isExpired: Bool {
            if let expiryDate = expiryDate {
                return Date() > expiryDate
            }
            return false
        }
    }

    private var cache: [String: CacheItem] = [:]
    private let cacheQueue = DispatchQueue(label: "SharedCacheManagerQueue")

    static let shared = SharedCacheManager()

    private init() {
        startPeriodicCleanup()
    }

    func md5(_ data: String) -> String {
        let md5Data = Insecure.MD5.hash(data: Data(data.utf8))
        return md5Data.map { String(format: "%02hhx", $0) }.joined()
    }

    func set(value: Any, for query: String, ttl: TimeInterval) {
        cacheQueue.sync {
            self.cache[self.md5(query)] = CacheItem(value: value, ttl: ttl)
        }
    }

    func get(for query: String) -> Any? {
        var result: Any? = nil
        let query = md5(query)
        cacheQueue.sync {
            if let item = self.cache[query], !item.isExpired {
                result = item.value
            } else {
                self.cache.removeValue(forKey: query)
            }
        }
        return result
    }

    func clear() {
        cacheQueue.sync {
            self.cache.removeAll()
        }
    }

    func invalidate(for query: String) {
        let hashedKey = md5(query)
        cacheQueue.sync {
            _ = self.cache.removeValue(forKey: hashedKey)
        }
    }

    private func startPeriodicCleanup() {
        Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.cleanupExpiredItems()
        }
    }

    private func cleanupExpiredItems() {
        cacheQueue.async {
            let now = Date()
            self.cache = self.cache.filter { key, item in
                if let expiryDate = item.expiryDate {
                    return expiryDate > now
                }
                return true
            }
        }
    }

    deinit {
        clear()
    }
}

class CloudMusicApi {
    let cacheTtl: TimeInterval  // 0 means no cache
    private let client: NeteaseHTTPClient

    init(cacheTtl: TimeInterval = 0, client: NeteaseHTTPClient = .shared) {
        self.cacheTtl = cacheTtl
        self.client = client
    }

    static let RecommandSongPlaylistId: UInt64 = 0

    struct Profile: Codable, Equatable {
        let avatarUrl: String
        let nickname: String
        let userId: UInt64
    }

    struct PlayListItem: Identifiable, Codable, Equatable, Hashable {
        let subscribed: Bool
        let coverImgUrl: String
        let name: String
        let id: UInt64
        let createTime: Int
        let userId: Int
        let privacy: Int
        let description: String?
        let creator: Profile
        let trackCount: UInt64?
        let cloudTrackCount: UInt64?

        static func == (lhs: CloudMusicApi.PlayListItem, rhs: CloudMusicApi.PlayListItem) -> Bool {
            return lhs.id == rhs.id
                && lhs.name == rhs.name
                && lhs.subscribed == rhs.subscribed
                && lhs.coverImgUrl == rhs.coverImgUrl
                && lhs.trackCount == rhs.trackCount
                && lhs.cloudTrackCount == rhs.cloudTrackCount
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }

    struct RecommandPlaylistItem: Codable, Identifiable, Equatable {
        static func == (
            lhs: CloudMusicApi.RecommandPlaylistItem, rhs: CloudMusicApi.RecommandPlaylistItem
        ) -> Bool {
            return lhs.id == rhs.id
        }

        let creator: Profile?
        let picUrl: String
        let userId: UInt64?
        let id: UInt64
        let name: String
        let playcount: UInt64?
        let trackCount: UInt64?
    }

    struct Quality: Codable {
        let br: UInt64
        let size: UInt64
    }

    struct Album: Codable {
        let id: UInt64
        let name: String?
        let pic: UInt64
        let picUrl: String
        let tns: [String]
    }

    struct Artist: Codable {
        let id: UInt64
        let name: String?

        let alias: [String]
        let tns: [String]

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case alias
            case tns
        }

        init(id: UInt64, name: String?, alias: [String] = [], tns: [String] = []) {
            self.id = id
            self.name = name
            self.alias = alias
            self.tns = tns
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UInt64.self, forKey: .id)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            alias = try container.decodeIfPresent([String].self, forKey: .alias) ?? []
            tns = try container.decodeIfPresent([String].self, forKey: .tns) ?? []
        }
    }

    struct CloudMusic: Codable {
        let alb: String
        let ar: String
        let br: UInt64
        let fn: String
        let sn: String
        let uid: UInt64
    }

    struct CloudFile: Codable, Identifiable, Hashable, Equatable {
        static func == (lhs: CloudMusicApi.CloudFile, rhs: CloudMusicApi.CloudFile) -> Bool {
            return lhs.pcId == rhs.pcId
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(pcId)
        }

        let fileName: String
        let fileSize: Int64
        let matchType: String
        let pcId: UInt64
        let privateCloud: PrivateCloud
        let simpleSong: SimpleSong?

        var id: UInt64 { pcId }

        struct PrivateCloud: Codable {
            let songId: UInt64
        }

        struct SimpleSong: Codable {
            let name: String?
            let al: SimpleAlbum?
            let ar: [SimpleArtist]?

            struct SimpleAlbum: Codable {
                let name: String?
            }

            struct SimpleArtist: Codable {
                let name: String?
            }
        }

        func parseFileSize() -> String {
            let bytes = Double(fileSize)
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useMB, .useGB]
            formatter.countStyle = .file
            return formatter.string(fromByteCount: Int64(bytes))
        }

        var isMatched: Bool {
            return matchType == "matched"
        }
    }

    struct CloudFilesResponse: Codable {
        let code: Int
        let count: Int
        let data: [CloudFile]
    }

    enum Fee: Int, Codable {
        case free = 0  // 免费或无版权
        case vip = 1  // VIP 歌曲
        case album = 4  // 购买专辑
        case trial = 8  // 非会员可免费播放低音质，会员可播放高音质及下载
    }

    struct Song: Codable, Identifiable, Hashable, Equatable {
        static func == (lhs: CloudMusicApi.Song, rhs: CloudMusicApi.Song) -> Bool {
            return lhs.id == rhs.id
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }

        let name: String
        let id: UInt64

        let al: Album
        let ar: [Artist]

        let alia: [String]
        let tns: [String]?

        let fee: Fee
        let originCoverType: Int

        let mv: UInt64  // MV id

        let dt: Int64  // 歌曲时长

        let hr: Quality?  // Hi-Res 质量文件信息
        let sq: Quality?  // 无损质量文件信息
        let h: Quality?  // 高质量文件信息
        let m: Quality?  // 中等质量文件信息
        let l: Quality?  // 低质量文件信息

        let publishTime: Int64  // 毫秒为单位的 Unix 时间戳

        let pc: CloudMusic?

        func parseDuration() -> (minute: Int64, second: Int64) {
            let second = dt / 1000
            let minute = second / 60
            return (minute, second % 60)
        }

        func getHighestQuality() -> Quality? {
            return hr ?? sq ?? h ?? m ?? l
        }

        var albumName: String {
            al.name ?? ""
        }
    }

    struct SongData: Decodable {
        let br: UInt64
        let encodeType: String
        let id: UInt64
        let level: String
        let size: UInt64
        let time: Int64
        let type: String
        let url: String
    }

    // MARK: - Comments

    enum CommentResourceType: Int, Codable {
        case music = 0
        case mv = 1
        case playlist = 2
        case album = 3
        case dj = 4
        case video = 5
        case event = 6
        case radio = 7
    }

    struct CommentUser: Decodable, Hashable {
        let userId: UInt64
        let nickname: String
        let avatarUrl: String?
    }

    struct CommentIPLocation: Decodable, Hashable {
        let location: String?
    }

    struct CommentBeReplied: Decodable, Hashable {
        let beRepliedCommentId: UInt64?
        let content: String?
        let richContent: String?
        let status: Int?
        let user: CommentUser?
    }

    struct CommentShowFloorComment: Decodable, Hashable {
        let replyCount: Int?
        let showReplyCount: Bool?
    }

    struct Comment: Decodable, Identifiable, Hashable {
        let commentId: UInt64
        let content: String
        let richContent: String?
        let time: Int64?
        let timeStr: String?
        let likedCount: Int?
        let liked: Bool?
        let ipLocation: CommentIPLocation?
        let user: CommentUser
        let beReplied: [CommentBeReplied]?
        let showFloorComment: CommentShowFloorComment?

        var id: UInt64 { commentId }
    }

    enum CommentNewSortType: Int, Codable {
        case recommend = 1
        case hot = 2
        case time = 3
    }

    struct CommentNewPage: Decodable, Hashable {
        struct DataPayload: Decodable, Hashable {
            let comments: [Comment]?
            let hasMore: Bool?
            let cursor: IntOrString?
            let totalCount: Int?
            let sortType: Int?
            let commentsTitle: String?
        }

        let code: Int
        let message: String?
        let data: DataPayload?
    }

    struct FloorCommentsPage: Decodable, Hashable {
        struct DataPayload: Decodable, Hashable {
            let ownerComment: Comment?
            let bestComments: [Comment]?
            let comments: [Comment]?
            let hasMore: Bool?
            let time: Int64?
            let totalCount: Int?
            let currentComment: Comment?
        }

        let code: Int
        let message: String?
        let data: DataPayload?
    }

    func login_qr_key(max_retries: UInt = 3) async throws -> String {
        struct Result: Decodable {
            let code: Int
            let unikey: String
        }

        _ = max_retries
        let response = try await client.loginQRCodeKey(cacheTtl: cacheTtl)
        guard let result = response.asType(Result.self, silent: true), result.code == 200 else {
            throw RequestError.noData
        }
        return result.unikey
    }

    func login_qr_create(key: String) async throws -> String {
        return client.loginQRCodeURL(key: key)
    }

    static let SaveCookieName: String = "NeteaseApiCookie"

    static func migrateLegacyAuthenticationIfNeeded() {
        NeteaseHTTPClient.migrateLegacyAuthenticationIfNeeded()
    }

    func setCookie(_ cookie: String) {
        client.setCookie(cookie)
    }

    func getCookie() -> String? {
        client.cookie()
    }

    func login_refresh() async throws {
        _ = try await client.loginRefresh(cacheTtl: cacheTtl)
    }

    func login_qr_check(key: String) async throws -> (
        code: Int, message: String, cookie: String?, redirectUrl: String?
    ) {
        struct Result: Decodable {
            let code: Int
            let message: String?
            let cookie: String?
            let redirectUrl: String?
        }
        let response = try await client.loginQRCodeCheck(key: key, cacheTtl: cacheTtl)
        guard let parsedResult = response.asType(Result.self, silent: true) else {
            throw RequestError.noData
        }

        if parsedResult.code == 803, let cookie = parsedResult.cookie {
            setCookie(cookie)
        }

        return (
            parsedResult.code, parsedResult.message ?? "No message", parsedResult.cookie,
            parsedResult.redirectUrl
        )
    }

    func login_status() async -> Profile? {
        struct Result: Decodable {
            let profile: Profile?
        }
        guard let ret = try? await client.loginStatus(cacheTtl: cacheTtl) else {
            return nil
        }
        return ret.asType(Result.self)?.profile
    }

    func user_playlist(
        uid: UInt64, limit: Int = 30, offset: Int = 0, includeVideo: Bool = true
    )
        async throws
        -> [CloudMusicApi.PlayListItem]?
    {
        guard
            let ret = try? await client.userPlaylist(
                userID: uid,
                limit: limit,
                offset: offset,
                includeVideo: includeVideo,
                cacheTtl: cacheTtl
            )
        else { return nil }

        struct Result: Decodable {
            let playlist: [PlayListItem]
            let more: Bool
        }

        // TODO: Fix more = true
        if let parsed = ret.asType(Result.self) {
            return parsed.playlist
        }
        return nil
    }

    func login_cellphone(phone: String, countrycode: Int = 86, password: String) async
        -> String?
    {
        let response: Foundation.Data
        do {
            response = try await client.loginCellphone(
                phone: phone,
                countryCode: countrycode,
                password: password,
                cacheTtl: cacheTtl
            )
        } catch {
            return error.localizedDescription
        }

        struct Data: Decodable {
            let blockText: String?
        }

        struct Result: Decodable {
            let code: Int?
            let message: String?
            let cookie: String?
            let data: Data?
        }

        if let parsed = response.asType(Result.self) {
            if parsed.code == 200 {
                if let cookie = parsed.cookie {
                    setCookie(cookie)
                    return nil
                }
                if getCookie() != nil {
                    return nil
                }
            }
            if let data = parsed.data, let blockText = data.blockText {
                return blockText
            }
            if let message = parsed.message, !message.isEmpty {
                return message
            }
        }
        return "Parse failed"
    }

    func logout() async {
        _ = try? await client.logout(cacheTtl: cacheTtl)
        client.clearCookie()
        SharedCacheManager.shared.clear()
    }

    func user_cloud(limit: Int = 30, offset: Int = 0) async -> [CloudFile]? {
        guard
            let res = try? await client.userCloud(
                limit: limit,
                offset: offset,
                cacheTtl: cacheTtl
            )
        else {
            print("user_cloud failed")
            return nil
        }

        if let parsed = res.asType(CloudFilesResponse.self) {
            return parsed.data
        }
        return nil
    }

    func playlist_detail(id: UInt64) async -> (tracks: [Song], trackIds: [UInt64])? {
        if id == CloudMusicApi.RecommandSongPlaylistId {
            return await recommend_songs().map { ($0, $0.map { $0.id }) }
        }
        guard
            let ret: Data = try? await client.playlistDetail(id: id, cacheTtl: cacheTtl)
        else {
            return nil
        }

        struct Track: Decodable {
            let id: UInt64
        }

        struct Playlist: Decodable {
            let trackIds: [Track]
            let tracks: [Song]
        }

        struct Result: Decodable {
            let code: Int
            let playlist: Playlist
        }

        if let parsed = ret.asType(Result.self) {
            return (parsed.playlist.tracks, parsed.playlist.trackIds.map { $0.id })
        }
        print("playlist_detail failed")
        return nil
    }

    func song_detail(ids: [UInt64]) async -> [Song]? {
        guard
            let ret = try? await client.songDetail(ids: ids, cacheTtl: cacheTtl)
        else { return nil }

        struct Result: Decodable {
            let songs: [Song]
        }

        if let parsed = ret.asType(Result.self) {
            return parsed.songs
        }
        print("song_detail failed")
        return nil
    }

    func song_url_v1(id: [UInt64], level: String = "jymaster") async -> [SongData]? {
        guard
            let ret = try? await client.songURL(ids: id, level: level, cacheTtl: cacheTtl)
        else { return nil }

        struct Result: Decodable {
            let code: Int
            let data: [SongData]
        }

        if let parsed = ret.asType(Result.self) {
            return parsed.data
        }
        print("song_url_v1 failed")
        return nil
    }

    func comment_new(
        type: CommentResourceType,
        id: UInt64,
        pageNo: Int = 1,
        pageSize: Int = 20,
        sortType: CommentNewSortType = .hot,
        cursor: Int64? = nil
    ) async throws -> CommentNewPage.DataPayload {
        let ret = try await client.comments(
            type: type.rawValue,
            resourceID: id,
            pageNo: pageNo,
            pageSize: pageSize,
            sortType: sortType.rawValue,
            cursor: cursor,
            cacheTtl: cacheTtl
        )
        guard let parsed = ret.asType(CommentNewPage.self, silent: true), let data = parsed.data else {
            throw RequestError.noData
        }
        return data
    }

    func comment_floor(
        parentCommentId: UInt64,
        id: UInt64,
        type: CommentResourceType,
        limit: Int = 20,
        time: Int64? = nil
    ) async throws -> FloorCommentsPage.DataPayload {
        let ret = try await client.floorComments(
            parentCommentID: parentCommentId,
            resourceID: id,
            type: type.rawValue,
            limit: limit,
            time: time,
            cacheTtl: cacheTtl
        )
        guard let parsed = ret.asType(FloorCommentsPage.self, silent: true), let data = parsed.data else {
            throw RequestError.noData
        }
        return data
    }

    private var seq: Int {
        var ret_seq = UserDefaults.standard.integer(forKey: "scrobble_seq")
        if ret_seq == 0 {
            ret_seq = Int.random(in: 1000..<3000)
        }
        ret_seq += 1
        UserDefaults.standard.set(ret_seq, forKey: "scrobble_seq")
        return ret_seq
    }

    private var mspm: String {
        let ret =
            UserDefaults.standard.string(forKey: "mspm")
            ?? {
                var ret: String
                if getenv("MSPM") != nil {
                    ret = String(cString: getenv("MSPM"))
                } else {
                    ret = {
                        let characters = "0123456789abcdef"
                        var result = ""

                        let length = 24

                        for _ in 0..<length {
                            let randomIndex = Int(arc4random_uniform(UInt32(characters.count)))
                            let randomCharacter = characters[
                                characters.index(characters.startIndex, offsetBy: randomIndex)]
                            result.append(randomCharacter)
                        }

                        return result
                    }()
                }

                UserDefaults.standard.set(ret, forKey: "mspm")
                return ret
            }()

        return ret
    }

    func scrobble(song: Song, playedTime: Int? = nil) async {
        guard
            (try? await client.scrobble(
                songID: song.id,
                sourceID: song.al.id,
                playedTime: playedTime ?? Int(song.dt / 1000),
                cacheTtl: cacheTtl
            )) != nil
        else {
            print("scrobble failed")
            return
        }
    }

    func cloud(
        filePath: URL,
        songName: String?,
        artist: String?,
        album: String?,
        progress: @escaping TransferProgressHandler = { _ in }
    ) async throws
        -> UInt64?
    {
        try await client.uploadCloudFile(
            fileURL: filePath,
            songName: songName,
            artist: artist,
            album: album,
            progress: progress
        )
    }

    func cloud_match(userId: UInt64, songId: UInt64, adjustSongId: UInt64) async throws {
        guard
            let res = try? await client.cloudMatch(
                userID: userId,
                songID: songId,
                adjustedSongID: adjustSongId,
                cacheTtl: cacheTtl
            )
        else {
            throw RequestError.Request("cloud_match failed to make request")
        }

        struct Result: Decodable {
            let code: Int
            let message: IntOrString?
        }

        if let parsed = res.asType(Result.self, silent: true) {
            if parsed.code == 200 {
                return
            }

            throw RequestError.errorCode(
                (parsed.code, "cloud_match failed: \(parsed.message?.stringValue ?? "Unknown error")"))
        }

        throw RequestError.Request(
            "cloud_match failed: \(res.asAny() ?? "Unknown error")"
        )
    }

    func likelist(userId: UInt64) async -> [UInt64]? {
        guard
            let res = try? await client.likedSongIDs(userID: userId, cacheTtl: cacheTtl)
        else {
            print("likelist failed")
            return nil
        }

        struct Result: Decodable {
            let ids: [UInt64]
        }

        if let parsed = res.asType(Result.self) {
            return parsed.ids
        }
        return nil
    }

    func like(id: UInt64, like: Bool) async throws {
        guard
            let res = try? await client.setLiked(
                songID: id,
                liked: like,
                cacheTtl: cacheTtl
            )
        else {
            print("like failed")
            return
        }

        struct Result: Decodable {
            let code: Int
        }
        if let parsed = res.asType(Result.self) {
            if parsed.code != 200 {
                throw RequestError.errorCode((parsed.code, "收藏失败"))
            }
        }
    }

    func recommend_resource() async -> [RecommandPlaylistItem]? {
        guard
            let res = try? await client.recommendedResources(cacheTtl: cacheTtl)
        else {
            print("recommend_resource failed")
            return nil
        }

        struct Result: Decodable {
            let recommend: [RecommandPlaylistItem]
        }

        if let parsed = res.asType(Result.self) {
            return parsed.recommend
        }
        return nil
    }

    func recommend_songs() async -> [Song]? {
        guard
            let res = try? await client.recommendedSongs(cacheTtl: cacheTtl)
        else {
            print("recommend_songs failed")
            return nil
        }

        struct Data: Decodable {
            let dailySongs: [Song]
        }

        struct Result: Decodable {
            let data: Data
        }

        if let parsed = res.asType(Result.self) {
            return parsed.data.dailySongs
        }
        return nil
    }

    enum SearchType: Int {
        case singleSong = 1
        case album = 10
        case artist = 100
        case playlist = 1000
        case user = 1002
        case mv = 1004
        case lyric = 1006
        case radio = 1009
        case video = 1014
    }

    struct SearchResult {
        struct Artist: Decodable {
            let img1v1: UInt64
            let img1v1Url: String
            let name: String
            let id: UInt64

            func convertToArtist() -> CloudMusicApi.Artist {
                return CloudMusicApi.Artist(id: id, name: name, alias: [], tns: [])
            }
        }
        struct Album: Decodable {
            let picId: UInt64
            let id: UInt64
            let name: String

            let artist: Artist
            let publishTime: Int64

            func convertToAlbum() -> CloudMusicApi.Album {
                return CloudMusicApi.Album(
                    id: id, name: name, pic: picId, picUrl: "", tns: [])
            }
        }

        struct Song: Decodable {
            let album: Album
            let alias: [String]
            let artists: [Artist]
            let duration: Int64
            let id: UInt64
            let fee: Fee
            let name: String
            let mvid: UInt64
            let transNames: [String]?

            func convertToSong() -> CloudMusicApi.Song {
                return CloudMusicApi.Song(
                    name: name,
                    id: id,
                    al: album.convertToAlbum(),
                    ar: artists.map { $0.convertToArtist() },
                    alia: alias,
                    tns: nil,
                    fee: fee,
                    originCoverType: 0,
                    mv: mvid,
                    dt: duration,
                    hr: nil, sq: nil, h: nil, m: nil, l: nil,
                    publishTime: album.publishTime,
                    pc: nil
                )
            }
        }
    }

    func search_suggest(keyword: String) async -> [SearchResult.Song]? {
        guard
            let res = try? await client.searchSuggestions(keyword: keyword, cacheTtl: cacheTtl)
        else {
            print("search_suggest failed")
            return nil
        }

        struct SuggestResult: Decodable {
            let songs: [SearchResult.Song]?
        }

        struct Result: Decodable {
            let code: Int
            let result: SuggestResult?
        }
        if let parsed = res.asType(Result.self) {
            return parsed.result?.songs ?? []
        }
        print("search_suggest failed to parse response: \(res.asJSONString())")
        return nil
    }

    func search(
        keyword: String, type: SearchType = .singleSong, limit: Int = 30, offset: Int = 0
    ) async
        -> [SearchResult.Song]?
    {
        guard
            let res = try? await client.search(
                keyword: keyword,
                type: type.rawValue,
                limit: limit,
                offset: offset,
                cacheTtl: cacheTtl
            )
        else {
            print("search failed")
            return nil
        }

        struct Result2: Decodable {
            let hasMore: Bool
            let songCount: Int
            let songs: [SearchResult.Song]
        }

        struct Result: Decodable {
            let result: Result2
        }

        if let parsed = res.asType(Result.self) {
            return parsed.result.songs
        }
        return nil
    }

    enum PlaylistTracksOp: String {
        case add = "add"
        case del = "del"
    }

    func playlist_tracks(op: PlaylistTracksOp, playlistId: UInt64, trackIds: [UInt64])
        async throws
    {
        guard
            let res = try? await client.updatePlaylistTracks(
                operation: op.rawValue,
                playlistID: playlistId,
                trackIDs: trackIds,
                cacheTtl: cacheTtl
            )
        else {
            print("playlist_tracks failed")
            return
        }

        struct Result: Decodable {
            let code: Int
            let message: String?
        }

        guard let result = res.asType(Result.self, silent: true) else {
            throw RequestError.noData
        }
        guard result.code == 200 else {
            throw RequestError.errorCode((result.code, result.message ?? "Unknown error"))
        }
    }

    struct LyricLine: Decodable, Hashable {
        let time: Float64
        let lyric: String
        let tlyric: String?
        let romalrc: String?
    }

    struct LyricNew: Decodable {

        struct RawLyricLine: Decodable, Hashable {
            let time: Float64
            let text: String
        }
        struct Lyric: Decodable {
            let lyric: String
            let version: Int

            func parse() -> [RawLyricLine] {
                return lyric.split(separator: "\n").map { (line: Substring) in
                    if !line.starts(with: "[") {
                        return RawLyricLine(time: -1, text: String(line))
                    }

                    let parts = line.split(separator: "]")
                    let time = parts[0].dropFirst().split(separator: ":")
                    let text = parts.count < 2 ? "" : parts[1]
                    if time.count < 2 {
                        return RawLyricLine(time: 0, text: String(text))
                    }
                    let minute = Int(String(time[0])) ?? 0
                    let second = Float64(time[1]) ?? 0
                    return RawLyricLine(time: Float64(minute * 60) + second, text: String(text))
                }
                .filter {
                    line in
                    return !line.text.isEmpty
                }
            }
        }

        func merge() -> [LyricLine] {
            let lrc = self.lrc.parse()
            let tlyric = self.tlyric?.parse() ?? []
            let romalrc = self.romalrc?.parse() ?? []

            var result: [LyricLine] = []
            var lrcIndex = 0
            var tlyricIndex = 0
            var romalrcIndex = 0

            while lrcIndex < lrc.count || tlyricIndex < tlyric.count || romalrcIndex < romalrc.count
            {
                let lrcTime = lrcIndex < lrc.count ? lrc[lrcIndex].time : 1e9
                let tlyricTime = tlyricIndex < tlyric.count ? tlyric[tlyricIndex].time : 1e9
                let romalrcTime = romalrcIndex < romalrc.count ? romalrc[romalrcIndex].time : 1e9

                let time: Float64 = min(lrcTime, tlyricTime, romalrcTime)

                var lyricStr: String?
                var tlyricStr: String?
                var romalrcStr: String?

                if lrcIndex < lrc.count, lrc[lrcIndex].time == time {
                    lyricStr = lrc[lrcIndex].text
                    lrcIndex += 1
                }
                if tlyricIndex < tlyric.count, tlyric[tlyricIndex].time == time {
                    tlyricStr = tlyric[tlyricIndex].text
                    tlyricIndex += 1
                }
                if romalrcIndex < romalrc.count, romalrc[romalrcIndex].time == time {
                    romalrcStr = romalrc[romalrcIndex].text
                    romalrcIndex += 1
                }

                if time >= 0 && lyricStr != nil && lyricStr != "" {
                    result.append(
                        LyricLine(
                            time: time,
                            lyric: (lyricStr ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                            tlyric: tlyricStr?.trimmingCharacters(in: .whitespacesAndNewlines),
                            romalrc: romalrcStr?.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    )
                }
            }
            return result
        }

        // let klyric: LyricNew.Lyric
        let lrc: LyricNew.Lyric
        let tlyric: LyricNew.Lyric?
        let romalrc: LyricNew.Lyric?
    }

    func lyric_new(id: UInt64) async -> LyricNew? {
        guard
            let res = try? await client.lyrics(songID: id, cacheTtl: cacheTtl)
        else {
            print("lyric_new failed")
            return nil
        }

        if let parsed = res.asType(LyricNew.self) {
            return parsed
        }
        print("lyric_new failed")

        return nil
    }
}
