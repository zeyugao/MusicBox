/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Struct `PlaylistItem` is a playable track as an item in a playlist.
*/

import AVFoundation
import Foundation

private final class RunBlocking<T, Failure: Error> {
    fileprivate var value: Result<T, Failure>? = nil
}

extension RunBlocking where Failure == Never {
    func runBlocking(_ operation: @Sendable @escaping () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            let task = Task(operation: operation)
            self.value = await task.result
            semaphore.signal()
        }
        semaphore.wait()
        switch value {
        case let .success(value):
            return value
        case .none:
            fatalError("Run blocking not received value")
        }
    }
}

extension RunBlocking where Failure == Error {
    func runBlocking(_ operation: @Sendable @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            let task = Task(operation: operation)
            value = await task.result
            semaphore.signal()
        }
        semaphore.wait()
        switch value {
        case let .success(value):
            return value
        case let .failure(error):
            throw error
        case .none:
            fatalError("Run blocking not received value")
        }
    }
}

func runBlocking<T>(@_implicitSelfCapture _ operation: @Sendable @escaping () async -> T) -> T {
    RunBlocking().runBlocking(operation)
}

func runBlocking<T>(@_implicitSelfCapture _ operation: @Sendable @escaping () async throws -> T)
    throws -> T
{
    try RunBlocking().runBlocking(operation)
}

func isLocalURL(_ url: URL) -> Bool {
    return url.scheme == "file"
}

func isRemoteURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme else { return false }
    return ["http", "https", "ftp"].contains(scheme)
}

func downloadFile(url: URL, savePath: URL, ext: String) async -> URL? {
    let fileManager = FileManager.default
    // Check if file already exists
    if fileManager.fileExists(atPath: savePath.path) {
        print("File already exists, no need to download.")
    } else {
        do {
            // TODO: Streaming
            print("Downloading file from \(url) to \(savePath)")
            let (data, _) = try await URLSession.shared.data(from: url)
            try data.write(to: savePath)
        } catch {
            print("Error downloading or saving the file: \(error)")
            return nil
        }
    }
    return savePath
}

func getCachedMusicFile(id: UInt64) -> URL? {
    guard let appMusicFolder = getMusicBoxFolder() else {
        return nil
    }
    let exts = [
        "mp3", "MP3", "flac", "FLAC", "m4a", "M4A", "aac", "AAC", "wav", "WAV", "ogg", "OGG",
        "alac", "ALAC", "aiff", "AIFF", "caf", "CAF", "opus", "OPUS", "wma", "WMA", "mp4", "MP4",
        "webm", "WEBM", "aax", "AAX", "aa", "AA", "dsd", "DSD", "dff", "DFF", "dsf", "DSF", "pcm",
        "PCM", "flv", "FLV",
    ]
    for ext in exts {
        let localFileUrl = appMusicFolder.appendingPathComponent("\(id).\(ext)")
        if FileManager.default.fileExists(atPath: localFileUrl.path) {
            return localFileUrl
        }
    }
    return nil
}

func getMusicBoxFolder() -> URL? {
    let fileManager = FileManager.default
    guard
        let musicFolder = fileManager.urls(
            for: .musicDirectory, in: .userDomainMask
        ).first
    else {
        return nil
    }
    let appMusicFolder = musicFolder.appendingPathComponent("MusicBox")

    // Create the directory if it does not exist
    if !fileManager.fileExists(atPath: appMusicFolder.path) {
        do {
            try fileManager.createDirectory(
                at: appMusicFolder, withIntermediateDirectories: true)
        } catch {
            print("Failed to create directory: \(error)")
            return nil
        }
    }
    return appMusicFolder
}

func downloadMusicFile(url: URL, id: UInt64, ext: String) async -> URL? {
    guard let appMusicFolder = getMusicBoxFolder() else {
        return nil
    }

    let localFileUrl = appMusicFolder.appendingPathComponent("\(id).\(ext)")
    return await downloadFile(url: url, savePath: localFileUrl, ext: ext)
}

class PlaylistItem: Identifiable, Codable, Equatable {
    static func == (lhs: PlaylistItem, rhs: PlaylistItem) -> Bool {
        return lhs.id == rhs.id
    }

    let id: UInt64

    /// URL of the local file containing the track's audio.
    var url: URL?

    /// An error that prevents the track from playing.
    let error: Error?

    /// The title of the track.
    let title: String

    /// The artist heard on the track.
    let artist: String

    /// The ext name
    var ext: String?

    /// The duration of the audio file.
    let duration: CMTime

    let albumId: UInt64

    var artworkUrl: URL?

    let nsSong: CloudMusicApi.Song?

    /// Initializes a valid item.
    init(
        id: UInt64, url: URL?, title: String, artist: String, albumId: UInt64, ext: String?,
        duration: CMTime,
        artworkUrl: URL?,
        nsSong: CloudMusicApi.Song?
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.artist = artist
        self.ext = ext
        self.albumId = albumId
        self.duration = duration
        self.error = nil
        self.artworkUrl = artworkUrl
        self.nsSong = nsSong
    }

    enum CodingKeys: String, CodingKey {
        case id, url, title, artist, ext, duration, albumId, artworkUrl, nsSong
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UInt64.self, forKey: .id)
        url = try container.decodeIfPresent(URL.self, forKey: .url)
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decode(String.self, forKey: .artist)
        ext = try container.decodeIfPresent(String.self, forKey: .ext)
        let seconds = try container.decode(Double.self, forKey: .duration)
        duration = CMTime(seconds: seconds, preferredTimescale: 1000)
        albumId = try container.decode(UInt64.self, forKey: .albumId)
        artworkUrl = try container.decodeIfPresent(URL.self, forKey: .artworkUrl)
        nsSong = try container.decodeIfPresent(CloudMusicApi.Song.self, forKey: .nsSong)
        error = nil  // This should be handled according to your application logic
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encodeIfPresent(ext, forKey: .ext)
        // Encode CMTime as a Double representing total seconds
        let durationSeconds = CMTimeGetSeconds(duration)
        try container.encode(durationSeconds, forKey: .duration)
        try container.encode(albumId, forKey: .albumId)
        try container.encodeIfPresent(artworkUrl, forKey: .artworkUrl)
        try container.encodeIfPresent(nsSong, forKey: .nsSong)
    }

    func getLocalUrl() async -> URL? {
        if let url = await self.getUrl(), isLocalURL(url) {
            return url
        }
        return nil
    }

    func getPotentialLocalUrl() -> URL? {
        guard let appMusicFolder = getMusicBoxFolder() else {
            return nil
        }

        if let ext = self.ext {
            let localFileUrl = appMusicFolder.appendingPathComponent("\(id).\(ext)")
            return localFileUrl
        }
        return nil
    }

    func getArtworkUrl() async -> URL? {
        #if DEBUG
        let timestamp = Date().timeIntervalSince1970
        print("🎨 PlaylistItem: getArtworkUrl called for '\(title)' (ID: \(id)) at \(timestamp)")
        #endif
        
        if let artworkUrl = self.artworkUrl {
            #if DEBUG
            print("🎨 PlaylistItem: Artwork URL found: \(artworkUrl.absoluteString)")
            #endif
            return artworkUrl
        }
        
        #if DEBUG
        print("🎨 PlaylistItem: No artwork URL available for '\(title)' (ID: \(id))")
        #endif
        return nil
    }

    func getUrl() async -> URL? {
        if let cachedFile = getCachedMusicFile(id: id) {
            return cachedFile
        }
        if let url = self.url {
            return url
        }
        if let songData = await CloudMusicApi().song_url_v1(id: [id]) {
            let songData = songData[0]
            self.ext = songData.type
            if self.ext == "" {
                self.ext = songData.encodeType
            }
            if let url = URL(string: songData.url.https) {
                return url
            }
        }
        print("Failed to get URL")
        return nil
    }
}
