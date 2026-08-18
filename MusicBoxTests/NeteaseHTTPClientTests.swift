import AVFoundation
import CommonCrypto
import CryptoKit
import Foundation
import XCTest

@testable import MusicBox

final class NeteaseHTTPClientTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "NeteaseHTTPClientTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        MockURLProtocol.reset()
        SharedCacheManager.shared.clear()
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        MockURLProtocol.reset()
        try super.tearDownWithError()
    }

    func testSongDetailUsesRawFormRequestAndCache() async throws {
        let client = makeClient()
        MockURLProtocol.configure { request in
            XCTAssertEqual(request.url?.host, "interface.music.163.com")
            XCTAssertEqual(request.url?.path, "/api/v3/song/detail")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "User-Agent"),
                "NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")

            let form = try formFields(from: request)
            let songs = try XCTUnwrap(form["c"])
            let payload = try XCTUnwrap(songs.data(using: .utf8))
            let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [[String: UInt64]])
            XCTAssertEqual(decoded, [["id": 1], ["id": 2]])
            XCTAssertNil(form["params"])
            XCTAssertNil(form["encSecKey"])

            return (response(for: request), Data(#"{"code":200,"songs":[]}"#.utf8))
        }

        let first = try await client.songDetail(ids: [1, 2], cacheTtl: 60)
        let second = try await client.songDetail(ids: [1, 2], cacheTtl: 60)

        XCTAssertEqual(first, second)
        XCTAssertEqual(MockURLProtocol.requests().count, 1)
    }

    func testUserPlaylistThrowsForErrorPayload() async throws {
        let api = CloudMusicApi(client: makeClient())
        MockURLProtocol.configure { request in
            XCTAssertEqual(request.url?.path, "/api/user/playlist")
            return (response(for: request), Data(#"{"code":301}"#.utf8))
        }

        do {
            _ = try await api.user_playlist(uid: 42)
            XCTFail("Expected an error payload to throw")
        } catch {}
    }

    func testCellphoneLoginHashesPasswordAndMergesResponseCookie() async throws {
        let client = makeClient()
        let api = CloudMusicApi(client: client)
        client.setCookie("MUSIC_U=old; __csrf=csrf")

        MockURLProtocol.configure { request in
            XCTAssertEqual(request.url?.path, "/api/w/login/cellphone")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("MUSIC_U=old") == true)

            let form = try formFields(from: request)
            XCTAssertEqual(form["phone"], "13800138000")
            XCTAssertEqual(form["countrycode"], "86")
            XCTAssertEqual(form["password"], md5("secret"))
            XCTAssertEqual(form["rememberLogin"], "true")

            return (
                response(for: request, headers: ["Set-Cookie": "MUSIC_U=updated; Path=/; HttpOnly"]),
                Data(#"{"code":200}"#.utf8)
            )
        }

        let result = await api.login_cellphone(
            phone: "13800138000",
            countrycode: 86,
            password: "secret"
        )

        XCTAssertNil(result)
        XCTAssertTrue(client.cookie()?.contains("MUSIC_U=updated") == true)
        XCTAssertTrue(client.cookie()?.contains("__csrf=csrf") == true)
        client.clearCookie()
        XCTAssertNil(client.cookie())
    }

    func testQRCodeKeyAndPollingRoutes() async throws {
        let client = makeClient()
        let api = CloudMusicApi(client: client)

        MockURLProtocol.configure { request in
            let form = try formFields(from: request)
            switch request.url?.path {
            case "/api/login/qrcode/unikey":
                XCTAssertEqual(form["type"], "3")
                return (response(for: request), Data(#"{"code":200,"unikey":"qr-key"}"#.utf8))
            case "/api/login/qrcode/client/login":
                XCTAssertEqual(form["key"], "qr-key")
                XCTAssertEqual(form["type"], "3")
                return (
                    response(for: request),
                    Data(#"{"code":803,"message":"confirmed","cookie":"MUSIC_U=qr-session"}"#.utf8)
                )
            default:
                throw TestError.unexpectedRequest(request.url?.absoluteString ?? "missing URL")
            }
        }

        let key = try await api.login_qr_key()
        XCTAssertEqual(key, "qr-key")
        let generated = client.loginQRCodeURL(key: key)
        let result = try await api.login_qr_check(key: key)

        XCTAssertEqual(generated, "https://music.163.com/login?codekey=qr-key")
        XCTAssertEqual(result.code, 803)
        XCTAssertTrue(client.cookie()?.contains("MUSIC_U=qr-session") == true)
        XCTAssertEqual(MockURLProtocol.requests().map { $0.url?.path }, [
            "/api/login/qrcode/unikey",
            "/api/login/qrcode/client/login",
        ])
    }

    func testCacheInvalidationForcesANewRequest() async throws {
        let client = makeClient()
        let playlistID: UInt64 = 42

        MockURLProtocol.configure { request in
            XCTAssertEqual(request.url?.path, "/api/v6/playlist/detail")
            return (response(for: request), Data(#"{"code":200,"playlist":{"tracks":[],"trackIds":[]}}"#.utf8))
        }

        _ = try await client.playlistDetail(id: playlistID, cacheTtl: 60)
        client.invalidatePlaylistDetail(id: playlistID)
        _ = try await client.playlistDetail(id: playlistID, cacheTtl: 60)

        XCTAssertEqual(MockURLProtocol.requests().count, 2)
    }

    func testFacadeMapsServerErrorAndInvalidatesCachedResponse() async throws {
        let client = makeClient()
        let api = CloudMusicApi(cacheTtl: 60, client: client)

        MockURLProtocol.configure { request in
            XCTAssertEqual(request.url?.path, "/api/login/token/refresh")
            return (response(for: request), Data(#"{"code":-462,"message":"verification required"}"#.utf8))
        }

        for _ in 0..<2 {
            do {
                try await api.login_refresh()
                XCTFail("Expected a server error")
            } catch let error as RequestError {
                guard case let .errorCode((code, message)) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(code, -462)
                XCTAssertEqual(message, "绑定手机号或短信验证成功后，可进行下一步操作哦~🙃")
            }
        }

        XCTAssertEqual(MockURLProtocol.requests().count, 2)
    }

    func testCloudEAPIEncoderSignsAndEncryptsPayload() throws {
        let payload: [String: Any] = [
            "e_r": false,
            "header": ["MUSIC_U": "session", "os": "pc"],
            "md5": "abc",
        ]
        var request = URLRequest(url: URL(string: "https://example.test/eapi/cloud/upload/check")!)
        request.httpBody = try NeteaseHTTPClient.makeEAPIForm(
            path: "/api/cloud/upload/check",
            payload: payload
        )

        let decoded = try decodeEAPIRequest(request)
        XCTAssertEqual(decoded.path, "/api/cloud/upload/check")
        XCTAssertEqual(decoded.payload["md5"] as? String, "abc")
        XCTAssertEqual(decoded.payload["e_r"] as? Bool, false)
        XCTAssertEqual(
            decoded.digest,
            md5("nobody\(decoded.path)use\(decoded.requestJSON)md5forencrypt")
        )
    }

    func testCloudWEAPIEncoderUsesReferenceDoubleAESAndRawRSA() throws {
        let secretKey = "abcdefghijklmnop"
        let payload: [String: Any] = [
            "csrf_token": "csrf",
            "e_r": false,
            "filename": "song.mp3",
            "md5": "abc",
        ]
        let body = try NeteaseHTTPClient.makeWEAPIForm(payload: payload, secretKey: secretKey)
        let decoded = try decodeWEAPIPayload(body, secretKey: secretKey)

        XCTAssertEqual(decoded["csrf_token"] as? String, "csrf")
        XCTAssertEqual(decoded["e_r"] as? Bool, false)
        XCTAssertEqual(decoded["filename"] as? String, "song.mp3")
        XCTAssertEqual(decoded["md5"] as? String, "abc")

        var request = URLRequest(url: URL(string: "https://example.test/weapi/nos/token/alloc")!)
        request.httpBody = body
        let form = try formFields(from: request)
        XCTAssertEqual(form["encSecKey"]?.count, 256)
        XCTAssertTrue(form["encSecKey"]?.allSatisfy(\.isHexDigit) == true)
        XCTAssertEqual(
            body,
            try NeteaseHTTPClient.makeWEAPIForm(payload: payload, secretKey: secretKey)
        )
    }

    func testCloudUploadMetadataFallbacksAndFilenameNormalization() {
        XCTAssertEqual(
            NeteaseHTTPClient.firstNonempty("  Tagged title  ", "Playlist title", "Filename"),
            "Tagged title"
        )
        XCTAssertEqual(
            NeteaseHTTPClient.firstNonempty("  ", " Playlist title ", "Filename"),
            "Playlist title"
        )
        XCTAssertEqual(
            NeteaseHTTPClient.normalizedUploadName("My Song.live.mix.FLAC"),
            "MySong_live_mix"
        )
    }

    func testCloudUploadAcceptsCheck201AndSkipsNosWhenServerAlreadyHasFile() async throws {
        let client = makeClient()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicBox-cloud-test-\(UUID().uuidString).mp3")
        let fileData = Data("cloud test audio".utf8)
        try fileData.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        MockURLProtocol.configure { request in
            switch (request.url?.host, request.url?.path) {
            case ("interfacepc.music.163.com", "/eapi/cloud/upload/check"):
                let decoded = try decodeEAPIRequest(request)
                XCTAssertEqual(decoded.path, "/api/cloud/upload/check")
                XCTAssertEqual(decoded.payload["length"] as? Int, fileData.count)
                XCTAssertEqual(decoded.payload["md5"] as? String, md5(fileData))
                return (response(for: request), Data(#"{"code":201,"needUpload":false,"songId":42}"#.utf8))
            case ("music.163.com", "/weapi/nos/token/alloc"):
                let payload = try decodeWEAPIPayload(
                    requestBody(from: request),
                    secretKey: "abcdefghijklmnop"
                )
                XCTAssertEqual(payload["bucket"] as? String, "jd-musicrep-privatecloud-audio-public")
                XCTAssertEqual(payload["ext"] as? String, "mp3")
                XCTAssertEqual(
                    payload["filename"] as? String,
                    NeteaseHTTPClient.normalizedUploadName(fileURL.lastPathComponent)
                )
                XCTAssertEqual(payload["md5"] as? String, md5(fileData))
                XCTAssertEqual(payload["type"] as? String, "audio")
                XCTAssertEqual(payload["nos_product"] as? Int, 3)
                return (
                    response(for: request),
                    Data(#"{"code":200,"result":{"token":"nos-token","objectKey":"folder/object.mp3","resourceId":7}}"#.utf8)
                )
            case ("wanproxy.127.net", "/lbs"):
                return (response(for: request), Data(#"{"upload":["http://upload.example.test"]}"#.utf8))
            case ("interfacepc.music.163.com", "/eapi/upload/cloud/info/v2"):
                let decoded = try decodeEAPIRequest(request)
                XCTAssertEqual(decoded.payload["songid"] as? String, "42")
                XCTAssertEqual(decoded.payload["resourceId"] as? String, "7")
                return (response(for: request), Data(#"{"code":200,"songId":42}"#.utf8))
            case ("interfacepc.music.163.com", "/eapi/cloud/pub/v2"):
                return (response(for: request), Data(#"{"code":200,"privateCloud":{"songId":42}}"#.utf8))
            default:
                throw TestError.unexpectedRequest(request.url?.absoluteString ?? "missing URL")
            }
        }

        let songID = try await client.uploadCloudFile(
            fileURL: fileURL,
            songName: "Song",
            artist: "Artist",
            album: "Album"
        )

        XCTAssertEqual(songID, 42)
        XCTAssertEqual(MockURLProtocol.requests().map { $0.url?.path }, [
            "/eapi/cloud/upload/check",
            "/weapi/nos/token/alloc",
            "/lbs",
            "/eapi/upload/cloud/info/v2",
            "/eapi/cloud/pub/v2",
        ])
    }

    func testCloudUploadStreamsFileThroughNos() async throws {
        let client = makeClient()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicBox-cloud-upload-\(UUID().uuidString).flac")
        let fileData = Data("cloud upload audio body".utf8)
        try fileData.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let initialAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let initialModificationDate = initialAttributes[.modificationDate] as? Date
        let progressRecorder = TransferProgressRecorder()
        let checkedSongID = String(repeating: "a", count: 128)

        MockURLProtocol.configure { request in
            switch (request.url?.host, request.url?.path) {
            case ("interfacepc.music.163.com", "/eapi/cloud/upload/check"):
                let decoded = try decodeEAPIRequest(request)
                XCTAssertEqual(decoded.path, "/api/cloud/upload/check")
                return (
                    response(for: request),
                    Data("{\"code\":\"200\",\"needUpload\":true,\"songId\":\"\(checkedSongID)\"}".utf8)
                )
            case ("music.163.com", "/weapi/nos/token/alloc"):
                let payload = try decodeWEAPIPayload(
                    requestBody(from: request),
                    secretKey: "abcdefghijklmnop"
                )
                XCTAssertEqual(payload["bucket"] as? String, "jd-musicrep-privatecloud-audio-public")
                XCTAssertEqual(payload["ext"] as? String, "flac")
                XCTAssertEqual(
                    payload["filename"] as? String,
                    NeteaseHTTPClient.normalizedUploadName(fileURL.lastPathComponent)
                )
                XCTAssertEqual(payload["md5"] as? String, md5(fileData))
                XCTAssertEqual(payload["type"] as? String, "audio")
                XCTAssertEqual(payload["nos_product"] as? Int, 3)
                return (
                    response(for: request),
                    Data(#"{"code":"200","result":{"token":"nos-token","objectKey":"folder/object.flac","resourceId":"7"}}"#.utf8)
                )
            case ("wanproxy.127.net", "/lbs"):
                return (response(for: request), Data(#"{"upload":["http://upload.example.test"]}"#.utf8))
            case ("upload.example.test", _):
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.url?.scheme, "https")
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-nos-token"), "nos-token")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-MD5"), md5(fileData))
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/flac")
                XCTAssertTrue(request.url?.absoluteString.contains("folder%2Fobject.flac") == true)
                XCTAssertEqual(try requestBody(from: request), fileData)
                return (response(for: request), Data())
            case ("interfacepc.music.163.com", "/eapi/upload/cloud/info/v2"):
                let decoded = try decodeEAPIRequest(request)
                XCTAssertEqual(decoded.payload["songid"] as? String, checkedSongID)
                XCTAssertEqual(decoded.payload["resourceId"] as? String, "7")
                return (response(for: request), Data(#"{"code":"200","songId":"42"}"#.utf8))
            case ("interfacepc.music.163.com", "/eapi/cloud/pub/v2"):
                return (response(for: request), Data(#"{"code":"200","privateCloud":{"songId":"42"}}"#.utf8))
            default:
                throw TestError.unexpectedRequest(request.url?.absoluteString ?? "missing URL")
            }
        }

        let songID = try await client.uploadCloudFile(
            fileURL: fileURL,
            songName: nil,
            artist: nil,
            album: nil,
            progress: { progressRecorder.record($0) }
        )

        XCTAssertEqual(songID, 42)
        XCTAssertEqual(MockURLProtocol.requests().count, 6)
        let progress = progressRecorder.snapshot()
        XCTAssertEqual(progress.first?.stage, .preparing)
        XCTAssertTrue(progress.contains { $0.stage == .transferring })
        XCTAssertEqual(progress.last?.stage, .finalizing)
        XCTAssertEqual(progress.last?.fraction, 1)
        XCTAssertEqual(try Data(contentsOf: fileURL), fileData)
        let finalAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual(finalAttributes[.size] as? NSNumber, initialAttributes[.size] as? NSNumber)
        XCTAssertEqual(finalAttributes[.modificationDate] as? Date, initialModificationDate)
    }

    func testCloudUploadDecodeErrorNamesEndpointAndOnlyReportsShape() async throws {
        let client = makeClient()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicBox-cloud-invalid-\(UUID().uuidString).flac")
        try Data("audio".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        MockURLProtocol.configure { request in
            XCTAssertEqual(request.url?.host, "interfacepc.music.163.com")
            XCTAssertEqual(request.url?.path, "/eapi/cloud/upload/check")
            return (
                response(for: request),
                Data(#"{"code":200,"needUpload":true,"songId":{"secret":"do-not-echo"}}"#.utf8)
            )
        }

        do {
            _ = try await client.uploadCloudFile(
                fileURL: fileURL,
                songName: nil,
                artist: nil,
                album: nil
            )
            XCTFail("Expected decoding to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("/api/cloud/upload/check"))
            XCTAssertTrue(error.localizedDescription.contains("songId"))
            XCTAssertTrue(error.localizedDescription.contains("shape="))
            XCTAssertFalse(error.localizedDescription.contains("do-not-echo"))
        }
    }

    func testUploadProgressDelegateReportsBytes() {
        let recorder = TransferProgressRecorder()
        let session = URLSession(configuration: .ephemeral)
        let request = URLRequest(url: URL(string: "https://example.test/file")!)

        let uploadDelegate = URLSessionTransferProgressDelegate(
            expectedTotalBytes: 100,
            progress: { recorder.record($0) }
        )
        let uploadTask = session.uploadTask(with: request, from: Data())
        uploadDelegate.urlSession(
            session,
            task: uploadTask,
            didSendBodyData: 40,
            totalBytesSent: 40,
            totalBytesExpectedToSend: 100
        )

        XCTAssertEqual(recorder.snapshot().map(\.fraction), [0.4])
    }

    @MainActor
    func testAudioResolverDownloadsWithByteProgressAndStoresCompleteFile() async throws {
        let fileData = Data(repeating: 0x5A, count: 16_384)
        let songID = UInt64.max - 10_000
        let repository = AudioResourceRepository(
            data: CloudMusicApi.SongData(
                br: 999_000,
                encodeType: "flac",
                id: songID,
                level: "lossless",
                size: UInt64(fileData.count),
                time: 1_000,
                type: "flac",
                url: "https://audio.example.test/song.flac"
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let resolver = AudioSourceResolver(
            repository: repository,
            session: URLSession(configuration: configuration)
        )
        let destination = try XCTUnwrap(MusicLibraryCache.destination(for: songID, fileExtension: "flac"))
        defer { try? FileManager.default.removeItem(at: destination) }
        let recorder = TransferProgressRecorder()

        MockURLProtocol.configure { request in
            XCTAssertEqual(request.url?.host, "audio.example.test")
            return (
                response(for: request, headers: ["Content-Length": String(fileData.count)]),
                fileData
            )
        }

        let result = try await resolver.download(
            PlaylistItem(
                id: songID,
                url: nil,
                title: "Download Test",
                artist: "Artist",
                albumId: 0,
                ext: "flac",
                duration: .zero,
                artworkUrl: nil,
                nsSong: nil
            ),
            progress: { recorder.record($0) }
        )

        XCTAssertEqual(result, destination)
        XCTAssertEqual(try Data(contentsOf: destination), fileData)
        let progressValues = recorder.snapshot()
        XCTAssertEqual(progressValues.first?.stage, .preparing)
        XCTAssertTrue(
            progressValues.contains {
                $0.stage == .transferring && ($0.fraction ?? 0) > 0 && ($0.fraction ?? 1) < 1
            }
        )
        XCTAssertEqual(progressValues.last?.stage, .finalizing)
        XCTAssertEqual(progressValues.last?.fraction, 1)
    }

    func testMigrationClearsLegacyAccountStateOnlyOnce() {
        defaults.set("legacy-cookie", forKey: CloudMusicApi.SaveCookieName)
        defaults.set(Data("profile".utf8), forKey: "profile")
        defaults.set(Data("playlists".utf8), forKey: "playlists")
        defaults.set(Data("likelist".utf8), forKey: "likelist")

        NeteaseHTTPClient.migrateLegacyAuthenticationIfNeeded(defaults: defaults)

        XCTAssertNil(defaults.string(forKey: CloudMusicApi.SaveCookieName))
        XCTAssertNil(defaults.object(forKey: "profile"))
        XCTAssertNil(defaults.object(forKey: "playlists"))
        XCTAssertNil(defaults.object(forKey: "likelist"))

        defaults.set("native-cookie", forKey: CloudMusicApi.SaveCookieName)
        NeteaseHTTPClient.migrateLegacyAuthenticationIfNeeded(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: CloudMusicApi.SaveCookieName), "native-cookie")
    }

    func testRelayConfigUsesEncryptedDesktopEAPI() async throws {
        let client = makePlaybackClient()
        MockURLProtocol.configure { request in
            XCTAssertEqual(request.url?.host, "interface.music.163.com")
            XCTAssertEqual(request.url?.path, "/eapi/relay/config/get")
            XCTAssertEqual(request.url?.query, "_nmclfl=1")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(
                request.value(forHTTPHeaderField: "User-Agent")?
                    .hasPrefix("NeteaseMusic/3368 CFNetwork/3896.100.1.1.1 Darwin/") == true
            )
            XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("MUSIC_U=playback-token") == true)
            XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("clientSign=0123456789ABCDEF0123456789ABCDEF") == true)

            let decoded = try decodeEAPIRequest(request)
            XCTAssertEqual(decoded.path, "/api/relay/config/get")
            XCTAssertEqual(decoded.payload["deviceId"] as? String, "00112233445566778899aabbccddeeff")
            XCTAssertEqual(decoded.payload["os"] as? String, "OSX")
            XCTAssertEqual(decoded.payload["verifyId"] as? Int, 1)
            XCTAssertEqual(decoded.payload["e_r"] as? Bool, true)
            let headerText = try XCTUnwrap(decoded.payload["header"] as? String)
            let header = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(headerText.utf8)) as? [String: Any])
            XCTAssertEqual(header["clientSign"] as? String, "0123456789ABCDEF0123456789ABCDEF")
            XCTAssertEqual(header["deviceId"] as? String, "HEADER%7CDEVICE")
            XCTAssertEqual(header["appver"] as? String, "3.1.8")
            XCTAssertEqual(header["requestId"] as? Int, 0)
            XCTAssertEqual(decoded.digest, md5("nobody\(decoded.path)use\(decoded.requestJSON)md5forencrypt"))

            return (
                response(for: request),
                try encryptedEAPIResponse(#"{"code":200,"data":{"enable":true,"snapshotSize":6,"radioProgressInterval":30}}"#)
            )
        }

        let config = try await client.relayConfig()

        XCTAssertEqual(config, RelayConfig(enabled: true, snapshotSize: 6, radioProgressInterval: 30))
    }

    func testRelaySettingsUseDedicatedEndpoints() async throws {
        let client = makePlaybackClient()
        MockURLProtocol.configure { request in
            let decoded = try decodeEAPIRequest(request)
            switch request.url?.path {
            case "/eapi/relay/setting/show":
                XCTAssertEqual(decoded.path, "/api/relay/setting/show")
                XCTAssertEqual(decoded.payload["all"] as? Bool, false)
                XCTAssertEqual(decoded.payload["settingKey"] as? String, "RELAY_SWITCH")
                return (response(for: request), try encryptedEAPIResponse(#"{"code":200,"data":true}"#))
            case "/eapi/relay/setting/update":
                XCTAssertEqual(decoded.path, "/api/relay/setting/update")
                XCTAssertEqual(decoded.payload["settingKey"] as? String, "RELAY_SWITCH")
                XCTAssertEqual(decoded.payload["targetDeviceId"] as? String, "00112233445566778899aabbccddeeff")
                XCTAssertEqual(decoded.payload["enable"] as? Bool, false)
                return (response(for: request), try encryptedEAPIResponse(#"{"code":200}"#))
            default:
                throw TestError.unexpectedRequest(request.url?.absoluteString ?? "missing URL")
            }
        }

        let relayEnabled = try await client.relaySetting()
        XCTAssertTrue(relayEnabled)
        try await client.updateRelaySetting(enabled: false)
        XCTAssertEqual(MockURLProtocol.requests().map { $0.url?.path }, [
            "/eapi/relay/setting/show",
            "/eapi/relay/setting/update",
        ])
    }

    func testRelaySubmissionsWrapJSONStrings() async throws {
        let client = makePlaybackClient()
        let songList = RelaySongListRequest(
            retransmit: false,
            sessionID: "ABC123DEF456",
            initialResourceID: "2",
            playMode: "random",
            sourceType: nil,
            sourceID: nil,
            resources: [RelayResource(id: "1"), RelayResource(id: "2")]
        )
        let state = RelayPlayStateRequest(
            resource: RelayResource(id: "2"),
            progress: 0,
            sessionID: "ABC123DEF456",
            playMode: "random"
        )

        MockURLProtocol.configure { request in
            let decoded = try decodeEAPIRequest(request)
            switch request.url?.path {
            case "/eapi/relay/songlist/submit":
                let encoded = try XCTUnwrap(decoded.payload["songListSubmitReq"] as? String)
                let value = try JSONDecoder().decode(RelaySongListRequest.self, from: Data(encoded.utf8))
                XCTAssertEqual(value, songList)
                return (response(for: request), try encryptedEAPIResponse(#"{"code":200}"#))
            case "/eapi/relay/play/state/submit":
                let encoded = try XCTUnwrap(decoded.payload["playStateSubmitReq"] as? String)
                let value = try JSONDecoder().decode(RelayPlayStateRequest.self, from: Data(encoded.utf8))
                XCTAssertEqual(value, state)
                return (response(for: request), try encryptedEAPIResponse(#"{"code":200}"#))
            default:
                throw TestError.unexpectedRequest(request.url?.absoluteString ?? "missing URL")
            }
        }

        let songListCode = try await client.submitRelaySongList(songList)
        let playStateCode = try await client.submitRelayPlayState(state)
        XCTAssertEqual(songListCode, 200)
        XCTAssertEqual(playStateCode, 200)
    }

    func testHandoffOfferAndPullKeepTheGeneralizedObject() async throws {
        let client = makePlaybackClient()
        MockURLProtocol.configure { request in
            let decoded = try decodeEAPIRequest(request)
            switch request.url?.path {
            case "/eapi/link/position/show/resource":
                XCTAssertEqual(decoded.path, "/api/link/position/show/resource")
                XCTAssertEqual(decoded.payload["positionCode"] as? String, "multi_terminal_reconnect_info")
                let extJSON = try XCTUnwrap(decoded.payload["extJson"] as? [String: Any])
                let states = try XCTUnwrap(extJSON["states"] as? [String: Any])
                let relayInfo = try XCTUnwrap(states["relayInfo"] as? [String: String])
                XCTAssertEqual(relayInfo["current"], #"{"needCheck":true}"#)
                return (
                    response(for: request),
                    try encryptedEAPIResponse(
                        #"{"code":200,"data":{"commonResourceList":[{"generalizedObject":{"deviceId":"remote-device","reconnectTitle":"Other Mac","resourceId":"2"}}]}}"#
                    )
                )
            case "/eapi/relay/play/pull":
                XCTAssertEqual(decoded.path, "/api/relay/play/pull")
                XCTAssertEqual(decoded.payload["deviceId"] as? String, "00112233445566778899aabbccddeeff")
                XCTAssertEqual(decoded.payload["targetDeviceId"] as? String, "remote-device")
                XCTAssertEqual(decoded.payload["reconnectTitle"] as? String, "Other Mac")
                return (
                    response(for: request),
                    try encryptedEAPIResponse(
                        #"{"code":200,"data":{"sourceType":"playlist","sourceId":"99","resources":[{"id":"1","type":"song"},{"id":"2","type":"song"}],"currentPlayState":{"resourceId":"2","resourceType":"song","progress":12345},"playMode":"list_loop"}}"#
                    )
                )
            default:
                throw TestError.unexpectedRequest(request.url?.absoluteString ?? "missing URL")
            }
        }

        let receivedOffer = try await client.handoffOffer()
        let offer = try XCTUnwrap(receivedOffer)
        XCTAssertEqual(offer.deviceID, "remote-device")
        let pulled = try await client.pullRelayPlay(offer: offer)

        XCTAssertEqual(pulled.sourceID, "99")
        XCTAssertEqual(pulled.resources, [RelayResource(id: "1"), RelayResource(id: "2")])
        XCTAssertEqual(pulled.currentResourceID, "2")
        XCTAssertEqual(pulled.progressMilliseconds, 12_345)
    }

    func testDawnUploadUsesNCBLMonitorAttach() async throws {
        let client = makePlaybackClient()
        let event = DawnEvent(
            id: UUID(uuidString: "1AAE490D-A868-4F1E-9CF8-3A8CFC41E836")!,
            action: "_plv",
            timestamp: 1_700_000_000,
            payload: ["id": .string("42"), "type": .string("song")]
        )

        MockURLProtocol.configure { request in
            XCTAssertEqual(request.url?.host, "clientlog3.music.163.com")
            XCTAssertEqual(request.url?.path, "/api/clientlog/encrypt/upload")
            XCTAssertEqual(request.url?.query, "multiupload=true")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.contains("multipart/form-data") == true)

            let body = try requestBody(from: request)
            let text = try XCTUnwrap(String(data: body, encoding: .isoLatin1))
            XCTAssertTrue(text.contains("name=\"attach\""))
            XCTAssertTrue(text.contains("filename=\"monitor_"))
            XCTAssertTrue(text.contains("_7_"))
            XCTAssertFalse(text.contains("name=\"MUSIC_U\""))

            let magic = Data([0x4E, 0x43, 0x42, 0x4C])
            let start = try XCTUnwrap(body.range(of: magic)?.lowerBound)
            let blob = body.subdata(in: start..<body.count)
            XCTAssertEqual(blob.prefix(4), magic)
            XCTAssertEqual(readLittleEndianUInt32(blob, offset: 4), 3)
            let headerLength = Int(readLittleEndianUInt16(blob, offset: 8))
            XCTAssertGreaterThanOrEqual(headerLength, 70)
            XCTAssertEqual(readLittleEndianUInt32(blob, offset: 58), 7)
            XCTAssertEqual(readLittleEndianUInt32(blob, offset: 62), 7)
            XCTAssertEqual(readLittleEndianUInt32(blob, offset: headerLength + 2), 7)
            XCTAssertNotEqual(blob.subdata(in: 26..<58), Data(repeating: 0, count: 32))
            return (response(for: request), Data(#"{"code":200,"data":{"successfiles":[]}}"#.utf8))
        }

        try await client.uploadDawn(events: [event], sequence: 7)
    }

    func testDawnChaCha20MatchesRFC8439BlockVector() {
        let key = dataFromHex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        let nonce = dataFromHex("000000090000004a00000000")
        let output = DawnLogEncoder.chacha20XOR(
            Data(repeating: 0, count: 64), key: key, nonce: nonce, counter: 1
        )
        XCTAssertEqual(
            output.hexEncoded,
            "10f1e7e4d13b5915500fdd1fa32071c4c7d1f4c733c068030422aa9ac3d46c4e"
                + "d2826446079faa0914c2d705d98b02a2b5129cd1de164eb9cbd083e8a2503c4e"
        )
    }

    func testDawnRawZstdFrameHasAStableStandardHeader() {
        let frame = DawnLogEncoder.zstdRawFrame(Data("hello".utf8))
        XCTAssertEqual(frame.hexEncoded, "28b52ffda00500000029000068656c6c6f")
    }

    @MainActor
    func testPlaybackCoordinatorRetransmitsSnapshotAfterRelay10001() async throws {
        let client = makePlaybackClient()
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicBox-playback-reports-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let recorder = RelaySubmissionRecorder()
        let stateSubmitted = expectation(description: "relay state submitted after retransmit")
        MockURLProtocol.configure { request in
            switch request.url?.path {
            case "/eapi/relay/config/get":
                return (
                    response(for: request),
                    try encryptedEAPIResponse(#"{"code":200,"data":{"enable":true,"snapshotSize":3,"radioProgressInterval":30}}"#)
                )
            case "/eapi/relay/setting/show":
                return (response(for: request), try encryptedEAPIResponse(#"{"code":200,"data":true}"#))
            case "/eapi/link/position/show/resource":
                return (
                    response(for: request),
                    try encryptedEAPIResponse(#"{"code":200,"data":{"commonResourceList":[]}}"#)
                )
            case "/eapi/relay/songlist/submit":
                let decoded = try decodeEAPIRequest(request)
                let text = try XCTUnwrap(decoded.payload["songListSubmitReq"] as? String)
                let submission = try JSONDecoder().decode(RelaySongListRequest.self, from: Data(text.utf8))
                let submissionCount = recorder.append(songList: submission)
                let code = submissionCount == 1 ? 10001 : 200
                return (response(for: request), try encryptedEAPIResponse("{\"code\":\(code)}"))
            case "/eapi/relay/play/state/submit":
                let decoded = try decodeEAPIRequest(request)
                let text = try XCTUnwrap(decoded.payload["playStateSubmitReq"] as? String)
                let submission = try JSONDecoder().decode(RelayPlayStateRequest.self, from: Data(text.utf8))
                recorder.append(playState: submission)
                stateSubmitted.fulfill()
                return (response(for: request), try encryptedEAPIResponse(#"{"code":200}"#))
            case "/api/clientlog/encrypt/upload":
                return (response(for: request), Data(#"{"code":200}"#.utf8))
            default:
                throw TestError.unexpectedRequest(request.url?.absoluteString ?? "missing URL")
            }
        }

        let coordinator = PlaybackReportingCoordinator(client: client, storageURL: storeURL)
        defer { coordinator.deactivate() }
        await coordinator.activate(accountID: 42)
        let items = [playbackItem(1), playbackItem(2), playbackItem(3)]
        coordinator.playbackQueueDidChange(items: items, currentIndex: 1, loopMode: .repeatAll)
        coordinator.playbackDidStart(item: items[1])

        await fulfillment(of: [stateSubmitted], timeout: 2)
        let submissions = recorder.snapshot()
        XCTAssertEqual(submissions.songLists.count, 2)
        XCTAssertFalse(submissions.songLists[0].retransmit)
        XCTAssertTrue(submissions.songLists[1].retransmit)
        XCTAssertNotEqual(submissions.songLists[0].sessionID, submissions.songLists[1].sessionID)
        XCTAssertEqual(submissions.songLists[1].resources?.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(submissions.playStates.count, 1)
        XCTAssertEqual(submissions.playStates[0].sessionID, submissions.songLists[1].sessionID)
        XCTAssertEqual(submissions.playStates[0].resource, RelayResource(id: "2"))

        let relayPaths = MockURLProtocol.requests()
            .compactMap { $0.url?.path }
            .filter { $0.hasPrefix("/eapi/relay/") }
        XCTAssertEqual(relayPaths, [
            "/eapi/relay/config/get",
            "/eapi/relay/setting/show",
            "/eapi/relay/songlist/submit",
            "/eapi/relay/songlist/submit",
            "/eapi/relay/play/state/submit",
        ])
    }

    @MainActor
    func testPlaybackLifecycleQueuesOneStartAndOneEndWhenDawnFails() async throws {
        let client = makePlaybackClient()
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicBox-dawn-outbox-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        MockURLProtocol.configure { request in
            switch request.url?.path {
            case "/eapi/relay/config/get":
                return (
                    response(for: request),
                    try encryptedEAPIResponse(#"{"code":200,"data":{"enable":false}}"#)
                )
            case "/api/clientlog/encrypt/upload":
                throw TestError.unexpectedRequest("simulated dawn transport failure")
            default:
                throw TestError.unexpectedRequest(request.url?.absoluteString ?? "missing URL")
            }
        }

        let coordinator = PlaybackReportingCoordinator(client: client, storageURL: storeURL)
        defer { coordinator.deactivate() }
        await coordinator.activate(accountID: 42)
        let item = playbackItem(7)
        coordinator.playbackDidStart(item: item)
        coordinator.playbackDidStart(item: item)
        coordinator.playbackDidEnd(item: item, playedSeconds: 12.4, reason: .switched)

        let data = try Data(contentsOf: storeURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try XCTUnwrap(root["dawn"] as? [[String: Any]])
        let decodedEvents = try events.map { event -> (action: String, payload: [String: Any]) in
            let inner = try XCTUnwrap(event["event"] as? [String: Any])
            return (
                try XCTUnwrap(inner["action"] as? String),
                try XCTUnwrap(inner["payload"] as? [String: Any])
            )
        }

        XCTAssertEqual(decodedEvents.map(\.action), ["_plv", "_pld"])
        XCTAssertNil(decodedEvents[0].payload["end"])
        XCTAssertEqual(decodedEvents[1].payload["end"] as? String, "ui")
        XCTAssertEqual(decodedEvents[1].payload["time"] as? Double, 12)
    }

    private func makeClient() -> NeteaseHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return NeteaseHTTPClient(
            session: URLSession(configuration: configuration),
            defaults: defaults,
            deviceId: "test-device",
            weapiSecretKeyGenerator: { "abcdefghijklmnop" }
        )
    }

    private func makePlaybackClient() -> NeteasePlaybackClient {
        defaults.set("MUSIC_U=playback-token; __csrf=csrf-token", forKey: CloudMusicApi.SaveCookieName)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return NeteasePlaybackClient(
            session: URLSession(configuration: configuration),
            defaults: defaults,
            identity: NeteaseDesktopIdentity(
                clientSign: "0123456789ABCDEF0123456789ABCDEF",
                headerDeviceID: "HEADER%7CDEVICE",
                requestDeviceID: "00112233445566778899aabbccddeeff"
            )
        )
    }

    private func playbackItem(_ id: UInt64) -> PlaylistItem {
        PlaylistItem(
            id: id,
            url: nil,
            title: "Song \(id)",
            artist: "Artist",
            albumId: 0,
            ext: nil,
            duration: CMTime(seconds: 180, preferredTimescale: 1_000),
            artworkUrl: nil,
            nsSong: nil
        )
    }
}

private enum TestError: Error {
    case unexpectedRequest(String)
    case invalidRequest(String)
    case missingRequestBody
    case failedToReadRequestBody
}

private final class TransferProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TransferProgress] = []

    func record(_ progress: TransferProgress) {
        lock.lock()
        values.append(progress)
        lock.unlock()
    }

    func snapshot() -> [TransferProgress] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@MainActor
private final class AudioResourceRepository: PlaybackResourceServing {
    let data: CloudMusicApi.SongData

    init(data: CloudMusicApi.SongData) {
        self.data = data
    }

    func audioURL(for _: UInt64) async -> CloudMusicApi.SongData? { data }
    func lyrics(for _: UInt64) async -> CloudMusicApi.LyricNew? { nil }
}

private final class RelaySubmissionRecorder {
    private let lock = NSLock()
    private var songLists: [RelaySongListRequest] = []
    private var playStates: [RelayPlayStateRequest] = []

    func append(songList: RelaySongListRequest) -> Int {
        lock.lock()
        defer { lock.unlock() }
        songLists.append(songList)
        return songLists.count
    }

    func append(playState: RelayPlayStateRequest) {
        lock.lock()
        playStates.append(playState)
        lock.unlock()
    }

    func snapshot() -> (songLists: [RelaySongListRequest], playStates: [RelayPlayStateRequest]) {
        lock.lock()
        defer { lock.unlock() }
        return (songLists, playStates)
    }
}

private final class MockURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private static var requestHandler: Handler?
    private static var recordedRequests: [URLRequest] = []

    static func configure(_ handler: @escaping Handler) {
        lock.lock()
        requestHandler = handler
        recordedRequests = []
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        requestHandler = nil
        recordedRequests = []
        lock.unlock()
    }

    static func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    override class func canInit(with request: URLRequest) -> Bool {
        switch request.url?.host {
        case "interface.music.163.com", "interfacepc.music.163.com", "wanproxy.127.net",
            "upload.example.test", "audio.example.test", "clientlog3.music.163.com", "music.163.com":
            return true
        default:
            return false
        }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let handler = try Self.handler(for: request)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if request.url?.host == "audio.example.test", data.count > 1 {
                let midpoint = data.count / 2
                client?.urlProtocol(self, didLoad: Data(data[..<midpoint]))
                Thread.sleep(forTimeInterval: 0.05)
                client?.urlProtocol(self, didLoad: Data(data[midpoint...]))
            } else {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func handler(for request: URLRequest) throws -> Handler {
        lock.lock()
        recordedRequests.append(request)
        let handler = requestHandler
        lock.unlock()
        guard let handler else {
            throw TestError.unexpectedRequest("No handler for \(request.url?.absoluteString ?? "missing URL")")
        }
        return handler
    }
}

private func response(for request: URLRequest, headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: headers
    )!
}

private func formFields(from request: URLRequest) throws -> [String: String] {
    let body = try requestBody(from: request)
    guard let query = String(data: body, encoding: .utf8) else {
        throw TestError.invalidRequest("Request body is not UTF-8")
    }
    guard let components = URLComponents(string: "https://example.invalid/?\(query)") else {
        throw TestError.invalidRequest("Request body is not a form query")
    }
    return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}

private func requestBody(from request: URLRequest) throws -> Data {
    if let requestBody = request.httpBody {
        return requestBody
    } else if let stream = request.httpBodyStream {
        return try data(from: stream)
    } else {
        throw TestError.missingRequestBody
    }
}

private func data(from stream: InputStream) throws -> Data {
    stream.open()
    defer { stream.close() }

    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: buffer.count)
        if read < 0 {
            throw stream.streamError ?? TestError.failedToReadRequestBody
        }
        if read == 0 { break }
        result.append(buffer, count: read)
    }
    return result
}

private func md5(_ value: String) -> String {
    md5(Data(value.utf8))
}

private func md5(_ value: Data) -> String {
    Insecure.MD5.hash(data: value).map { String(format: "%02hhx", $0) }.joined()
}

private struct DecodedEAPIRequest {
    let path: String
    let requestJSON: String
    let digest: String
    let payload: [String: Any]
}

private func decodeEAPIRequest(_ request: URLRequest) throws -> DecodedEAPIRequest {
    let form = try formFields(from: request)
    guard let params = form["params"], let encrypted = Data(hexEncoded: params) else {
        throw TestError.invalidRequest("Missing EAPI params")
    }
    let plaintext = try eapiAES(encrypted, operation: CCOperation(kCCDecrypt))
    guard let signed = String(data: plaintext, encoding: .utf8) else {
        throw TestError.invalidRequest("Invalid EAPI plaintext")
    }
    let separator = "-36cd479b6b5-"
    let components = signed.components(separatedBy: separator)
    guard components.count == 3 else {
        throw TestError.unexpectedRequest("Malformed EAPI signing payload")
    }
    let json: Any
    do {
        json = try JSONSerialization.jsonObject(with: Data(components[1].utf8))
    } catch {
        throw TestError.invalidRequest("Invalid EAPI payload")
    }
    guard let payload = json as? [String: Any] else {
        throw TestError.invalidRequest("Invalid EAPI payload")
    }
    return DecodedEAPIRequest(
        path: components[0],
        requestJSON: components[1],
        digest: components[2],
        payload: payload
    )
}

private func decodeWEAPIPayload(_ body: Data, secretKey: String) throws -> [String: Any] {
    var request = URLRequest(url: URL(string: "https://example.test")!)
    request.httpBody = body
    let form = try formFields(from: request)
    guard let params = form["params"], let secondPass = Data(base64Encoded: params) else {
        throw TestError.invalidRequest("Missing WEAPI params")
    }
    let firstPassData = try weapiAES(
        secondPass,
        key: Data(secretKey.utf8),
        operation: CCOperation(kCCDecrypt)
    )
    guard
        let firstPass = String(data: firstPassData, encoding: .utf8),
        let encryptedPayload = Data(base64Encoded: firstPass)
    else {
        throw TestError.invalidRequest("Invalid WEAPI first pass")
    }
    let payloadData = try weapiAES(
        encryptedPayload,
        key: Data("0CoJUm6Qyw8W8jud".utf8),
        operation: CCOperation(kCCDecrypt)
    )
    guard let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
        throw TestError.invalidRequest("Invalid WEAPI payload")
    }
    return payload
}

private func encryptedEAPIResponse(_ json: String) throws -> Data {
    try eapiAES(Data(json.utf8), operation: CCOperation(kCCEncrypt))
}

private func eapiAES(_ data: Data, operation: CCOperation) throws -> Data {
    let key = Data("e82ckenh8dichen8".utf8)
    var output = Data(count: data.count + kCCBlockSizeAES128)
    let capacity = output.count
    var moved = 0
    let result = output.withUnsafeMutableBytes { outputBuffer in
        data.withUnsafeBytes { inputBuffer in
            key.withUnsafeBytes { keyBuffer in
                CCCrypt(
                    operation,
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                    keyBuffer.baseAddress,
                    kCCBlockSizeAES128,
                    nil,
                    inputBuffer.baseAddress,
                    data.count,
                    outputBuffer.baseAddress,
                    capacity,
                    &moved
                )
            }
        }
    }
    guard result == kCCSuccess else {
        throw TestError.unexpectedRequest("AES failed: \(result)")
    }
    return Data(output.prefix(moved))
}

private func weapiAES(_ data: Data, key: Data, operation: CCOperation) throws -> Data {
    let iv = Data("0102030405060708".utf8)
    var output = Data(count: data.count + kCCBlockSizeAES128)
    let capacity = output.count
    var moved = 0
    let result = output.withUnsafeMutableBytes { outputBuffer in
        data.withUnsafeBytes { inputBuffer in
            key.withUnsafeBytes { keyBuffer in
                iv.withUnsafeBytes { ivBuffer in
                    CCCrypt(
                        operation,
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBuffer.baseAddress,
                        key.count,
                        ivBuffer.baseAddress,
                        inputBuffer.baseAddress,
                        data.count,
                        outputBuffer.baseAddress,
                        capacity,
                        &moved
                    )
                }
            }
        }
    }
    guard result == kCCSuccess else {
        throw TestError.unexpectedRequest("WEAPI AES failed: \(result)")
    }
    return Data(output.prefix(moved))
}

private func dataFromHex(_ value: String) -> Data {
    Data(hexEncoded: value)!
}

private func readLittleEndianUInt16(_ data: Data, offset: Int) -> UInt16 {
    UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
}

private func readLittleEndianUInt32(_ data: Data, offset: Int) -> UInt32 {
    UInt32(data[offset])
        | UInt32(data[offset + 1]) << 8
        | UInt32(data[offset + 2]) << 16
        | UInt32(data[offset + 3]) << 24
}

private extension Data {
    init?(hexEncoded value: String) {
        guard value.count.isMultiple(of: 2) else { return nil }
        var result = Data()
        var index = value.startIndex
        while index < value.endIndex {
            let end = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<end], radix: 16) else { return nil }
            result.append(byte)
            index = end
        }
        self = result
    }

    var hexEncoded: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
