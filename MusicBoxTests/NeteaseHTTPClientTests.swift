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

    func testCloudUploadSkipsNosWhenServerAlreadyHasFile() async throws {
        let client = makeClient()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicBox-cloud-test-\(UUID().uuidString).mp3")
        let fileData = Data("cloud test audio".utf8)
        try fileData.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        MockURLProtocol.configure { request in
            switch request.url?.path {
            case "/api/cloud/upload/check":
                let form = try formFields(from: request)
                XCTAssertEqual(form["length"], String(fileData.count))
                XCTAssertEqual(form["md5"], md5(fileData))
                return (response(for: request), Data(#"{"code":200,"needUpload":false,"songId":42}"#.utf8))
            case "/api/nos/token/alloc":
                return (response(for: request), Data(#"{"code":200,"result":{"resourceId":7}}"#.utf8))
            case "/api/upload/cloud/info/v2":
                let form = try formFields(from: request)
                XCTAssertEqual(form["songid"], "42")
                XCTAssertEqual(form["resourceId"], "7")
                return (response(for: request), Data(#"{"code":200,"songId":42}"#.utf8))
            case "/api/cloud/pub/v2":
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
            "/api/cloud/upload/check",
            "/api/nos/token/alloc",
            "/api/upload/cloud/info/v2",
            "/api/cloud/pub/v2",
        ])
    }

    func testCloudUploadStreamsFileThroughNos() async throws {
        let client = makeClient()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicBox-cloud-upload-\(UUID().uuidString).mp3")
        let fileData = Data("cloud upload audio body".utf8)
        try fileData.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        MockURLProtocol.configure { request in
            switch (request.url?.host, request.url?.path) {
            case ("interface.music.163.com", "/api/cloud/upload/check"):
                return (response(for: request), Data(#"{"code":200,"needUpload":true,"songId":42}"#.utf8))
            case ("interface.music.163.com", "/api/nos/token/alloc"):
                let form = try formFields(from: request)
                if form["bucket"] == "" {
                    return (response(for: request), Data(#"{"code":200,"result":{"resourceId":7}}"#.utf8))
                }
                XCTAssertEqual(form["bucket"], "jd-musicrep-privatecloud-audio-public")
                return (
                    response(for: request),
                    Data(#"{"code":200,"result":{"token":"nos-token","objectKey":"folder/object.mp3"}}"#.utf8)
                )
            case ("wanproxy.127.net", "/lbs"):
                return (response(for: request), Data(#"{"upload":["https://upload.example.test"]}"#.utf8))
            case ("upload.example.test", _):
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-nos-token"), "nos-token")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-MD5"), md5(fileData))
                XCTAssertTrue(request.url?.absoluteString.contains("folder%2Fobject.mp3") == true)
                XCTAssertEqual(try requestBody(from: request), fileData)
                return (response(for: request), Data())
            case ("interface.music.163.com", "/api/upload/cloud/info/v2"):
                return (response(for: request), Data(#"{"code":200,"songId":42}"#.utf8))
            case ("interface.music.163.com", "/api/cloud/pub/v2"):
                return (response(for: request), Data(#"{"code":200,"privateCloud":{"songId":42}}"#.utf8))
            default:
                throw TestError.unexpectedRequest(request.url?.absoluteString ?? "missing URL")
            }
        }

        let songID = try await client.uploadCloudFile(
            fileURL: fileURL,
            songName: nil,
            artist: nil,
            album: nil
        )

        XCTAssertEqual(songID, 42)
        XCTAssertEqual(MockURLProtocol.requests().count, 7)
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

    private func makeClient() -> NeteaseHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return NeteaseHTTPClient(
            session: URLSession(configuration: configuration),
            defaults: defaults,
            deviceId: "test-device"
        )
    }
}

private enum TestError: Error {
    case unexpectedRequest(String)
    case missingRequestBody
    case failedToReadRequestBody
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
        case "interface.music.163.com", "wanproxy.127.net", "upload.example.test":
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
            client?.urlProtocol(self, didLoad: data)
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
        return try XCTUnwrap(handler)
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
    let query = try XCTUnwrap(String(data: body, encoding: .utf8))
    let components = try XCTUnwrap(URLComponents(string: "https://example.invalid/?\(query)"))
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
