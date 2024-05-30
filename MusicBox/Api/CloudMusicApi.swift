//
//  CloudMusicApi.swift
//  MusicBox
//
//  Created by Elsa on 2024/4/20.
//

import CryptoKit
import Foundation

enum RequestError: Error {
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
}

struct ServerError: Decodable, Error {
    let code: Int
    let msg: String?
    let message: String?
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
        cacheQueue.async {
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
        cacheQueue.async {
            self.cache.removeAll()
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

    init(cacheTtl: TimeInterval = 0) {
        self.cacheTtl = cacheTtl
    }

    static let RecommandSongPlaylistId: UInt64 = 0

    struct Profile: Codable {
        let avatarUrl: String
        let nickname: String
        let userId: UInt64
    }

    struct PlayListItem: Identifiable, Codable, Equatable, Hashable {
        static func == (lhs: CloudMusicApi.PlayListItem, rhs: CloudMusicApi.PlayListItem) -> Bool {
            return lhs.id == rhs.id
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }

        let subscribed: Bool
        let coverImgUrl: String
        let name: String
        let id: UInt64
        let createTime: Int
        let userId: Int
        let privacy: Int
        let description: String?
        let creator: Profile
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
        let name: String
        let pic: UInt64
        let picUrl: String
        let tns: [String]
    }

    struct Artist: Codable {
        let id: UInt64
        let name: String

        let alias: [String]
        let tns: [String]
    }

    struct CloudMusic: Codable {
        let alb: String
        let ar: String
        let br: UInt64
        let fn: String
        let sn: String
        let uid: UInt64
    }

    enum Fee: Int, Codable {
        case free = 0  // 免费或无版权
        case vip = 1  // VIP 歌曲
        case album = 4  // 购买专辑
        case trial = 8  // 非会员可免费播放低音质，会员可播放高音质及下载
    }

    enum OriginCoverType: Int, Codable {
        case unknown = 0
        case origin = 1
        case cover = 2
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
        let originCoverType: OriginCoverType

        let mv: UInt64  // MV id

        let dt: Int64  // 歌曲时长

        let hr: Quality?  // Hi-Res质量文件信息
        let sq: Quality?  // 无损质量文件信息
        let h: Quality?  // 高质量文件信息
        let m: Quality?  // 中等质量文件信息
        let l: Quality?  // 低质量文件信息

        let publishTime: Int64  // 毫秒为单位的Unix时间戳

        let pc: CloudMusic?

        func parseDuration() -> (minute: Int64, second: Int64) {
            let second = dt / 1000
            let minute = second / 60
            return (minute, second % 60)
        }

        func getHighestQuality() -> Quality? {
            return hr ?? sq ?? h ?? m ?? l
        }
    }

    struct Privilege: Decodable {
        let downloadMaxBrLevel: String
        let downloadMaxbr: UInt64
        let fee: Int
        let id: UInt64
        let maxBrLevel: String
        let maxbr: UInt64
        let playMaxBrLevel: String
        let playMaxbr: UInt64
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

    private struct ApiResponse<T: Decodable>: Decodable {
        let code: Int
        let data: T
    }

    private func doRequest(
        memberName: String, data: [String: Any]
    ) async throws -> Data {
        var data = data
        if let cookie = getCookie() {
            data["cookie"] = cookie
        }
        setenv("QT_ENABLE_REGEXP_JIT", "0", 1)  // Disable Qt's JIT in regex matching
        setenv("QT_LOGGING_RULES", "*.debug=false", 1)  // Reduce log
        return try await withCheckedThrowingContinuation { continuation in
            do {
                let jsonData = try JSONSerialization.data(
                    withJSONObject: data, options: [.sortedKeys])

                let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

                let cacheKey = memberName + jsonString
                if cacheTtl != 0 {
                    if let cachedData = SharedCacheManager.shared.get(for: cacheKey) as? Data {
                        SharedCacheManager.shared.set(
                            value: cachedData, for: cacheKey, ttl: cacheTtl)
                        continuation.resume(returning: cachedData)
                        return
                    }
                }

                memberName.withCString { memberNameCString in
                    let memberNamePtr = UnsafeMutablePointer(mutating: memberNameCString)
                    jsonString.withCString { jsonString in
                        let jsonString = UnsafeMutablePointer(mutating: jsonString)
                        let jsonResultCString = invoke(memberNamePtr, jsonString)
                        if let cString = jsonResultCString {
                            let jsonResult = String(cString: cString)

                            if let jsonData = jsonResult.data(using: .utf8) {
                                SharedCacheManager.shared.set(
                                    value: jsonData, for: cacheKey, ttl: cacheTtl)
                                continuation.resume(returning: jsonData)
                                return
                            }
                            continuation.resume(
                                throwing: RequestError.Request("No data: \(jsonResult)"))
                            return
                        }
                        continuation.resume(throwing: RequestError.Request("invoke() returns nil"))
                        return
                    }
                }
            } catch let error where error is ServerError {
                guard let err = error as? ServerError else { return }

                var msg = err.msg ?? err.message ?? ""

                if err.code == -462 {
                    msg = "绑定手机号或短信验证成功后，可进行下一步操作哦~🙃"
                }

                continuation.resume(throwing: RequestError.errorCode((err.code, msg)))
            } catch let error {
                continuation.resume(throwing: RequestError.error(error))
            }
        }
    }

    func login_qr_key(max_retries: UInt = 3) async throws -> String {
        struct Result: Decodable {
            let code: Int
            let unikey: String
        }

        if let res = try? await doRequest(
            memberName: "login_qr_key",
            data: [:]
        ).asType(ApiResponse<Result>.self) {
            return res.data.unikey
        }

        throw RequestError.noData
    }

    func login_qr_create(key: String) async throws -> String {
        struct Result: Decodable {
            let qrurl: String
        }

        let p = [
            "key": key
        ]

        if let res = try? await doRequest(
            memberName: "login_qr_create",
            data: p
        ).asType(ApiResponse<Result>.self) {
            return res.data.qrurl
        }
        throw RequestError.noData
    }

    static let SaveCookieName: String = "NeteaseApiCookie"

    func setCookie(_ cookie: String) {
        UserDefaults.standard.set(cookie, forKey: CloudMusicApi.SaveCookieName)
    }

    func getCookie() -> String? {
        return UserDefaults.standard.string(forKey: CloudMusicApi.SaveCookieName)
    }

    func login_refresh() async throws {
        guard
            (try? await doRequest(
                memberName: "login_refresh",
                data: [:])) != nil
        else {
            return
        }
    }

    func login_qr_check(key: String) async throws -> (code: Int, message: String) {
        struct Result: Decodable {
            let code: Int
            let message: String?
            let cookie: String?
        }
        let p = [
            "key": key
        ]
        guard
            let ret = try? await doRequest(
                memberName: "login_qr_check", data: p
            ).asType(Result.self)
        else {
            return (0, "No data")
        }

        if ret.code == 803, let cookie = ret.cookie {
            setCookie(cookie)
        }

        return (ret.code, ret.message ?? "No message")
    }

    func login_status() async -> Profile? {
        struct Data: Decodable {
            let profile: Profile?
        }
        struct Result: Decodable {
            let data: Data
        }
        guard let ret = try? await doRequest(memberName: "login_status", data: [:]) else {
            return nil
        }
        return ret.asType(Result.self)?.data.profile
    }

    func history_recommend_songs() async {
        guard let ret = try? await doRequest(memberName: "history_recommend_songs", data: [:])
        else { return }

        print(ret.asAny() ?? "No data")
    }

    func user_playlist(
        uid: UInt64, limit: Int = 30, offset: Int = 0, includeVideo: Bool = true
    )
        async throws
        -> [CloudMusicApi.PlayListItem]?
    {
        guard
            let ret = try? await doRequest(
                memberName: "user_playlist",
                data: [
                    "uid": uid,
                    "limit": limit,
                    "offset": offset,
                    "includeVideo": includeVideo,
                ])
        else { return nil }

        struct Result: Decodable {
            let playlist: [PlayListItem]
            let more: Bool
            let version: String
        }

        // TODO: Fix more = true
        if let parsed = ret.asType(Result.self) {
            return parsed.playlist
        }
        return nil
    }

    func login_cellphone(phone: String, countrycode: Int = 86, password: String) async
        -> Bool
    {
        guard
            let ret = try? await doRequest(
                memberName: "login_cellphone",
                data: [
                    "phone": phone,
                    "countrycode": countrycode,
                    "password": password,
                ])
        else {
            print("login_cellphone failed")
            return false
        }

        struct Result: Decodable {
            let code: Int
            let message: String?
            let cookie: String?
        }

        print(ret.asAny() ?? "No data")

        if let parsed = ret.asType(Result.self) {
            if parsed.code == 200, let cookie = parsed.cookie {
                setCookie(cookie)
                return true
            }
        }
        return false
    }

    func logout() async {
        guard let _ = try? await doRequest(memberName: "logout", data: [:]) else { return }
        setCookie("dummy saved cookie")
    }

    func user_account() async {
        guard let ret = try? await doRequest(memberName: "user_account", data: [:]) else { return }
        print(ret)
    }

    func user_subcount() async {
        guard let ret = try? await doRequest(memberName: "user_subcount", data: [:]) else { return }

        print(ret)
    }

    func user_cloud() async {
        guard let ret: Data = try? await doRequest(memberName: "user_cloud", data: [:]) else {
            return
        }

        print(ret)
    }

    func playlist_detail(id: UInt64) async -> (tracks: [Song], trackIds: [UInt64])? {
        if id == CloudMusicApi.RecommandSongPlaylistId {
            return await recommend_songs().map { ($0, $0.map { $0.id }) }
        }
        guard
            let ret: Data = try? await doRequest(
                memberName: "playlist_detail",
                data: [
                    "id": id
                ])
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
            let ret = try? await doRequest(
                memberName: "song_detail",
                data: [
                    "ids": ids.map { String($0) }.joined(separator: ",")
                ])
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
            let ret = try? await doRequest(
                memberName: "song_url_v1",
                data: [
                    "id": id.map { String($0) }.joined(separator: ","),
                    "level": level,
                ])
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

    func song_download_url(id: UInt64, br: UInt64 = 999000) async -> SongData? {
        guard
            let ret = try? await doRequest(
                memberName: "song_download_url",
                data: [
                    "id": id,
                    "br": br,
                ])
        else { return nil }

        struct Result: Decodable {
            let code: Int
            let data: SongData
        }

        if let parsed = ret.asType(Result.self) {
            return parsed.data
        }
        print("song_download_url failed")
        return nil
    }

    func playlist_track_all(id: UInt64, limit: UInt64?, offset: UInt64?) async -> [Song]? {
        var p: [String: UInt64] = [
            "id": id
        ]
        if let limit = limit {
            p["limit"] = limit
        }
        if let offset = offset {
            p["offset"] = offset
        }
        guard
            let ret = try? await doRequest(
                memberName: "playlist_track_all", data: p)
        else { return nil }

        struct Result: Decodable {
            let code: Int
            let songs: [Song]
        }

        if let parsed = ret.asType(Result.self) {
            return parsed.songs
        }
        print("playlist_track_all failed")
        return nil
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

    func scrobble(song: Song) async {
        let req = [
            [
                "id": song.id,
                "artistid": song.ar.first?.id ?? 0,
                "sourceId": song.al.id,
                "fee": song.fee.rawValue,
                "time": Int(song.dt / 1000),
                "bitrate": Double(song.getHighestQuality()?.br ?? 0) / 1000.0,
                "seq": seq,
                "mspm": mspm,
                "sessionid": 3333,
                "timestamp": Int(Date().timeIntervalSince1970),
            ]
        ]
        guard
            let res = try? await doRequest(
                memberName: "scrobble_pc",
                data: [
                    "actions": req
                ])
        else {
            print("scrobble failed")
            return
        }

        print(res.asAny() ?? "")
    }

    func scrobble_legacy(id: UInt64, sourceid: UInt64, time: Int64) async {
        guard
            let res = try? await doRequest(
                memberName: "scrobble",
                data: [
                    "id": id,
                    "sourceid": sourceid,
                    "time": time,
                ])
        else {
            print("scrobble failed")
            return
        }

        struct Result: Decodable {
            let code: Int
            let data: String
        }

        if let parsed = res.asType(Result.self),
            parsed.code == 200
        {
            print("scrobble success")
        } else {
            print("scrobble failed")
            print(res.asAny() ?? "")
        }
    }

    func cloud(filePath: URL, songName: String?, artist: String?, album: String?) async
        -> UInt64?
    {
        guard
            let data = try? Data(contentsOf: filePath).base64EncodedString()
        else {
            print("cloud failed to read file")
            return nil
        }

        let filename = filePath.lastPathComponent

        let p =
            [
                "dataAsBase64": 1,
                "songFile": [
                    "data": data,
                    "name": filename,
                ],
                "songName": songName ?? filename,
                "artist": artist ?? "未知专辑",
                "album": album ?? "未知艺术家",
            ] as [String: Any]

        guard
            let res = try? await doRequest(
                memberName: "cloud", data: p)
        else {
            print("cloud failed")
            return nil
        }

        struct PrivateCloud: Decodable {
            let songId: UInt64
        }

        struct Result: Decodable {
            let privateCloud: PrivateCloud
        }

        if let parsed = res.asType(Result.self) {
            return parsed.privateCloud.songId
        }
        return nil
    }

    func cloud_match(userId: UInt64, songId: UInt64, adjustSongId: UInt64) async {
        guard
            let res = try? await doRequest(
                memberName: "cloud_match",
                data: [
                    "uid": userId,
                    "sid": songId,
                    "asid": adjustSongId,
                ])
        else {
            print("cloud_match failed")
            return
        }
        print(res.asAny() ?? "")
    }

    func likelist(userId: UInt64) async -> [UInt64]? {
        guard
            let res = try? await doRequest(
                memberName: "likelist",
                data: [
                    "uid": userId
                ])
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
            let res = try? await doRequest(
                memberName: "like",
                data: [
                    "id": id,
                    "like": like ? "true" : "false",
                ])
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
            let res = try? await doRequest(
                memberName: "recommend_resource",
                data: [:])
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
            let res = try? await doRequest(
                memberName: "recommend_songs",
                data: [:])
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
                    originCoverType: .unknown,
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
            let res = try? await doRequest(
                memberName: "search_suggest",
                data: [
                    "keywords": keyword
                ])
        else {
            print("search_suggest failed")
            return nil
        }

        struct SuggestResult: Decodable {
            let songs: [SearchResult.Song]
        }

        struct Result: Decodable {
            let code: Int
            let result: SuggestResult
        }
        if let parsed = res.asType(Result.self) {
            return parsed.result.songs
        }
        print("search_suggest failed")
        return nil
    }

    func search(
        keyword: String, type: SearchType = .singleSong, limit: Int = 30, offset: Int = 0
    ) async
        -> [SearchResult.Song]?
    {
        guard
            let res = try? await doRequest(
                memberName: "search",
                data: [
                    "keywords": keyword,
                    "type": type.rawValue,
                    "limit": limit,
                    "offset": offset,
                ])
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

    func playlist_tracks(op: PlaylistTracksOp, playlistId: UInt64, trackIds: [uint64])
        async throws
    {
        guard
            let res = try? await doRequest(
                memberName: "playlist_tracks",
                data: [
                    "op": op.rawValue,
                    "pid": playlistId,
                    "tracks": trackIds.map { String($0) }.joined(separator: ","),
                ])
        else {
            print("playlist_tracks failed")
            return
        }

        struct ErrorResult: Decodable {
            let code: Int
            let message: String
        }

        if let error = res.asType(ErrorResult.self) {
            throw RequestError.errorCode((error.code, error.message))
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
            let tlyric = self.tlyric.parse()
            let romalrc = self.romalrc.parse()

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

                if time >= 0 {
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
        let tlyric: LyricNew.Lyric
        let romalrc: LyricNew.Lyric
    }

    func lyric_new(id: UInt64) async -> LyricNew? {
        guard
            let res = try? await doRequest(
                memberName: "lyric_new",
                data: [
                    "id": id
                ])
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
