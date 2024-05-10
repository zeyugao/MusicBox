//
//  CloudMusicApi.swift
//  MusicBox
//
//  Created by Elsa on 2024/4/20.
//

import Foundation

enum RequestError: Error {
    case error(Error)
    case noData
    case errorCode((Int, String))
    case Request(String)
    case unknown
}

struct ServerError: Decodable, Error {
    let code: Int
    let msg: String?
    let message: String?
}

extension Data {
    func asType<T: Decodable>(_ type: T.Type) -> T? {
        return try? JSONDecoder().decode(type, from: self)
    }

    func asAny() -> Any? {
        return try? JSONSerialization.jsonObject(with: self, options: [])
    }
}

class CloudMusicApi {
    struct Profile: Decodable {
        let avatarUrl: String
        let nickname: String
        let userId: UInt64
    }

    struct PlayListItem: Identifiable, Decodable, Equatable {
        static func == (lhs: CloudMusicApi.PlayListItem, rhs: CloudMusicApi.PlayListItem) -> Bool {
            return lhs.id == rhs.id
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

    struct Quality: Decodable {
        let br: UInt64
        let size: UInt64
    }

    struct Album: Decodable {
        let id: UInt64
        let name: String
        let pic: UInt64
        let picUrl: String
        let tns: [String]
    }

    struct Artist: Decodable {
        let id: UInt64
        let name: String

        let alias: [String]
        let tns: [String]
    }

    struct CloudMusic: Decodable {
        let alb: String
        let ar: String
        let br: UInt64
        let fn: String
        let sn: String
        let uid: UInt64
    }

    enum Fee: Int, Decodable {
        case free = 0  // 免费或无版权
        case vip = 1  // VIP 歌曲
        case album = 4  // 购买专辑
        case trial = 8  // 非会员可免费播放低音质，会员可播放高音质及下载
    }

    enum OriginCoverType: Int, Decodable {
        case unknown = 0
        case origin = 1
        case cover = 2
    }

    struct Song: Decodable, Identifiable {
        let name: String
        let id: UInt64

        let al: Album
        let ar: [Artist]

        let alia: [String]

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

    static private func doRequest(
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
                let jsonData = try JSONSerialization.data(withJSONObject: data)

                let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

                memberName.withCString { memberName in
                    let memberName = UnsafeMutablePointer(mutating: memberName)
                    jsonString.withCString { jsonString in
                        let jsonString = UnsafeMutablePointer(mutating: jsonString)
                        let jsonResultCString = invoke(memberName, jsonString)
                        if let cString = jsonResultCString {
                            let jsonResult = String(cString: cString)

                            if let jsonData = jsonResult.data(using: .utf8) {
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

    static func login_qr_key(max_retries: UInt = 3) async throws -> String {
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

    static func login_qr_create(key: String) async throws -> String {
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

    static func setCookie(_ cookie: String) {
        UserDefaults.standard.set(cookie, forKey: SaveCookieName)
    }

    static func getCookie() -> String? {
        return UserDefaults.standard.string(forKey: SaveCookieName)
    }

    static func login_refresh() async throws {
        guard
            (try? await doRequest(
                memberName: "login_refresh",
                data: [:])) != nil
        else {
            return
        }
    }

    static func login_qr_check(key: String) async throws -> (code: Int, message: String) {
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

    static func login_status() async -> Profile? {
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

    static func history_recommend_songs() async {
        guard let ret = try? await doRequest(memberName: "history_recommend_songs", data: [:])
        else { return }

        print(ret.asAny() ?? "No data")
    }

    static func user_playlist(
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

    static func user_account() async {
        guard let ret = try? await doRequest(memberName: "user_account", data: [:]) else { return }
        print(ret)
    }

    static func user_subcount() async {
        guard let ret = try? await doRequest(memberName: "user_subcount", data: [:]) else { return }

        print(ret)
    }

    static func user_cloud() async {
        guard let ret: Data = try? await doRequest(memberName: "user_cloud", data: [:]) else {
            return
        }

        print(ret)
    }

    static func playlist_detail(id: UInt64) async -> (tracks: [Song], trackIds: [UInt64])? {
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

    static func song_detail(ids: [UInt64]) async -> [Song]? {
        guard
            let ret = try? await doRequest(
                memberName: "song_detail",
                data: [
                    "id": ids.map { String($0) }.joined(separator: ",")
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

    static func song_url_v1(id: [UInt64], level: String = "jymaster") async -> [SongData]? {
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
        print(ret.asAny() ?? "")
        print("song_url_v1 failed")
        return nil
    }

    static func song_download_url(id: UInt64, br: UInt64 = 999000) async -> SongData? {
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
        print(ret.asAny() ?? "")
        print("song_download_url failed")
        return nil
    }

    static func playlist_track_all(id: UInt64, limit: UInt64?, offset: UInt64?) async -> [Song]? {
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
}
