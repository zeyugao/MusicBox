//
//  NeteaseHTTPClient.swift
//  MusicBox
//
//  Native HTTP transport for the subset of NetEase endpoints used by MusicBox.
//

import AVFoundation
import CommonCrypto
import CryptoKit
import Foundation
import Security

final class NeteaseHTTPClient {
    static let shared = NeteaseHTTPClient()

    private static let apiBaseURL = URL(string: "https://interface.music.163.com")!
    private static let eapiBaseURL = URL(string: "https://interfacepc.music.163.com")!
    private static let weapiBaseURL = URL(string: "https://music.163.com")!
    private static let userAgent =
        "NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)"
    private static let webUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.0.0"
    private static let defaultOSVersion = "16.2"
    private static let defaultAppVersion = "9.0.90"
    private static let cloudBucket = "jd-musicrep-privatecloud-audio-public"
    private static let eapiKey = Data("e82ckenh8dichen8".utf8)
    private static let weapiPresetKey = Data("0CoJUm6Qyw8W8jud".utf8)
    private static let weapiIV = Data("0102030405060708".utf8)
    private static let weapiPublicKeyDER = Data(
        base64Encoded:
            "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDgtQn2JZ34ZC28NWYpAUd98iZ37"
            + "BUrX/aKzmFbt7clFSs6sXqHauqKWqdtLkF2KexO40H1YTX8z2lSgBBOAxLsvaklV"
            + "8k4cBFK9snQXE9/DDaFt6Rr7iVZMldczhC0JNgTz+SHXT6CBHuX3e9SdB1Ua44onc"
            + "aTWz7OBGLbCiK45wIDAQAB"
    )!
    private static let cookieMigrationKey = "NeteaseNativeHTTPMigrationCompleted"
    private static let deviceIDKey = "NeteaseNativeHTTPDeviceID"

    private let session: URLSession
    private let defaults: UserDefaults
    private let cookieLock = NSLock()
    private let deviceId: String
    private let weapiSecretKeyGenerator: @Sendable () -> String

    init(
        session: URLSession = NeteaseHTTPClient.makeDefaultSession(),
        defaults: UserDefaults = .standard,
        deviceId: String? = nil,
        weapiSecretKeyGenerator: @escaping @Sendable () -> String = {
            NeteaseHTTPClient.randomBase62(length: 16)
        }
    ) {
        self.session = session
        self.defaults = defaults
        self.weapiSecretKeyGenerator = weapiSecretKeyGenerator
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
        let isAccessingSecurityScopedResource = fileURL.startAccessingSecurityScopedResource()
        defer {
            if isAccessingSecurityScopedResource {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        let values = try await fileMetadata(at: fileURL)
        let tags = await mediaTags(at: fileURL)
        let fileName = fileURL.lastPathComponent
        let ext = fileURL.pathExtension.isEmpty ? "mp3" : fileURL.pathExtension.lowercased()
        let normalizedName = Self.normalizedUploadName(fileName)
        let resolvedSongName = Self.firstNonempty(
            tags.title,
            songName,
            fileURL.deletingPathExtension().lastPathComponent
        )
        let resolvedArtist = Self.firstNonempty(tags.artist, artist, "未知艺术家")
        let resolvedAlbum = Self.firstNonempty(tags.album, album, "未知专辑")
        progress(
            TransferProgress(
                completedBytes: 0,
                totalBytes: values.size,
                stage: .preparing
            )
        )

        let checkResponse = try await postCloudEAPI(
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
        try requireSuccess(
            check.code?.value,
            data: checkResponse.data,
            endpoint: "/api/cloud/upload/check"
        )
        let checkedSongID = try required(check.songId?.value, message: "Missing cloud upload song ID")

        let tokenResponse = try await postCloudWEAPI(
            path: "/api/nos/token/alloc",
            fields: [
                "bucket": Self.cloudBucket,
                "ext": ext,
                "filename": normalizedName,
                "local": false,
                "nos_product": 3,
                "type": "audio",
                "md5": values.md5,
            ]
        )
        mergeCookies(from: tokenResponse.response)
        let uploadToken = try decode(
            NosTokenResponse.self,
            from: tokenResponse.data,
            endpoint: "/api/nos/token/alloc"
        )
        try requireSuccess(
            uploadToken.code?.value,
            data: tokenResponse.data,
            endpoint: "/api/nos/token/alloc"
        )
        let tokenResult = try required(uploadToken.result, message: "Missing NOS upload token result")
        let objectKey = try required(tokenResult.objectKey, message: "Missing NOS object key")
        let resourceID = try required(tokenResult.resourceId?.value, message: "Missing NOS resource ID")
        let uploadURL = try await nosUploadURL(objectKey: objectKey)

        if check.needUpload == true {
            try await upload(
                fileURL: fileURL,
                uploadURL: uploadURL,
                contentLength: values.size,
                fileExtension: ext,
                md5: values.md5,
                token: try required(tokenResult.token, message: "Missing NOS upload token"),
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

        let infoResponse = try await postCloudEAPI(
            path: "/api/upload/cloud/info/v2",
            fields: [
                "md5": values.md5,
                "songid": checkedSongID,
                "filename": fileName,
                "song": resolvedSongName,
                "album": resolvedAlbum,
                "artist": resolvedArtist,
                "bitrate": "999000",
                "resourceId": resourceID,
            ]
        )
        mergeCookies(from: infoResponse.response)
        let info = try decode(
            CloudUploadInfo.self,
            from: infoResponse.data,
            endpoint: "/api/upload/cloud/info/v2"
        )
        try requireSuccess(
            info.code?.value,
            data: infoResponse.data,
            endpoint: "/api/upload/cloud/info/v2"
        )

        let publishResponse = try await postCloudEAPI(
            path: "/api/cloud/pub/v2",
            fields: ["songid": try required(info.songId?.value, message: "Missing uploaded song ID")]
        )
        mergeCookies(from: publishResponse.response)
        let published = try decode(
            CloudPublishResponse.self,
            from: publishResponse.data,
            endpoint: "/api/cloud/pub/v2"
        )
        try requireSuccess(
            published.code?.value,
            data: publishResponse.data,
            endpoint: "/api/cloud/pub/v2"
        )
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

    private func postCloudEAPI(
        path: String,
        fields: [String: Any]
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        guard path.hasPrefix("/api/") else {
            throw RequestError.Request("Invalid NetEase EAPI path: \(path)")
        }
        let endpoint = "/eapi/" + path.dropFirst("/api/".count)
        guard let url = URL(string: endpoint, relativeTo: Self.eapiBaseURL) else {
            throw RequestError.Request("Invalid NetEase EAPI path: \(path)")
        }

        let cookies = cloudCookies(for: path)
        let header = cloudEAPIHeader(from: cookies)
        var payload = fields
        payload["e_r"] = false
        payload["header"] = header

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.httpBody = try Self.makeEAPIForm(path: path, payload: payload)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.cookieHeader(header), forHTTPHeaderField: "Cookie")

        return try await sendCloudRequest(request, transport: "EAPI")
    }

    private func postCloudWEAPI(
        path: String,
        fields: [String: Any]
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        guard path.hasPrefix("/api/") else {
            throw RequestError.Request("Invalid NetEase WEAPI path: \(path)")
        }
        let endpoint = "/weapi/" + path.dropFirst("/api/".count)
        guard let url = URL(string: endpoint, relativeTo: Self.weapiBaseURL) else {
            throw RequestError.Request("Invalid NetEase WEAPI path: \(path)")
        }

        let cookies = cloudCookies(for: path)
        var payload = fields
        payload["e_r"] = false
        payload["csrf_token"] = cookies["__csrf"] ?? ""

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.httpBody = try Self.makeWEAPIForm(
            payload: payload,
            secretKey: weapiSecretKeyGenerator()
        )
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.weapiBaseURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(Self.cookieHeader(cookies), forHTTPHeaderField: "Cookie")

        return try await sendCloudRequest(request, transport: "WEAPI")
    }

    private func sendCloudRequest(
        _ request: URLRequest,
        transport: String
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RequestError.Request("NetEase \(transport) returned a non-HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw RequestError.Request("NetEase \(transport) failed with HTTP \(httpResponse.statusCode)")
        }
        return (data, httpResponse)
    }

    private func upload(
        fileURL: URL,
        uploadURL: URL,
        contentLength: Int64,
        fileExtension: String,
        md5: String,
        token: String,
        progress: @escaping TransferProgressHandler
    ) async throws {
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

    private func nosUploadURL(objectKey: String) async throws -> URL {
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
            Self.cloudBucket,
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
        return uploadURL
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

    private func cloudCookies(for path: String) -> [String: String] {
        var cookies = parsedCookie()
        let milliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
        let nuid = cookies["_ntes_nuid"] ?? Self.randomHex(length: 64).lowercased()

        cookies["__remember_me"] = "true"
        cookies["ntes_kaola_ad"] = "1"
        cookies["_ntes_nuid"] = nuid
        cookies["_ntes_nnid"] = cookies["_ntes_nnid"] ?? "\(nuid),\(milliseconds)"
        cookies["WNMCID"] = cookies["WNMCID"]
            ?? "\(Self.randomLowercaseLetters(length: 6)).\(milliseconds).01.0"
        cookies["WEVNSM"] = cookies["WEVNSM"] ?? "1.0.0"
        cookies["osver"] = cookies["osver"]
            ?? "Microsoft-Windows-10-Professional-build-19045-64bit"
        cookies["deviceId"] = cookies["deviceId"] ?? deviceId
        cookies["os"] = cookies["os"] ?? "pc"
        cookies["channel"] = cookies["channel"] ?? "netease"
        cookies["appver"] = cookies["appver"] ?? "3.1.17.204416"
        if !path.contains("login") {
            cookies["NMTID"] = Self.randomHex(length: 32).lowercased()
        }
        return cookies
    }

    private func cloudEAPIHeader(from cookies: [String: String]) -> [String: String] {
        let milliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
        var header: [String: String] = [
            "osver": cookies["osver"] ?? "Microsoft-Windows-10-Professional-build-19045-64bit",
            "deviceId": cookies["deviceId"] ?? deviceId,
            "os": cookies["os"] ?? "pc",
            "appver": cookies["appver"] ?? "3.1.17.204416",
            "versioncode": cookies["versioncode"] ?? "140",
            "mobilename": cookies["mobilename"] ?? "",
            "buildver": cookies["buildver"] ?? String(milliseconds / 1_000),
            "resolution": cookies["resolution"] ?? "1920x1080",
            "__csrf": cookies["__csrf"] ?? "",
            "channel": cookies["channel"] ?? "netease",
            "requestId": "\(milliseconds)_\(String(format: "%04d", Int.random(in: 0..<1_000)))",
        ]
        if let musicU = cookies["MUSIC_U"] { header["MUSIC_U"] = musicU }
        if let musicA = cookies["MUSIC_A"] { header["MUSIC_A"] = musicA }
        return header
    }

    private static func cookieHeader(_ cookies: [String: String]) -> String {
        cookies.keys.sorted().map { key in
            "\(percentEncode(key))=\(percentEncode(cookies[key] ?? ""))"
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

    private func fileMetadata(at url: URL) async throws -> (size: Int64, md5: String) {
        let task = Task.detached(priority: .userInitiated) {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let fileSize = values.fileSize else {
                throw RequestError.Request("cloud failed to read file")
            }

            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = Insecure.MD5()
            while true {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: 2 * 1_024 * 1_024) ?? Data()
                if chunk.isEmpty { break }
                hash.update(data: chunk)
            }
            let digest = hash.finalize().map { String(format: "%02hhx", $0) }.joined()
            return (Int64(fileSize), digest)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func mediaTags(at url: URL) async -> CloudUploadMediaTags {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.commonMetadata) else {
            return CloudUploadMediaTags()
        }

        var tags = CloudUploadMediaTags()
        for item in metadata {
            guard
                let commonKey = item.commonKey,
                let value = try? await item.load(.stringValue),
                !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }

            switch commonKey {
            case .commonKeyTitle where tags.title == nil:
                tags.title = value
            case .commonKeyArtist where tags.artist == nil:
                tags.artist = value
            case .commonKeyAlbumName where tags.album == nil:
                tags.album = value
            default:
                break
            }
        }
        return tags
    }

    private func requireSuccess(
        _ code: Int?,
        data: Data,
        endpoint: String
    ) throws {
        guard let code, (200..<300).contains(code) else {
            let error = error(from: data)
            throw RequestError.errorCode((
                code ?? -1,
                error ?? "NetEase request failed at \(endpoint)"
            ))
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

    static func makeEAPIForm(path: String, payload: [String: Any]) throws -> Data {
        let requestText = try jsonString(payload)
        let digest = md5("nobody\(path)use\(requestText)md5forencrypt")
        let signedText = "\(path)-36cd479b6b5-\(requestText)-36cd479b6b5-\(digest)"
        let encrypted = try aes(
            Data(signedText.utf8),
            key: eapiKey,
            iv: nil,
            options: CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
            operation: CCOperation(kCCEncrypt),
            transport: "EAPI"
        )
        return formEncoded(["params": hexString(encrypted).uppercased()])
    }

    static func makeWEAPIForm(payload: [String: Any], secretKey: String) throws -> Data {
        let secret = Data(secretKey.utf8)
        guard secret.count == kCCKeySizeAES128 else {
            throw RequestError.Request("WEAPI secret key must be 16 UTF-8 bytes")
        }

        let firstPass = try aes(
            Data(try jsonString(payload).utf8),
            key: weapiPresetKey,
            iv: weapiIV,
            options: CCOptions(kCCOptionPKCS7Padding),
            operation: CCOperation(kCCEncrypt),
            transport: "WEAPI"
        ).base64EncodedString()
        let params = try aes(
            Data(firstPass.utf8),
            key: secret,
            iv: weapiIV,
            options: CCOptions(kCCOptionPKCS7Padding),
            operation: CCOperation(kCCEncrypt),
            transport: "WEAPI"
        ).base64EncodedString()
        let encryptedSecret = try encryptWEAPISecret(secretKey)
        return formEncoded([
            "encSecKey": hexString(encryptedSecret),
            "params": params,
        ])
    }

    private static func aes(
        _ data: Data,
        key: Data,
        iv: Data?,
        options: CCOptions,
        operation: CCOperation,
        transport: String
    ) throws -> Data {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBuffer in
            data.withUnsafeBytes { inputBuffer in
                key.withUnsafeBytes { keyBuffer in
                    if let iv {
                        return iv.withUnsafeBytes { ivBuffer in
                            CCCrypt(
                                operation,
                                CCAlgorithm(kCCAlgorithmAES),
                                options,
                                keyBuffer.baseAddress,
                                key.count,
                                ivBuffer.baseAddress,
                                inputBuffer.baseAddress,
                                data.count,
                                outputBuffer.baseAddress,
                                outputCapacity,
                                &moved
                            )
                        }
                    }
                    return CCCrypt(
                        operation,
                        CCAlgorithm(kCCAlgorithmAES),
                        options,
                        keyBuffer.baseAddress,
                        key.count,
                        nil,
                        inputBuffer.baseAddress,
                        data.count,
                        outputBuffer.baseAddress,
                        outputCapacity,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw RequestError.Request("NetEase \(transport) AES operation failed: \(status)")
        }
        return Data(output.prefix(moved))
    }

    private static func encryptWEAPISecret(_ secretKey: String) throws -> Data {
        let publicKeyData = Data(weapiPublicKeyDER.dropFirst(22))
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 1_024,
        ]
        var keyError: Unmanaged<CFError>?
        guard let publicKey = SecKeyCreateWithData(
            publicKeyData as CFData,
            attributes as CFDictionary,
            &keyError
        ) else {
            let message = keyError?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw RequestError.Request("Failed to create WEAPI RSA public key: \(message)")
        }

        let reversed = Data(secretKey.reversed().map { UInt8(String($0).utf8.first!) })
        let blockSize = SecKeyGetBlockSize(publicKey)
        guard reversed.count <= blockSize else {
            throw RequestError.Request("WEAPI RSA plaintext is too large")
        }
        var padded = Data(repeating: 0, count: blockSize - reversed.count)
        padded.append(reversed)

        var encryptionError: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(
            publicKey,
            .rsaEncryptionRaw,
            padded as CFData,
            &encryptionError
        ) else {
            let message = encryptionError?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw RequestError.Request("WEAPI RSA encryption failed: \(message)")
        }
        return encrypted as Data
    }

    private static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
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

    private static func randomBase62(length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<length).compactMap { _ in alphabet.randomElement() })
    }

    private static func randomLowercaseLetters(length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
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

    static func normalizedUploadName(_ fileName: String) -> String {
        URL(fileURLWithPath: fileName)
            .deletingPathExtension()
            .lastPathComponent
            .components(separatedBy: .whitespacesAndNewlines).joined()
            .replacingOccurrences(of: ".", with: "_")
    }

    static func firstNonempty(_ values: String?...) -> String {
        values.lazy.compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.first ?? ""
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

private struct CloudUploadMediaTags {
    var title: String?
    var artist: String?
    var album: String?
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
