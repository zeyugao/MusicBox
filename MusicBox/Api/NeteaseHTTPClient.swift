//
//  NeteaseHTTPClient.swift
//  MusicBox
//
//  Native HTTP transport for the subset of NetEase endpoints used by MusicBox.
//

import CryptoKit
import Foundation

final class NeteaseHTTPClient {
    static let shared = NeteaseHTTPClient()

    private static let apiBaseURL = URL(string: "https://interface.music.163.com")!
    private static let userAgent =
        "NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)"
    private static let defaultOSVersion = "16.2"
    private static let defaultAppVersion = "9.0.90"
    private static let cookieMigrationKey = "NeteaseNativeHTTPMigrationCompleted"
    private static let deviceIDKey = "NeteaseNativeHTTPDeviceID"

    private let session: URLSession
    private let defaults: UserDefaults
    private let cookieLock = NSLock()
    private let deviceId: String

    init(
        session: URLSession = NeteaseHTTPClient.makeDefaultSession(),
        defaults: UserDefaults = .standard,
        deviceId: String? = nil
    ) {
        self.session = session
        self.defaults = defaults
        if let deviceId {
            self.deviceId = deviceId
        } else if let savedDeviceID = defaults.string(forKey: Self.deviceIDKey), !savedDeviceID.isEmpty {
            self.deviceId = savedDeviceID
        } else {
            let generatedDeviceID = Self.randomHex(length: 52)
            defaults.set(generatedDeviceID, forKey: Self.deviceIDKey)
            self.deviceId = generatedDeviceID
        }
    }

    static func migrateLegacyAuthenticationIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: cookieMigrationKey) else { return }

        defaults.removeObject(forKey: CloudMusicApi.SaveCookieName)
        defaults.removeObject(forKey: "profile")
        defaults.removeObject(forKey: "playlists")
        defaults.removeObject(forKey: "likelist")
        defaults.set(true, forKey: cookieMigrationKey)
        SharedCacheManager.shared.clear()
    }

    func setCookie(_ cookie: String) {
        cookieLock.lock()
        defaults.set(cookie, forKey: CloudMusicApi.SaveCookieName)
        cookieLock.unlock()
    }

    func clearCookie() {
        cookieLock.lock()
        defaults.removeObject(forKey: CloudMusicApi.SaveCookieName)
        cookieLock.unlock()
    }

    func cookie() -> String? {
        cookieLock.lock()
        defer { cookieLock.unlock() }
        return defaults.string(forKey: CloudMusicApi.SaveCookieName)
    }

    func loginQRCodeKey(cacheTtl: TimeInterval = 0) async throws -> Data {
        try await perform(
            path: "/api/login/qrcode/unikey",
            fields: ["type": 3],
            cacheTtl: cacheTtl
        )
    }

    func loginQRCodeURL(key: String) -> String {
        "https://music.163.com/login?codekey=\(key)"
    }

    func loginQRCodeCheck(key: String, cacheTtl: TimeInterval = 0) async throws -> Data {
        try await perform(
            path: "/api/login/qrcode/client/login",
            fields: ["key": key, "type": 3],
            cacheTtl: cacheTtl
        )
    }

    func loginRefresh(cacheTtl: TimeInterval = 0) async throws -> Data {
        try await perform(path: "/api/login/token/refresh", fields: [:], cacheTtl: cacheTtl)
    }

    func loginStatus(cacheTtl: TimeInterval = 0) async throws -> Data {
        try await perform(path: "/api/w/nuser/account/get", fields: [:], cacheTtl: cacheTtl)
    }

    func loginCellphone(
        phone: String,
        countryCode: Int,
        password: String,
        cacheTtl: TimeInterval = 0
    ) async throws -> Data {
        try await perform(
            path: "/api/w/login/cellphone",
            fields: [
                "type": "0",
                "https": "true",
                "phone": phone,
                "countrycode": countryCode,
                "password": Self.md5(password),
                "rememberLogin": "true",
            ],
            cacheTtl: cacheTtl
        )
    }

    func logout(cacheTtl: TimeInterval = 0) async throws -> Data {
        try await perform(path: "/api/logout", fields: [:], cacheTtl: cacheTtl)
    }

    func userPlaylist(
        userID: UInt64,
        limit: Int,
        offset: Int,
        includeVideo: Bool,
        cacheTtl: TimeInterval = 0
    ) async throws -> Data {
        try await perform(
            path: "/api/user/playlist",
            fields: [
                "uid": userID,
                "limit": limit,
                "offset": offset,
                "includeVideo": includeVideo,
            ],
            cacheTtl: cacheTtl
        )
    }

    func userCloud(limit: Int, offset: Int, cacheTtl: TimeInterval = 0) async throws -> Data {
        try await perform(
            path: "/api/v1/cloud/get",
            fields: ["limit": limit, "offset": offset],
            cacheTtl: cacheTtl
        )
    }

    func playlistDetail(id: UInt64, cacheTtl: TimeInterval = 0) async throws -> Data {
        try await perform(
            path: "/api/v6/playlist/detail",
            fields: Self.playlistDetailFields(id: id),
            cacheTtl: cacheTtl
        )
    }

    func invalidatePlaylistDetail(id: UInt64) {
        invalidateCache(path: "/api/v6/playlist/detail", fields: Self.playlistDetailFields(id: id))
    }

    func songDetail(ids: [UInt64], cacheTtl: TimeInterval = 0) async throws -> Data {
        let songs = ids.map { ["id": $0] }
        return try await perform(
            path: "/api/v3/song/detail",
            fields: ["c": try Self.jsonString(songs)],
            cacheTtl: cacheTtl
        )
    }

    func songURL(
        ids: [UInt64],
        level: String,
        cacheTtl: TimeInterval = 0
    ) async throws -> Data {
        try await perform(
            path: "/api/song/enhance/player/url/v1",
            fields: [
                "ids": "[\(ids.map(String.init).joined(separator: ","))]",
                "level": level,
                "encodeType": "flac",
            ],
            cacheTtl: cacheTtl
        )
    }

    func comments(
        type: Int,
        resourceID: UInt64,
        pageNo: Int,
        pageSize: Int,
        sortType: Int,
        cursor: Int64?,
        cacheTtl: TimeInterval = 0
    ) async throws -> Data {
        let resourcePrefix = try Self.commentResourcePrefix(type)
        let normalizedSortType = sortType == 1 ? 99 : sortType
        let requestCursor: String
        switch normalizedSortType {
        case 99:
            requestCursor = String((pageNo - 1) * pageSize)
        case 2:
            requestCursor = "normalHot#\((pageNo - 1) * pageSize)"
        case 3:
            requestCursor = String(cursor ?? 0)
        default:
            requestCursor = ""
        }
        return try await perform(
            path: "/api/v2/resource/comments",
            fields: [
                "threadId": "\(resourcePrefix)\(resourceID)",
                "pageNo": pageNo,
                "showInner": true,
                "pageSize": pageSize,
                "cursor": requestCursor,
                "sortType": normalizedSortType,
            ],
            cacheTtl: cacheTtl
        )
    }

    func floorComments(
        parentCommentID: UInt64,
        resourceID: UInt64,
        type: Int,
        limit: Int,
        time: Int64?,
        cacheTtl: TimeInterval = 0
    ) async throws -> Data {
        let resourcePrefix = try Self.commentResourcePrefix(type)
        return try await perform(
            path: "/api/resource/comment/floor/get",
            fields: [
                "parentCommentId": parentCommentID,
                "threadId": "\(resourcePrefix)\(resourceID)",
                "time": time ?? -1,
                "limit": limit,
            ],
            cacheTtl: cacheTtl
        )
    }

    func scrobble(
        songID: UInt64,
        sourceID: UInt64,
        playedTime: Int,
        cacheTtl: TimeInterval = 0
    ) async throws -> Data {
        let logs: [[String: Any]] = [
            [
                "action": "play",
                "json": [
                    "download": 0,
                    "end": "playend",
                    "id": songID,
                    "sourceId": sourceID,
                    "time": playedTime,
                    "type": "song",
                    "wifi": 0,
                    "source": "list",
                ],
            ]
        ]
        return try await perform(
            path: "/api/feedback/weblog",
            fields: ["logs": try Self.jsonString(logs)],
            cacheTtl: cacheTtl
        )
    }

    func cloudMatch(
        userID: UInt64,
        songID: UInt64,
        adjustedSongID: UInt64,
        cacheTtl: TimeInterval = 0
    ) async throws -> Data {
        try await perform(
            path: "/api/cloud/user/song/match",
            fields: [
                "userId": userID,
                "songId": songID,
                "adjustSongId": adjustedSongID,
            ],
            cacheTtl: cacheTtl
        )
    }

    func likedSongIDs(userID: UInt64, cacheTtl: TimeInterval = 0) async throws -> Data {
        try await perform(
            path: "/api/song/like/get",
            fields: ["uid": userID],
            cacheTtl: cacheTtl
        )
    }

    func setLiked(
        songID: UInt64,
        liked: Bool,
        cacheTtl: TimeInterval = 0
    ) async throws -> Data {
        try await perform(
            path: "/api/radio/like",
            fields: [
                "alg": "itembased",
                "trackId": songID,
                "like": liked,
                "time": "3",
            ],
            cacheTtl: cacheTtl
        )
    }

    func recommendedResources(cacheTtl: TimeInterval = 0) async throws -> Data {
        try await perform(
            path: "/api/v1/discovery/recommend/resource",
            fields: [:],
            cacheTtl: cacheTtl
        )
    }

    func recommendedSongs(cacheTtl: TimeInterval = 0) async throws -> Data {
        try await perform(
            path: "/api/v3/discovery/recommend/songs",
            fields: [:],
            cacheTtl: cacheTtl
        )
    }

    func searchSuggestions(keyword: String, cacheTtl: TimeInterval = 0) async throws -> Data {
        try await perform(
            path: "/api/search/suggest/web",
            fields: ["s": keyword],
            cacheTtl: cacheTtl
        )
    }

    func search(
        keyword: String,
        type: Int,
        limit: Int,
        offset: Int,
        cacheTtl: TimeInterval = 0
    ) async throws -> Data {
        try await perform(
            path: "/api/search/get",
            fields: [
                "s": keyword,
                "type": type,
                "limit": limit,
                "offset": offset,
            ],
            cacheTtl: cacheTtl
        )
    }

    func updatePlaylistTracks(
        operation: String,
        playlistID: UInt64,
        trackIDs: [UInt64],
        cacheTtl: TimeInterval = 0
    ) async throws -> Data {
        try await perform(
            path: "/api/playlist/manipulate/tracks",
            fields: [
                "op": operation,
                "pid": playlistID,
                "trackIds": try Self.jsonString(trackIDs.map(String.init)),
                "imme": "true",
            ],
            cacheTtl: cacheTtl
        )
    }

    func lyrics(songID: UInt64, cacheTtl: TimeInterval = 0) async throws -> Data {
        try await perform(
            path: "/api/song/lyric/v1",
            fields: [
                "id": songID,
                "cp": false,
                "tv": 0,
                "lv": 0,
                "rv": 0,
                "kv": 0,
                "yv": 0,
                "ytv": 0,
                "yrv": 0,
            ],
            cacheTtl: cacheTtl
        )
    }

    private func perform(
        path: String,
        fields: [String: Any],
        cacheTtl: TimeInterval
    ) async throws -> Data {
        let cacheKey = cacheKey(path: path, fields: fields)
        do {
            if cacheTtl != 0, let cachedData = SharedCacheManager.shared.get(for: cacheKey) as? Data {
                try validateServerResponse(cachedData, cacheKey: cacheKey)
                return cachedData
            }

            let response = try await post(path: path, fields: fields)
            mergeCookies(from: response.response)
            try validateServerResponse(response.data, cacheKey: cacheKey)
            if cacheTtl != 0 {
                SharedCacheManager.shared.set(value: response.data, for: cacheKey, ttl: cacheTtl)
            }
            return response.data
        } catch let error as RequestError {
            throw error
        } catch {
            throw RequestError.error(error)
        }
    }

    private func validateServerResponse(_ data: Data, cacheKey: String) throws {
        guard let serverError = data.asType(ServerError.self, silent: true) else { return }
        let message = serverError.msg ?? serverError.message ?? ""
        if serverError.code == 502, message.localizedCaseInsensitiveContains("RST_STREAM") {
            SharedCacheManager.shared.invalidate(for: cacheKey)
            throw RequestError.errorCode((serverError.code, message))
        }
        if serverError.code == -462 {
            SharedCacheManager.shared.invalidate(for: cacheKey)
            throw RequestError.errorCode((
                serverError.code,
                "绑定手机号或短信验证成功后，可进行下一步操作哦~🙃"
            ))
        }
    }

    func uploadCloudFile(
        fileURL: URL,
        songName: String?,
        artist: String?,
        album: String?,
        progress: @escaping TransferProgressHandler = { _ in }
    ) async throws -> UInt64? {
        let values = try fileMetadata(at: fileURL)
        let fileName = fileURL.lastPathComponent
        let ext = fileURL.pathExtension.lowercased() == "flac" ? "flac" : "mp3"
        let normalizedName = Self.normalizedUploadName(fileName, ext: ext)
        progress(
            TransferProgress(
                completedBytes: 0,
                totalBytes: values.size,
                stage: .preparing
            )
        )

        let checkResponse = try await post(
            path: "/api/cloud/upload/check",
            fields: [
                "bitrate": "999000",
                "ext": "",
                "length": values.size,
                "md5": values.md5,
                "songId": "0",
                "version": 1,
            ]
        )
        mergeCookies(from: checkResponse.response)
        let check = try decode(
            CloudUploadCheck.self,
            from: checkResponse.data,
            endpoint: "/api/cloud/upload/check"
        )
        try requireSuccess(check.code?.value, data: checkResponse.data)
        let checkedSongID = try required(check.songId?.value, message: "Missing cloud upload song ID")

        let resourceTokenResponse = try await post(
            path: "/api/nos/token/alloc",
            fields: [
                "bucket": "",
                "ext": ext,
                "filename": normalizedName,
                "local": false,
                "nos_product": 3,
                "type": "audio",
                "md5": values.md5,
            ]
        )
        mergeCookies(from: resourceTokenResponse.response)
        let resourceToken = try decode(
            NosTokenResponse.self,
            from: resourceTokenResponse.data,
            endpoint: "/api/nos/token/alloc (resource)"
        )
        try requireSuccess(resourceToken.code?.value, data: resourceTokenResponse.data)

        if check.needUpload == true {
            let uploadTokenResponse = try await post(
                path: "/api/nos/token/alloc",
                fields: [
                    "bucket": "jd-musicrep-privatecloud-audio-public",
                    "ext": ext,
                    "filename": normalizedName,
                    "local": false,
                    "nos_product": 3,
                    "type": "audio",
                    "md5": values.md5,
                ]
            )
            mergeCookies(from: uploadTokenResponse.response)
            let uploadToken = try decode(
                NosTokenResponse.self,
                from: uploadTokenResponse.data,
                endpoint: "/api/nos/token/alloc (upload)"
            )
            try requireSuccess(uploadToken.code?.value, data: uploadTokenResponse.data)
            try await upload(
                fileURL: fileURL,
                contentLength: values.size,
                fileExtension: ext,
                md5: values.md5,
                token: try required(uploadToken.result?.token, message: "Missing NOS upload token"),
                objectKey: try required(uploadToken.result?.objectKey, message: "Missing NOS object key"),
                progress: progress
            )
        }

        progress(
            TransferProgress(
                completedBytes: values.size,
                totalBytes: values.size,
                stage: .finalizing
            )
        )

        let infoResponse = try await post(
            path: "/api/upload/cloud/info/v2",
            fields: [
                "md5": values.md5,
                "songid": checkedSongID,
                "filename": fileName,
                "song": songName?.isEmpty == false ? songName! : normalizedName,
                "album": album?.isEmpty == false ? album! : "未知专辑",
                "artist": artist?.isEmpty == false ? artist! : "未知艺术家",
                "bitrate": "999000",
                "resourceId": try required(resourceToken.result?.resourceId?.value, message: "Missing NOS resource ID"),
            ]
        )
        mergeCookies(from: infoResponse.response)
        let info = try decode(
            CloudUploadInfo.self,
            from: infoResponse.data,
            endpoint: "/api/upload/cloud/info/v2"
        )
        try requireSuccess(info.code?.value, data: infoResponse.data)

        let publishResponse = try await post(
            path: "/api/cloud/pub/v2",
            fields: ["songid": try required(info.songId?.value, message: "Missing uploaded song ID")]
        )
        mergeCookies(from: publishResponse.response)
        let published = try decode(
            CloudPublishResponse.self,
            from: publishResponse.data,
            endpoint: "/api/cloud/pub/v2"
        )
        try requireSuccess(published.code?.value, data: publishResponse.data)
        return published.privateCloud?.songId.value
    }

    private func post(path: String, fields: [String: Any]) async throws -> (data: Data, response: HTTPURLResponse) {
        guard let url = URL(string: path, relativeTo: Self.apiBaseURL) else {
            throw RequestError.Request("Invalid NetEase API path: \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Self.formEncoded(fields)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        request.setValue(apiCookieHeader(for: path), forHTTPHeaderField: "Cookie")

        let (responseData, urlResponse) = try await session.data(for: request)
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw RequestError.Request("NetEase API returned a non-HTTP response")
        }
        return (responseData, httpResponse)
    }

    private func upload(
        fileURL: URL,
        contentLength: Int64,
        fileExtension: String,
        md5: String,
        token: String,
        objectKey: String,
        progress: @escaping TransferProgressHandler
    ) async throws {
        let lbsURL = URL(string: "https://wanproxy.127.net/lbs?version=1.0&bucketname=jd-musicrep-privatecloud-audio-public")!
        var lbsRequest = URLRequest(url: lbsURL)
        lbsRequest.httpMethod = "GET"
        lbsRequest.httpShouldHandleCookies = false
        let (lbsData, lbsResponse) = try await session.data(for: lbsRequest)
        guard let lbsHTTPResponse = lbsResponse as? HTTPURLResponse else {
            throw RequestError.Request("NOS LBS returned a non-HTTP response")
        }
        guard (200..<300).contains(lbsHTTPResponse.statusCode) else {
            throw RequestError.Request("NOS LBS request failed with HTTP \(lbsHTTPResponse.statusCode)")
        }

        let lbs = try decode(
            NosLbsResponse.self,
            from: lbsData,
            endpoint: "NOS LBS"
        )
        let host = try required(lbs.upload.first, message: "NOS LBS returned no upload host")
        let encodedObjectKey = objectKey.replacingOccurrences(of: "/", with: "%2F")
        guard var uploadComponents = URLComponents(string: host), uploadComponents.host != nil else {
            throw RequestError.Request("NOS returned an invalid upload URL")
        }
        uploadComponents.scheme = "https"
        let basePath = uploadComponents.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        uploadComponents.percentEncodedPath = "/" + [
            basePath,
            "jd-musicrep-privatecloud-audio-public",
            encodedObjectKey,
        ].filter { !$0.isEmpty }.joined(separator: "/")
        uploadComponents.queryItems = [
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "complete", value: "true"),
            URLQueryItem(name: "version", value: "1.0"),
        ]
        guard let uploadURL = uploadComponents.url else {
            throw RequestError.Request("NOS returned an invalid upload URL")
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue(token, forHTTPHeaderField: "x-nos-token")
        request.setValue(md5, forHTTPHeaderField: "Content-MD5")
        request.setValue(
            fileExtension == "flac" ? "audio/flac" : "audio/mpeg",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(String(contentLength), forHTTPHeaderField: "Content-Length")

        progress(
            TransferProgress(
                completedBytes: 0,
                totalBytes: contentLength,
                stage: .transferring
            )
        )
        let delegate = URLSessionTransferProgressDelegate(
            expectedTotalBytes: contentLength,
            progress: progress
        )
        let (_, response) = try await session.upload(for: request, fromFile: fileURL, delegate: delegate)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RequestError.Request("NOS upload returned a non-HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw RequestError.Request("NOS upload failed with HTTP \(httpResponse.statusCode)")
        }
    }

    private func apiCookieHeader(for path: String) -> String {
        var cookies = parsedCookie()
        let now = Date()
        let milliseconds = Int64(now.timeIntervalSince1970 * 1_000)
        let nuid = Self.randomHex(length: 64)

        cookies["__remember_me"] = "true"
        cookies["ntes_kaola_ad"] = "1"
        cookies["_ntes_nuid"] = nuid
        cookies["_ntes_nnid"] = "\(nuid),\(milliseconds)"
        cookies["osver"] = cookies["osver"] ?? Self.defaultOSVersion
        cookies["deviceId"] = cookies["deviceId"] ?? deviceId
        cookies["os"] = cookies["os"] ?? "iPhone OS"
        cookies["channel"] = cookies["channel"] ?? "netease"
        cookies["appver"] = cookies["appver"] ?? Self.defaultAppVersion
        if !path.contains("login") {
            cookies["NMTID"] = Self.randomHex(length: 32)
        }

        var header: [String: String] = [
            "osver": cookies["osver"] ?? Self.defaultOSVersion,
            "deviceId": cookies["deviceId"] ?? deviceId,
            "os": cookies["os"] ?? "iPhone OS",
            "appver": cookies["appver"] ?? Self.defaultAppVersion,
            "versioncode": cookies["versioncode"] ?? "140",
            "mobilename": cookies["mobilename"] ?? "",
            "buildver": cookies["buildver"] ?? String(milliseconds / 1_000),
            "resolution": cookies["resolution"] ?? "1920x1080",
            "__csrf": cookies["__csrf"] ?? "",
            "channel": cookies["channel"] ?? "netease",
            "requestId": "\(milliseconds)_0000",
        ]
        if let musicU = cookies["MUSIC_U"] { header["MUSIC_U"] = musicU }
        if let musicA = cookies["MUSIC_A"] { header["MUSIC_A"] = musicA }

        return header.keys.sorted().map { key in
            "\(Self.percentEncode(key))=\(Self.percentEncode(header[key] ?? ""))"
        }.joined(separator: "; ")
    }

    private func parsedCookie() -> [String: String] {
        guard let cookie = cookie(), !cookie.isEmpty else { return [:] }
        return Self.parseCookie(cookie)
    }

    private func mergeCookies(from response: HTTPURLResponse) {
        var headerFields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            headerFields[key] = value
        }
        let responseCookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: response.url ?? Self.apiBaseURL)
        guard !responseCookies.isEmpty else { return }

        cookieLock.lock()
        var cookies = Self.parseCookie(defaults.string(forKey: CloudMusicApi.SaveCookieName) ?? "")
        for cookie in responseCookies {
            cookies[cookie.name] = cookie.value
        }
        let serialized = cookies.keys.sorted().map { "\($0)=\(cookies[$0] ?? "")" }.joined(separator: "; ")
        defaults.set(serialized, forKey: CloudMusicApi.SaveCookieName)
        cookieLock.unlock()
    }

    private func cacheKey(path: String, fields: [String: Any]) -> String {
        var cacheData = fields
        if let cookie = cookie() {
            cacheData["cookie"] = cookie
        }
        let json = (try? JSONSerialization.data(withJSONObject: cacheData, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return path + json
    }

    private func invalidateCache(path: String, fields: [String: Any]) {
        SharedCacheManager.shared.invalidate(for: cacheKey(path: path, fields: fields))
    }

    private static func playlistDetailFields(id: UInt64) -> [String: Any] {
        ["id": id, "n": 100_000, "s": 8]
    }

    private static func commentResourcePrefix(_ type: Int) throws -> String {
        switch type {
        case 0: return "R_SO_4_"
        case 1: return "R_MV_5_"
        case 2: return "A_PL_0_"
        case 3: return "R_AL_3_"
        case 4: return "A_DJ_1_"
        case 5: return "R_VI_62_"
        case 6: return "A_EV_2_"
        case 7: return "A_DR_14_"
        default: throw RequestError.Request("Unsupported comment resource type")
        }
    }

    private func fileMetadata(at url: URL) throws -> (size: Int64, md5: String) {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize else {
            throw RequestError.Request("cloud failed to read file")
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = Insecure.MD5()
        while true {
            let chunk = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
            if chunk.isEmpty { break }
            hash.update(data: chunk)
        }
        let digest = hash.finalize().map { String(format: "%02hhx", $0) }.joined()
        return (Int64(fileSize), digest)
    }

    private func requireSuccess(_ code: Int?, data: Data) throws {
        guard code == 200 else {
            let error = error(from: data)
            throw RequestError.errorCode((code ?? -1, error ?? "NetEase API request failed"))
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, endpoint: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw RequestError.Request(
                "Failed to decode NetEase response from \(endpoint): \(Self.decodingSummary(error)); "
                    + "shape=\(Self.responseShape(data))"
            )
        }
    }

    private func required<T>(_ value: T?, message: String) throws -> T {
        guard let value else { throw RequestError.Request(message) }
        return value
    }

    private func error(from data: Data) -> String? {
        struct APIError: Decodable {
            let msg: String?
            let message: String?
        }
        let decoded = try? JSONDecoder().decode(APIError.self, from: data)
        return decoded?.msg ?? decoded?.message
    }

    private static func formEncoded(_ fields: [String: Any]) -> Data {
        let form = fields.keys.sorted().map { key in
            "\(percentEncode(key))=\(percentEncode(stringValue(fields[key])))"
        }.joined(separator: "&")
        return Data(form.utf8)
    }

    private static func jsonString(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let string = String(data: data, encoding: .utf8) else {
            throw RequestError.Request("Failed to encode NetEase JSON request data")
        }
        return string
    }

    private static func parseCookie(_ value: String) -> [String: String] {
        var result: [String: String] = [:]
        for item in value.split(separator: ";") {
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            result[pair[0].trimmingCharacters(in: .whitespaces)] =
                pair[1].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    private static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }

    private static func randomHex(length: Int) -> String {
        let alphabet = Array("0123456789ABCDEF")
        return String((0..<length).compactMap { _ in alphabet.randomElement() })
    }

    private static func percentEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func stringValue(_ value: Any?, default fallback: String = "") -> String {
        guard let value else { return fallback }
        if let string = value as? String { return string }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        return String(describing: value)
    }

    private static func md5(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02hhx", $0) }.joined()
    }

    private static func normalizedUploadName(_ fileName: String, ext: String) -> String {
        fileName
            .replacingOccurrences(of: ".\(ext)", with: "", options: [.caseInsensitive])
            .components(separatedBy: .whitespacesAndNewlines).joined()
            .replacingOccurrences(of: ".", with: "_")
    }

    private static func decodingSummary(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        let context: DecodingError.Context
        switch error {
        case .typeMismatch(_, let value), .valueNotFound(_, let value),
            .keyNotFound(_, let value), .dataCorrupted(let value):
            context = value
        @unknown default:
            return error.localizedDescription
        }
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
    }

    private static func responseShape(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return "non-JSON(\(data.count) bytes)"
        }
        return shape(of: object, depth: 0)
    }

    private static func shape(of value: Any, depth: Int) -> String {
        guard depth < 3 else { return "..." }
        if let dictionary = value as? [String: Any] {
            return "{" + dictionary.keys.sorted().map { key in
                "\(key):\(shape(of: dictionary[key] ?? NSNull(), depth: depth + 1))"
            }.joined(separator: ",") + "}"
        }
        if let array = value as? [Any] {
            return "[\(array.first.map { shape(of: $0, depth: depth + 1) } ?? "empty")]"
        }
        switch value {
        case is String: return "string"
        case is NSNumber: return "number"
        case is NSNull: return "null"
        default: return "unknown"
        }
    }
}

private struct FlexibleInt: Decodable {
    let value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self.value = value
        } else if let string = try? container.decode(String.self) {
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Int(normalized) else {
                throw DecodingError.typeMismatch(
                    Int.self,
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: Self.invalidStringDescription(normalized)
                    )
                )
            }
            self.value = value
        } else {
            throw DecodingError.typeMismatch(
                Int.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected an integer or decimal integer string"
                )
            )
        }
    }

    private static func invalidStringDescription(_ value: String) -> String {
        let isDecimal = !value.isEmpty && value.allSatisfy(\.isNumber)
        return "Expected a decimal integer string; length=\(value.count), decimalDigitsOnly=\(isDecimal)"
    }
}

private struct FlexibleUInt64: Decodable {
    let value: UInt64

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(UInt64.self) {
            self.value = value
        } else if let string = try? container.decode(String.self) {
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = UInt64(normalized) else {
                throw DecodingError.typeMismatch(
                    UInt64.self,
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: Self.invalidStringDescription(normalized)
                    )
                )
            }
            self.value = value
        } else {
            throw DecodingError.typeMismatch(
                UInt64.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected an unsigned integer or decimal integer string"
                )
            )
        }
    }

    private static func invalidStringDescription(_ value: String) -> String {
        let isDecimal = !value.isEmpty && value.allSatisfy(\.isNumber)
        return "Expected a decimal unsigned integer string; length=\(value.count), decimalDigitsOnly=\(isDecimal)"
    }
}

private struct FlexibleIdentifier: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self), !string.isEmpty {
            value = string
        } else if let number = try? container.decode(UInt64.self) {
            value = String(number)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected a non-empty string or unsigned integer identifier"
                )
            )
        }
    }
}

private struct CloudUploadCheck: Decodable {
    let code: FlexibleInt?
    let needUpload: Bool?
    let songId: FlexibleIdentifier?
}

private struct NosTokenResponse: Decodable {
    struct Result: Decodable {
        let token: String?
        let objectKey: String?
        let resourceId: FlexibleIdentifier?
    }

    let code: FlexibleInt?
    let result: Result?
}

private struct NosLbsResponse: Decodable {
    let upload: [String]
}

private struct CloudUploadInfo: Decodable {
    let code: FlexibleInt?
    let songId: FlexibleIdentifier?
}

private struct CloudPublishResponse: Decodable {
    struct PrivateCloud: Decodable {
        let songId: FlexibleUInt64
    }

    let code: FlexibleInt?
    let privateCloud: PrivateCloud?
}
