//
//  NeteasePlaybackClient.swift
//  MusicBox
//
//  Native desktop playback reporting and relay handoff transport.
//

import CommonCrypto
import CryptoKit
import Foundation

enum JSONValue: Codable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        switch self {
        case let .string(value): return value
        case let .number(value): return String(Int64(value))
        default: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case let .number(value): return Int(value)
        case let .string(value): return Int(value)
        default: return nil
        }
    }

    var int64Value: Int64? {
        switch self {
        case let .number(value): return Int64(value)
        case let .string(value): return Int64(value)
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case let .bool(value): return value
        case let .number(value): return value != 0
        case let .string(value): return (value as NSString).boolValue
        default: return nil
        }
    }

    var foundationValue: Any {
        switch self {
        case let .object(value): return value.mapValues(\.foundationValue)
        case let .array(value): return value.map(\.foundationValue)
        case let .string(value): return value
        case let .number(value): return value
        case let .bool(value): return value
        case .null: return NSNull()
        }
    }
}

struct RelayResource: Codable, Equatable, Hashable {
    let id: String
    let type: String

    init(id: UInt64, type: String = "song") {
        self.id = String(id)
        self.type = type
    }

    init(id: String, type: String = "song") {
        self.id = id
        self.type = type
    }
}

struct RelayConfig: Equatable {
    let enabled: Bool
    let snapshotSize: Int
    let radioProgressInterval: TimeInterval
}

struct RelayHandoffOffer: Equatable {
    let payload: [String: JSONValue]

    var deviceID: String? { payload["deviceId"]?.stringValue }
    var title: String? { payload["reconnectTitle"]?.stringValue }
}

struct RelayPullResult: Equatable {
    let sourceID: String?
    let sourceType: String?
    let resources: [RelayResource]
    let currentResourceID: String?
    let currentResourceType: String?
    let progressMilliseconds: Int
    let playMode: String?
}

struct RelaySongListRequest: Codable, Equatable {
    let retransmit: Bool
    let sessionID: String
    let initialResourceID: String
    let playMode: String
    let sourceType: String?
    let sourceID: String?
    let resources: [RelayResource]?

    enum CodingKeys: String, CodingKey {
        case retransmit
        case sessionID = "sessionId"
        case initialResourceID = "initResId"
        case playMode
        case sourceType
        case sourceID = "sourceId"
        case resources
    }
}

struct RelayPlayStateRequest: Codable, Equatable {
    let resource: RelayResource
    let progress: Int
    let sessionID: String
    let playMode: String

    enum CodingKeys: String, CodingKey {
        case resource
        case progress
        case sessionID = "sessionId"
        case playMode
    }
}

struct DawnEvent: Codable, Equatable, Identifiable {
    let id: UUID
    let action: String
    let timestamp: Int64
    let payload: [String: JSONValue]

    init(id: UUID = UUID(), action: String, timestamp: Int64 = Int64(Date().timeIntervalSince1970), payload: [String: JSONValue]) {
        self.id = id
        self.action = action
        self.timestamp = timestamp
        self.payload = payload
    }
}

private struct DawnUserInfo: Encodable {
    let musicU: String?
    let musicA: String?
    let buildver: String
    let appver: String

    enum CodingKeys: String, CodingKey {
        case musicU = "MUSIC_U"
        case musicA = "MUSIC_A"
        case buildver
        case appver
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let musicU, !musicU.isEmpty {
            try container.encode(musicU, forKey: .musicU)
        } else if let musicA, !musicA.isEmpty {
            try container.encode(musicA, forKey: .musicA)
        }
        try container.encode(buildver, forKey: .buildver)
        try container.encode(appver, forKey: .appver)
    }
}

struct NeteaseDesktopIdentity: Codable, Equatable {
    let clientSign: String
    let headerDeviceID: String
    let requestDeviceID: String

    static func make() -> NeteaseDesktopIdentity {
        let headerDeviceID = "\(UUID().uuidString.uppercased())%7C\(UUID().uuidString.uppercased())"
        return NeteaseDesktopIdentity(
            clientSign: Self.randomHex(length: 32),
            headerDeviceID: headerDeviceID,
            requestDeviceID: Self.randomHex(length: 32).lowercased()
        )
    }

    private static func randomHex(length: Int) -> String {
        let alphabet = Array("0123456789ABCDEF")
        return String((0..<length).compactMap { _ in alphabet.randomElement() })
    }
}

final class NeteasePlaybackClient {
    static let shared = NeteasePlaybackClient()

    private static let eapiBaseURL = URL(string: "https://interface.music.163.com")!
    private static let primaryDawnURL = URL(
        string: "https://clientlog3.music.163.com/api/clientlog/encrypt/upload?multiupload=true"
    )!
    private static let fallbackDawnURL = URL(
        string: "https://music.163.com/api/clientlog/encrypt/upload?multiupload=true"
    )!
    private static let desktopAppVersion = "3.1.8"
    private static let desktopBuildVersion = "3368"
    private static let identityKey = "NeteasePlaybackDesktopIdentity"
    private static let eapiKey = Data("e82ckenh8dichen8".utf8)

    private let session: URLSession
    private let defaults: UserDefaults
    private let identity: NeteaseDesktopIdentity

    init(
        session: URLSession = NeteasePlaybackClient.makeDefaultSession(),
        defaults: UserDefaults = .standard,
        identity: NeteaseDesktopIdentity? = nil
    ) {
        self.session = session
        self.defaults = defaults
        if let identity {
            self.identity = identity
        } else if let data = defaults.data(forKey: Self.identityKey),
            let saved = try? JSONDecoder().decode(NeteaseDesktopIdentity.self, from: data)
        {
            self.identity = saved
        } else {
            let generated = NeteaseDesktopIdentity.make()
            self.identity = generated
            defaults.set(try? JSONEncoder().encode(generated), forKey: Self.identityKey)
        }
    }

    func hasAuthenticatedSession() -> Bool {
        let cookies = parsedCookie()
        return !(cookies["MUSIC_U"] ?? cookies["MUSIC_A"] ?? "").isEmpty
    }

    func relayConfig() async throws -> RelayConfig {
        let response = try await postEAPI(
            endpoint: "/eapi/relay/config/get",
            apiPath: "/api/relay/config/get",
            fields: [:]
        )
        let object = try responseObject(response)
        try requireSuccess(object)
        let data = object["data"]?.objectValue ?? object
        return RelayConfig(
            enabled: data["enable"]?.boolValue ?? false,
            snapshotSize: max(1, data["snapshotSize"]?.intValue ?? 20),
            radioProgressInterval: TimeInterval(max(1, data["radioProgressInterval"]?.intValue ?? 30))
        )
    }

    func relaySetting() async throws -> Bool {
        let response = try await postEAPI(
            endpoint: "/eapi/relay/setting/show",
            apiPath: "/api/relay/setting/show",
            fields: ["all": false, "settingKey": "RELAY_SWITCH"]
        )
        let object = try responseObject(response)
        try requireSuccess(object)
        let data = object["data"]
        return data?.boolValue
            ?? data?.objectValue?["enable"]?.boolValue
            ?? data?.objectValue?["isEnable"]?.boolValue
            ?? object["enable"]?.boolValue
            ?? object["isEnable"]?.boolValue
            ?? false
    }

    func updateRelaySetting(enabled: Bool) async throws {
        let response = try await postEAPI(
            endpoint: "/eapi/relay/setting/update",
            apiPath: "/api/relay/setting/update",
            fields: [
                "targetDeviceId": identity.requestDeviceID,
                "enable": enabled,
                "settingKey": "RELAY_SWITCH",
            ]
        )
        try requireSuccess(try responseObject(response))
    }

    func submitRelaySongList(_ request: RelaySongListRequest) async throws -> Int {
        let requestJSON = try Self.jsonString(request)
        let response = try await postEAPI(
            endpoint: "/eapi/relay/songlist/submit",
            apiPath: "/api/relay/songlist/submit",
            fields: ["songListSubmitReq": requestJSON]
        )
        return try responseCode(response)
    }

    func submitRelayPlayState(_ request: RelayPlayStateRequest) async throws -> Int {
        let requestJSON = try Self.jsonString(request)
        let response = try await postEAPI(
            endpoint: "/eapi/relay/play/state/submit",
            apiPath: "/api/relay/play/state/submit",
            fields: ["playStateSubmitReq": requestJSON]
        )
        return try responseCode(response)
    }

    func handoffOffer() async throws -> RelayHandoffOffer? {
        let extJSON: [String: Any] = [
            "interactRecords": [],
            "preData": [],
            "states": ["relayInfo": ["current": "{\"needCheck\":true}", "prev": ""]],
        ]
        let response = try await postEAPI(
            endpoint: "/eapi/link/position/show/resource",
            apiPath: "/api/link/position/show/resource",
            fields: [
                "positionCode": "multi_terminal_reconnect_info",
                "extJson": extJSON,
            ]
        )
        let object = try responseObject(response)
        try requireSuccess(object)
        let resources = object["data"]?.objectValue?["commonResourceList"]?.arrayValue
        guard let payload = resources?.first?.objectValue?["generalizedObject"]?.objectValue,
            !(payload["deviceId"]?.stringValue ?? "").isEmpty
        else {
            return nil
        }
        return RelayHandoffOffer(payload: payload)
    }

    func pullRelayPlay(offer: RelayHandoffOffer) async throws -> RelayPullResult {
        guard let targetDeviceID = offer.deviceID, !targetDeviceID.isEmpty else {
            throw RequestError.Request("Missing handoff target device ID")
        }
        var fields = offer.payload.mapValues(\.foundationValue)
        fields["targetDeviceId"] = targetDeviceID
        let response = try await postEAPI(
            endpoint: "/eapi/relay/play/pull",
            apiPath: "/api/relay/play/pull",
            fields: fields
        )
        let object = try responseObject(response)
        try requireSuccess(object)
        let data = object["data"]?.objectValue ?? object
        let current = data["currentPlayState"]?.objectValue
        let resources = (data["resources"]?.arrayValue ?? []).compactMap { value -> RelayResource? in
            guard let object = value.objectValue,
                let id = object["id"]?.stringValue,
                !id.isEmpty
            else { return nil }
            return RelayResource(id: id, type: object["type"]?.stringValue ?? "song")
        }
        return RelayPullResult(
            sourceID: data["sourceId"]?.stringValue,
            sourceType: data["sourceType"]?.stringValue,
            resources: resources,
            currentResourceID: current?["resourceId"]?.stringValue,
            currentResourceType: current?["resourceType"]?.stringValue,
            progressMilliseconds: max(0, current?["progress"]?.intValue ?? 0),
            playMode: data["playMode"]?.stringValue
        )
    }

    func uploadDawn(events: [DawnEvent], sequence: UInt32) async throws {
        guard !events.isEmpty else { return }
        let cookies = parsedCookie()
        guard let auth = cookies["MUSIC_U"] ?? cookies["MUSIC_A"], !auth.isEmpty else {
            throw RequestError.Request("NetEase authentication is required for playback reporting")
        }

        let userInfo = Self.userInfo(
            musicU: cookies["MUSIC_U"],
            musicA: cookies["MUSIC_A"]
        )
        let payload = try DawnLogEncoder.encode(events: events)
        let blob = try DawnLogEncoder.wrap(payload: payload, userInfo: userInfo, sequence: sequence)
        let filename = "monitor_\(getpid())_\(sequence)_\(UInt32.random(in: .min ... .max))"

        do {
            try await postDawn(blob: blob, filename: filename, url: Self.primaryDawnURL)
        } catch {
            try await postDawn(blob: blob, filename: filename, url: Self.fallbackDawnURL)
        }
    }

    private func postEAPI(
        endpoint: String,
        apiPath: String,
        fields: [String: Any]
    ) async throws -> Data {
        guard hasAuthenticatedSession() else {
            throw RequestError.Request("NetEase authentication is required for relay handoff")
        }
        guard let url = URL(string: endpoint + "?_nmclfl=1", relativeTo: Self.eapiBaseURL) else {
            throw RequestError.Request("Invalid NetEase EAPI endpoint")
        }

        var body = fields
        body["deviceId"] = identity.requestDeviceID
        body["os"] = "OSX"
        body["verifyId"] = 1
        body["e_r"] = true
        let header: [String: Any] = [
            "clientSign": identity.clientSign,
            "os": "osx",
            "appver": Self.desktopAppVersion,
            "deviceId": identity.headerDeviceID,
            "requestId": 0,
            "osver": Self.osVersion,
        ]
        body["header"] = String(decoding: try Self.jsonData(header), as: UTF8.self)
        let requestJSON = try Self.jsonData(body)
        let requestText = String(decoding: requestJSON, as: UTF8.self)
        let digest = Self.md5("nobody\(apiPath)use\(requestText)md5forencrypt")
        let signedText = "\(apiPath)-36cd479b6b5-\(requestText)-36cd479b6b5-\(digest)"
        let encrypted = try Self.aesECB(Data(signedText.utf8), operation: CCOperation(kCCEncrypt))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.httpBody = Data("params=\(Self.percentEncode(encrypted.hexString.uppercased()))".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(desktopCookieHeader(), forHTTPHeaderField: "Cookie")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RequestError.Request("NetEase EAPI returned a non-HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw RequestError.Request("NetEase EAPI failed with HTTP \(httpResponse.statusCode)")
        }
        return try decodeEAPIResponse(data)
    }

    private func postDawn(blob: Data, filename: String, url: URL) async throws {
        let boundary = "0xKhTmLbOuNdArY-\(UUID().uuidString)"
        let body = Self.multipartAttach(boundary: boundary, filename: filename, data: blob)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.httpBody = body
        request.setValue(
            "multipart/form-data; charset=utf-8; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(desktopCookieHeader(), forHTTPHeaderField: "Cookie")
        request.setValue("osx", forHTTPHeaderField: "os")
        request.setValue(Self.desktopAppVersion, forHTTPHeaderField: "appver")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")

        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RequestError.Request("Dawn upload returned a non-HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw RequestError.Request("Dawn upload failed with HTTP \(httpResponse.statusCode)")
        }
        let object = try responseObject(responseData)
        try requireSuccess(object)
    }

    private func decodeEAPIResponse(_ data: Data) throws -> Data {
        if (try? responseObject(data)) != nil {
            return data
        }
        if let decrypted = try? Self.aesECB(data, operation: CCOperation(kCCDecrypt)),
            (try? responseObject(decrypted)) != nil
        {
            return decrypted
        }
        if let text = String(data: data, encoding: .utf8),
            let encoded = Data(hexString: text.trimmingCharacters(in: .whitespacesAndNewlines)),
            let decrypted = try? Self.aesECB(encoded, operation: CCOperation(kCCDecrypt)),
            (try? responseObject(decrypted)) != nil
        {
            return decrypted
        }
        throw RequestError.Request("Unable to decode NetEase EAPI response")
    }

    private func responseCode(_ data: Data) throws -> Int {
        let object = try responseObject(data)
        return object["code"]?.intValue ?? 0
    }

    private func responseObject(_ data: Data) throws -> [String: JSONValue] {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
            let object = root.objectValue
        else {
            throw RequestError.Request("Invalid NetEase JSON response")
        }
        return object
    }

    private func requireSuccess(_ object: [String: JSONValue]) throws {
        let code = object["code"]?.intValue ?? 0
        guard code == 200 else {
            let message = object["message"]?.stringValue ?? object["msg"]?.stringValue ?? "NetEase request failed"
            throw RequestError.errorCode((code, message))
        }
    }

    private var desktopUserAgent: String {
        "NeteaseMusic/\(Self.desktopBuildVersion) CFNetwork/3896.100.1.1.1 Darwin/\(Self.osVersion)"
    }

    private func desktopCookieHeader() -> String {
        var cookies = parsedCookie()
        cookies["clientSign"] = identity.clientSign
        cookies["deviceId"] = identity.headerDeviceID
        cookies["os"] = "osx"
        cookies["osver"] = Self.osVersion
        cookies["appver"] = Self.desktopAppVersion
        cookies["buildver"] = Self.desktopBuildVersion
        cookies["channel"] = "appstore"
        cookies["__remember_me"] = "true"
        return cookies.keys.sorted().map { key in
            key + "=" + (cookies[key] ?? "")
        }.joined(separator: "; ")
    }

    private func parsedCookie() -> [String: String] {
        guard let cookie = defaults.string(forKey: CloudMusicApi.SaveCookieName), !cookie.isEmpty else {
            return [:]
        }
        var result: [String: String] = [:]
        for item in cookie.split(separator: ";") {
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            result[pair[0].trimmingCharacters(in: .whitespaces)] =
                pair[1].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    private static func userInfo(musicU: String?, musicA: String?) -> String {
        let value = DawnUserInfo(
            musicU: musicU,
            musicA: musicA,
            buildver: desktopBuildVersion,
            appver: desktopAppVersion
        )
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func multipartAttach(boundary: String, filename: String, data: Data) -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(
            Data(
                "Content-Disposition: form-data; name=\"attach\"; filename=\"\(filename)\"\r\n"
                    .utf8
            )
        )
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    private static func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func jsonString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw RequestError.Request("Failed to encode NetEase request JSON")
        }
        return string
    }

    private static func percentEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func md5(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func aesECB(_ data: Data, operation: CCOperation) throws -> Data {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { outputBuffer in
            data.withUnsafeBytes { inputBuffer in
                eapiKey.withUnsafeBytes { keyBuffer in
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
                        outputCapacity,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw RequestError.Request("NetEase EAPI AES operation failed: \(status)")
        }
        return Data(output.prefix(moved))
    }

    private static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }
}

enum DawnLogEncoder {
    private static let rsaModulus = Data(hexString: "fd90bd466ff9bc8a3fec2fbcf263b90d5c564879fa5d7aab89b31c1d5cb4139d")!

    static func encode(events: [DawnEvent]) throws -> Data {
        var result = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for event in events {
            let payload = try encoder.encode(event.payload)
            guard let payloadText = String(data: payload, encoding: .utf8) else {
                throw RequestError.Request("Failed to encode dawn event")
            }
            result += "\(event.timestamp)\u{1}\(event.action)\u{1}\(payloadText)\n"
        }
        return Data(result.utf8)
    }

    static func wrap(payload: Data, userInfo: String, sequence: UInt32) throws -> Data {
        var sessionKey = randomData(count: 32)
        if sessionKey[sessionKey.startIndex] >= 0xA3 {
            sessionKey[sessionKey.startIndex] = 0xA2
        }
        let session = sessionMaterial()
        let wrappedKey = rsaNoPadding(sessionKey)
        let encryptedUserInfo = chacha20XOR(
            Data(userInfo.utf8), key: wrappedKey, nonce: session.nonce, counter: session.counter
        )
        var tlv = Data()
        tlv.appendLittleEndian(UInt16(0x4343))
        tlv.appendLittleEndian(UInt16(encryptedUserInfo.count))
        tlv.append(encryptedUserInfo)

        let compressed = zstdRawFrame(payload)
        var record = Data()
        record.appendLittleEndian(UInt16(compressed.count))
        record.appendLittleEndian(sequence)
        record.append(chacha20XOR(compressed, key: sessionKey, nonce: session.nonce, counter: session.counter))

        var header = Data()
        header.appendLittleEndian(UInt32(0x4C42434E))
        header.appendLittleEndian(UInt32(3))
        header.appendLittleEndian(UInt16(70 + tlv.count))
        header.append(session.identifier)
        header.append(wrappedKey)
        header.appendLittleEndian(sequence)
        header.appendLittleEndian(sequence)
        header.appendLittleEndian(UInt32(record.count))
        header.append(tlv)
        header.append(record)
        return header
    }

    static func zstdRawFrame(_ payload: Data) -> Data {
        precondition(payload.count <= Int(UInt32.max))
        var frame = Data([0x28, 0xB5, 0x2F, 0xFD, 0xA0])
        frame.appendLittleEndian(UInt32(payload.count))

        let blockSize = 128 * 1024
        if payload.isEmpty {
            frame.appendLittleEndian(UInt32(1), byteCount: 3)
            return frame
        }
        var offset = 0
        while offset < payload.count {
            let count = min(blockSize, payload.count - offset)
            let isLast = offset + count == payload.count
            let header = UInt32(count << 3) | (isLast ? 1 : 0)
            frame.appendLittleEndian(header, byteCount: 3)
            frame.append(payload[offset..<(offset + count)])
            offset += count
        }
        return frame
    }

    private static func rsaNoPadding(_ key: Data) -> Data {
        let value = Array(key)
        let modulus = Array(rsaModulus)
        var result = value
        for _ in 0..<16 {
            result = modularMultiply(result, result, modulus: modulus)
        }
        result = modularMultiply(result, value, modulus: modulus)
        return Data(result)
    }

    private static func modularMultiply(_ lhs: [UInt8], _ rhs: [UInt8], modulus: [UInt8]) -> [UInt8] {
        var result = Array(repeating: UInt8(0), count: modulus.count)
        let addend = lhs
        for byte in rhs {
            for bit in stride(from: 7, through: 0, by: -1) {
                result = modularAdd(result, result, modulus: modulus)
                if (byte & (1 << bit)) != 0 {
                    result = modularAdd(result, addend, modulus: modulus)
                }
            }
        }
        return result
    }

    private static func modularAdd(_ lhs: [UInt8], _ rhs: [UInt8], modulus: [UInt8]) -> [UInt8] {
        var sum = Array(repeating: UInt8(0), count: lhs.count + 1)
        var carry = 0
        for index in stride(from: lhs.count - 1, through: 0, by: -1) {
            let value = Int(lhs[index]) + Int(rhs[index]) + carry
            sum[index + 1] = UInt8(value & 0xFF)
            carry = value >> 8
        }
        sum[0] = UInt8(carry)
        let modulusWithLeadingZero = [UInt8(0)] + modulus
        if sum[0] != 0 || compare(sum, modulusWithLeadingZero) >= 0 {
            sum = subtract(sum, modulusWithLeadingZero)
        }
        return Array(sum.dropFirst())
    }

    private static func compare(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        for (left, right) in zip(lhs, rhs) {
            if left < right { return -1 }
            if left > right { return 1 }
        }
        return 0
    }

    private static func subtract(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
        var result = lhs
        var borrow = 0
        for index in stride(from: lhs.count - 1, through: 0, by: -1) {
            var value = Int(lhs[index]) - Int(rhs[index]) - borrow
            if value < 0 {
                value += 256
                borrow = 1
            } else {
                borrow = 0
            }
            result[index] = UInt8(value)
        }
        return result
    }

    private static func sessionMaterial() -> (identifier: Data, nonce: Data, counter: UInt32) {
        let high = UInt64.random(in: .min ... .max)
        let low = (UInt64.random(in: .min ... .max) & 0xFF0F_FFFF_FFFF_FFFF) | 0x0040_0000_0000_0000
        let adjustedHigh = (high & 0xFFFF_FFFF_FFFF_FF3F) | 0x80
        var identifier = Data()
        identifier.appendLittleEndian(low)
        identifier.appendLittleEndian(adjustedHigh)
        return (
            identifier,
            Data(identifier.prefix(12)),
            UInt32(truncatingIfNeeded: high >> 34)
        )
    }

    private static func randomData(count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
    }

    static func chacha20XOR(_ data: Data, key: Data, nonce: Data, counter: UInt32) -> Data {
        precondition(key.count == 32 && nonce.count == 12)
        var result = Data(count: data.count)
        var offset = 0
        var blockCounter = counter
        while offset < data.count {
            let block = chacha20Block(key: key, nonce: nonce, counter: blockCounter)
            let count = min(64, data.count - offset)
            for index in 0..<count {
                result[offset + index] = data[offset + index] ^ block[index]
            }
            offset += count
            blockCounter &+= 1
        }
        return result
    }

    private static func chacha20Block(key: Data, nonce: Data, counter: UInt32) -> Data {
        func word(_ data: Data, _ offset: Int) -> UInt32 {
            UInt32(data[offset])
                | UInt32(data[offset + 1]) << 8
                | UInt32(data[offset + 2]) << 16
                | UInt32(data[offset + 3]) << 24
        }
        var state: [UInt32] = [
            0x6170_7865, 0x3320_646E, 0x7962_2D32, 0x6B20_6574,
            word(key, 0), word(key, 4), word(key, 8), word(key, 12),
            word(key, 16), word(key, 20), word(key, 24), word(key, 28),
            counter, word(nonce, 0), word(nonce, 4), word(nonce, 8),
        ]
        let original = state
        func quarterRound(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
            state[a] &+= state[b]
            state[d] = (state[d] ^ state[a]).rotatedLeft(16)
            state[c] &+= state[d]
            state[b] = (state[b] ^ state[c]).rotatedLeft(12)
            state[a] &+= state[b]
            state[d] = (state[d] ^ state[a]).rotatedLeft(8)
            state[c] &+= state[d]
            state[b] = (state[b] ^ state[c]).rotatedLeft(7)
        }
        for _ in 0..<10 {
            quarterRound(0, 4, 8, 12)
            quarterRound(1, 5, 9, 13)
            quarterRound(2, 6, 10, 14)
            quarterRound(3, 7, 11, 15)
            quarterRound(0, 5, 10, 15)
            quarterRound(1, 6, 11, 12)
            quarterRound(2, 7, 8, 13)
            quarterRound(3, 4, 9, 14)
        }
        var output = Data()
        for index in 0..<16 {
            output.appendLittleEndian(state[index] &+ original[index])
        }
        return output
    }
}

private extension UInt32 {
    func rotatedLeft(_ amount: UInt32) -> UInt32 {
        (self << amount) | (self >> (32 - amount))
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var value = Data()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let end = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<end], radix: 16) else { return nil }
            value.append(byte)
            index = end
        }
        self = value
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T, byteCount: Int? = nil) {
        var value = value.littleEndian
        let count = byteCount ?? MemoryLayout<T>.size
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0.prefix(count)) }
    }
}
