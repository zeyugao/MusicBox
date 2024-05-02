//
//  NeteaseMusicAPI.swift
//  NeteaseMusic
//
//  Created by xjbeta on 2019/3/31.
//  Copyright © 2019 xjbeta. All rights reserved.
//

import Alamofire
import Foundation

class NeteaseMusicAPI {

    let nmDeviceId: String
    let nmAppver: String
    let channel: NMChannel
    let nmSession: Session
    var reachabilityManager: NetworkReachabilityManager?

    init() {
        nmDeviceId = "\(UUID().uuidString)|\(UUID().uuidString)"
        nmAppver = "1.5.10"
        channel = NMChannel(nmDeviceId, nmAppver)

        let session = Session(configuration: .default)
        let cookies = [
            "deviceId",
            "os",
            "appver",
            "MUSIC_U",
            "__csrf",
            "ntes_kaola_ad",
            "channel",
            "__remember_me",
            "NMTID",
            "osver",
        ]

        session.sessionConfiguration.httpCookieStorage?.cookies?.filter {
            !cookies.contains($0.name)
        }.forEach {
            session.sessionConfiguration.httpCookieStorage?.deleteCookie($0)
        }

        [
            "deviceId": nmDeviceId,
            "os": "osx",
            "appver": nmAppver,
            "channel": "netease",
            "osver": "Version%2010.16%20(Build%2020G165)",
        ].compactMap {
            HTTPCookie(properties: [
                .domain: ".music.163.com",
                .name: $0.key,
                .value: $0.value,
                .path: "/",
            ])
        }.forEach {
            session.sessionConfiguration.httpCookieStorage?.setCookie($0)
        }

        session.sessionConfiguration.headers = HTTPHeaders.default
        session.sessionConfiguration.headers.update(
            name: "user-agent",
            value:
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_16) AppleWebKit/605.1.15 (KHTML, like Gecko)"
        )
        nmSession = session
    }

    var uid = -1
    var csrf: String {
        return HTTPCookieStorage.shared.cookies?.filter({ $0.name == "__csrf" }).first?.value ?? ""
    }

    struct CodeResult: Decodable {
        let code: Int
        let msg: String?
    }

    func startNRMListening() {
        stopNRMListening()

        reachabilityManager = NetworkReachabilityManager(host: "music.163.com")
        reachabilityManager?.startListening { status in
            switch status {
            case .reachable(.cellular):
                Log.error("NetworkReachability reachable cellular.")
            case .reachable(.ethernetOrWiFi):
                Log.error("NetworkReachability reachable ethernetOrWiFi.")
            case .notReachable:
                Log.error("NetworkReachability notReachable.")
            case .unknown:
                break
            }
        }
    }

    func stopNRMListening() {
        reachabilityManager?.stopListening()
        reachabilityManager = nil
    }

    func loginQrKey() async throws -> String {
        struct Result: Decodable {
            let code: Int
            let data: String
        }

        let p = [
            "type": 1
        ]

        let result: Result = try await eapiRequest(
            "https://music.163.com/weapi/login/qrcode/unikey",
            p,
            Result.self
        )

        guard result.code == 200 else {
            throw RequestError.errorCode((result.code, ""))
        }

        return result.data
    }

    func nuserAccount() async throws -> NUserProfile? {
        struct Result: Decodable {
            let code: Int
            let profile: NUserProfile?
        }

        let result: Result = try await eapiRequest(
            "https://music.163.com/eapi/nuser/account/get", [:], Result.self)
        guard result.code == 200 else { return nil }
        return result.profile
    }

    func userPlaylist() async throws -> [Playlist] {
        struct Result: Decodable {
            let playlist: [Playlist]
            let code: Int
        }

        let p = [
            "uid": uid,
            "offset": 0,
            "limit": 1000,
        ]

        let result = try await eapiRequest(
            "https://music.163.com/eapi/user/playlist/",
            p,
            Result.self
        )

        guard result.code == 200 else {
            throw RequestError.errorCode((result.code, ""))
        }

        return result.playlist
    }

    func playlistDetail(_ id: Int) async throws -> Playlist {
        struct Result: Decodable {
            let playlist: Playlist
            let privileges: [Track.Privilege]?
            let code: Int
        }

        let p = [
            "id": id,
            "n": 0,
            "s": 0,
            "t": -1,
        ]

        let result: Result = try await eapiRequest(
            "https://music.163.com/eapi/v3/playlist/detail",
            p,
            Result.self
        )

        guard let ids = result.playlist.trackIds?.map({ $0.id }) else {
            throw NSError(domain: "No track ids found", code: 0, userInfo: nil)
        }

        let playlists = ids.chunked(into: 500).map { Array(ids[$0.startIndex..<($0.endIndex)]) }

        var tracks = [Track]()
        for playlistIds in playlists {
            let bTracks = try await songDetail(playlistIds)
            tracks.append(contentsOf: bTracks)
        }

        var playlist = result.playlist

        playlist.tracks = tracks
        playlist.tracks?.forEach { track in
            track.from = (playlist.id, playlist.name)
        }

        return playlist
    }

    func songUrl(_ ids: [Int], _ br: Int) async throws -> [Song] {
        struct Result: Decodable {
            let data: [Song]
            let code: Int
        }

        let p: [String: Any] = [
            "ids": ids,
            "br": br,
            "e_r": true,
        ]

        let result = try await eapiRequest(
            "https://music.163.com/eapi/song/enhance/player/url",
            p,
            Result.self,
            shouldDeSerial: true
        )

        guard result.code == 200 else {
            throw RequestError.errorCode((result.code, ""))
        }

        return result.data
    }

    func lyric(_ id: Int) async throws -> LyricResult? {
        let url = "https://music.163.com/api/song/lyric?os=osx&id=\(id)&lv=-1&kv=-1&tv=-1"
        let response = await AF.request(url).serializingDecodable(LyricResult.self).response
        return response.value
    }

    //    func search(_ keywords: String,
    //                limit: Int,
    //                page: Int,
    //                type: SearchResultViewController.ResultType) -> Promise<SearchResult.Result> {
    //        var p: [String: Any] = [
    //            "s": keywords,
    //            "limit": limit,
    //            "offset": page * limit,
    //            "total": true
    //        ]
    //
    //
    //        var u = "https://music.163.com/eapi/search/pc"
    //
    //        // 1: 单曲, 10: 专辑, 100: 歌手, 1000: 歌单, 1002: 用户, 1004: MV, 1006: 歌词, 1009: 电台, 1014: 视频
    //        switch type {
    //        case .songs:
    //            p["type"] = 1
    //            u = "https://music.163.com/eapi/cloudsearch/pc"
    //        case .albums:
    //            p["type"] = 10
    //        case .artists:
    //            p["type"] = 100
    //        case .playlists:
    //            p["type"] = 1000
    //        default:
    //            p["type"] = 0
    //        }
    //
    //        return eapiRequest(u,
    //                           p,
    //                           SearchResult.self).map {
    //                            $0.result.songs.forEach {
    //                                $0.from = (.searchResults, 0, "Search Result")
    //                            }
    //                            return $0.result
    //        }
    //    }

    func album(_ id: Int) async throws -> AlbumResult {
        let url = "https://music.163.com/eapi/v1/album/\(id)"
        var albumResult: AlbumResult = try await eapiRequest(
            url,
            [:],
            AlbumResult.self
        )

        albumResult.songs.forEach { song in
            song.from = (id, albumResult.album.name)
            if song.album.picUrl == nil {
                song.album.picUrl = albumResult.album.picUrl
            }
        }

        return albumResult
    }

    func albumSublist() async throws -> [Track.Album] {
        struct Result: Decodable {
            let code: Int
            let data: [Track.Album]
            let hasMore: Bool
        }

        let p: [String: Any] = [
            "limit": 1000,
            "offset": 0,
            "total": true,
        ]
        let result = try await eapiRequest(
            "https://music.163.com/eapi/album/sublist",
            p,
            Result.self
        )

        guard result.code == 200 else {
            throw RequestError.errorCode((result.code, ""))
        }

        return result.data
    }

    //    func artistSublist() -> Promise<[Track.Artist]> {
    //        struct Result: Decodable {
    //            let code: Int
    //            let data: [Track.Artist]
    //            let hasMore: Bool
    //        }
    //
    //        let p: [String: Any] = [
    //            "limit": 1000,
    //            "offset": 0,
    //            "total": true,
    //        ]
    //        return eapiRequest(
    //            "https://music.163.com/eapi/artist/sublist",
    //            p,
    //            Result.self
    //        ).map {
    //            $0.data.forEach {
    //                $0.picUrl = $0.picUrl?.https
    //            }
    //            return $0.data
    //        }
    //    }

    func artist(_ id: Int) async throws -> ArtistResult {
        let p: [String: Any] = [
            "id": id,
            "ext": "true",
            "top": "50",
            "private_cloud": "true",
        ]
        let result = try await eapiRequest(
            "https://music.163.com/eapi/v1/artist/\(id)",
            p,
            ArtistResult.self)
        guard result.code == 200 else {
            throw RequestError.errorCode((result.code, ""))
        }

        return result
    }

    func artistAlbums(_ id: Int) async throws -> ArtistAlbumsResult {
        let p: [String: Any] = [
            "limit": 1000,
            "offset": 0,
            "total": true,
        ]

        let result = try await eapiRequest(
            "https://music.163.com/eapi/artist/albums/\(id)",
            p,
            ArtistAlbumsResult.self)
        guard result.code == 200 else {
            throw RequestError.errorCode((result.code, ""))
        }

        return result
    }
    //
    //    func like(_ id: Int, _ like: Bool = true, _ time: Int = 25) -> Promise<()> {
    //        struct Result: Decodable {
    //            let code: Int
    //            let playlistId: Int
    //        }
    //
    //        let p: [String: Any] = [
    //            "time": time,
    //            "trackId": id,
    //            "alg": "itembased",
    //            "like": like,
    //        ]
    //
    //        return eapiRequest(
    //            "https://music.163.com/eapi/radio/like",
    //            p,
    //            Result.self
    //        ).map {
    //            if $0.code == 200 {
    //                return ()
    //            } else {
    //                throw RequestError.errorCode(($0.code, ""))
    //            }
    //        }
    //    }
    //
    //    func likeList() -> Promise<[Int]> {
    //        struct Result: Decodable {
    //            let code: Int
    //            let ids: [Int]
    //        }
    //        let p = ["uid": uid]
    //
    //        return eapiRequest(
    //            "https://music.163.com/eapi/song/like/get",
    //            p,
    //            Result.self
    //        ).map {
    //            if $0.code == 200 {
    //                return $0.ids
    //            } else {
    //                throw RequestError.errorCode(($0.code, ""))
    //            }
    //        }
    //
    //    }
    //
    //    func fmTrash(id: Int, _ time: Int = 25, _ add: Bool = true) -> Promise<()> {
    //        struct Result: Decodable {
    //            let code: Int
    //        }
    //
    //        var p = [String: Any]()
    //        if add {
    //            p = [
    //                "songId": id,
    //                "alg": "redRec",
    //                "time": time,
    //            ]
    //        } else {
    //            p = [
    //                "songIds": "[\(id)]"
    //            ]
    //        }
    //
    //        let u =
    //            add
    //            ? "https://music.163.com/eapi/radio/trash/add"
    //            : "https://music.163.com/eapi/radio/trash/del/batch"
    //
    //        return eapiRequest(
    //            u,
    //            p,
    //            Result.self
    //        ).map {
    //            if $0.code == 200 {
    //                return ()
    //            } else {
    //                throw RequestError.errorCode(($0.code, ""))
    //            }
    //        }
    //    }
    //
    //    func fmTrashList() -> Promise<([Track])> {
    //        struct Result: Decodable {
    //            let code: Int
    //            let data: [Track]
    //        }
    //
    //        return eapiRequest(
    //            "https://music.163.com/eapi/v3/radio/trash/get",
    //            [:],
    //            Result.self
    //        ).map {
    //            $0.data
    //        }
    //    }
    //
    //    func playlistTracks(add: Bool, _ trackIds: [Int], to playlistId: Int) -> Promise<()> {
    //        let p: [String: Any] = [
    //            "op": add ? "add" : "del",
    //            "pid": playlistId,
    //            "trackIds": "\(trackIds)",
    //            "imme": true,
    //        ]
    //
    //        return eapiRequest(
    //            "https://music.163.com/eapi/v1/playlist/manipulate/tracks",
    //            p,
    //            CodeResult.self
    //        ).map {
    //            if $0.code == 200 {
    //                return ()
    //            } else {
    //                throw RequestError.errorCode(($0.code, $0.msg ?? ""))
    //            }
    //        }
    //    }
    //
    //    func playlistCreate(_ name: String, privacy: Bool = false) -> Promise<()> {
    //        let p: [String: Any] = [
    //            "name": name,
    //            "uid": uid,
    //            "privacy": privacy ? 10 : 0,
    //        ]
    //
    //        return eapiRequest(
    //            "https://music.163.com/eapi/playlist/create",
    //            p,
    //            CodeResult.self
    //        ).map {
    //            if $0.code == 200 {
    //                return ()
    //            } else {
    //                throw RequestError.errorCode(($0.code, $0.msg ?? ""))
    //            }
    //        }
    //    }
    //
    //    func discoveryRecommendDislike(_ id: Int, isPlaylist: Bool = false, alg: String = "")
    //        -> Promise<((Track?, RecommendResource.Playlist?))>
    //    {
    //        var p: [String: Any] = [
    //            "resId": id,
    //            "resType": isPlaylist ? 1 : 4  // daily 4  playlist 1,,
    //        ]
    //
    //        p["sceneType"] = isPlaylist ? nil : 1  // daily 1  playlist nil
    //        p["alg"] = isPlaylist ? alg : nil  // daily 1  playlist nil
    //
    //        class Result: Decodable {
    //            let code: Int
    //            let track: Track?
    //            let playlist: RecommendResource.Playlist?
    //
    //            enum CodingKeys: String, CodingKey {
    //                case code, data
    //            }
    //
    //            required init(from decoder: Decoder) throws {
    //                let container = try decoder.container(keyedBy: CodingKeys.self)
    //                self.code = try container.decode(Int.self, forKey: .code)
    //                self.track = try? container.decodeIfPresent(Track.self, forKey: .data)
    //                self.playlist = try? container.decodeIfPresent(
    //                    RecommendResource.Playlist.self, forKey: .data)
    //            }
    //        }
    //
    //        //        code == 432, msg == "今日暂无更多推荐"
    //        return eapiRequest(
    //            "https://music.163.com/eapi/discovery/recommend/dislike",
    //            p,
    //            Result.self
    //        ).map {
    //            if $0.code == 200 {
    //                return (($0.track, $0.playlist))
    //            } else {
    //                throw RequestError.errorCode(($0.code, ""))
    //            }
    //        }
    //    }
    //
    //    func playlistDelete(_ id: Int) -> Promise<()> {
    //        struct Result: Decodable {
    //            let code: Int
    //            let id: Int
    //        }
    //        let p = [
    //            "pid": id,
    //            "id": id,
    //        ]
    //
    //        return eapiRequest(
    //            "https://music.163.com/eapi/playlist/delete",
    //            p,
    //            Result.self
    //        ).map {
    //            if $0.code == 200, $0.id == id {
    //                return ()
    //            } else {
    //                throw RequestError.errorCode(($0.code, ""))
    //            }
    //        }
    //    }

    func logout() async throws {
        let result = try await eapiRequest(
            "https://music.163.com/eapi/logout",
            [:],
            CodeResult.self
        )

        guard result.code == 200 else {
            throw RequestError.errorCode((result.code, result.msg ?? ""))
        }
    }

    func songDetail(_ ids: [Int]) async throws -> [Track] {
        struct Result: Decodable {
            let songs: [Track]
            let code: Int
            let privileges: [Track.Privilege]
        }

        let c = "[" + ids.map({ "{\"id\":\"\($0)\", \"v\":\"\(0)\"}" }).joined(separator: ",") + "]"

        let p = [
            "c": c
        ]

        let result: Result = try await eapiRequest(
            "https://music.163.com/eapi/v3/song/detail",
            p,
            Result.self
        )

        guard result.code == 200, result.songs.count == result.privileges.count else {
            throw RequestError.errorCode((result.code, ""))
        }

        var songs = result.songs
        let privileges = result.privileges

        for index in songs.indices {
            if songs[index].id == privileges[index].id {
                songs[index].privilege = privileges[index]
            }
        }

        return songs

    }

    private func eapiRequest<T: Decodable>(
        _ url: String,
        _ params: [String: Any],
        _ resultType: T.Type,
        shouldDeSerial: Bool = false,
        debug: Bool = false
    ) async throws -> T {

        let p = try channel.serialData(params, url: url)

        let response = await nmSession.request(url, method: .post, parameters: ["params": p])
            .serializingDecodable(T.self).response

        if debug, let d = response.data, let str = String(data: d, encoding: .utf8) {
            Log.verbose(str)
        }

        guard var data = response.data else {
            throw RequestError.noData
        }

        if shouldDeSerial {
            guard
                let deSerialData = try self.channel.deSerialData(data.toHexString(), split: false),
                let newData = deSerialData.data(using: .utf8)
            else {
                throw RequestError.noData
            }
            data = newData
        }

        if let serverError = try? JSONDecoder().decode(ServerError.self, from: data),
            serverError.code != 200
        {
            var msg = serverError.msg ?? serverError.message ?? ""

            if serverError.code == -462 {
                msg = "绑定手机号或短信验证成功后，可进行下一步操作哦~🙃"
            }

            let u = response.request?.url?.absoluteString ?? ""
            throw RequestError.errorCode((serverError.code, "\(u)  \(msg)"))
        }

        return try JSONDecoder().decode(resultType.self, from: data)
    }

    enum RequestError: Error {
        case error(Error)
        case noData
        case errorCode((Int, String))
        case unknown
    }

    enum APIError: Error {
        case errorCode(Int)
    }

}

extension Encodable {
    func jsonString() -> String {
        guard let data = try? JSONEncoder().encode(self),
            let str = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return str
    }
}

extension Array {
    func chunked(into size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map {
            self[$0..<Swift.min($0 + size, count)]
        }
    }
}
