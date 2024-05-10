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
struct PlaylistItem: Identifiable {
    let id: String

    /// URL of the local file containing the track's audio.
    let url: URL

    /// An error that prevents the track from playing.
    let error: Error?

    /// The title of the track.
    let title: String

    /// The artist heard on the track.
    let artist: String

    /// The ext name
    let ext: String

    /// The duration of the audio file.
    let duration: CMTime

    /// Initializes a valid item.
    init(id: String, url: URL, title: String, artist: String, ext: String, duration: CMTime) {
        self.id = id
        self.url = url
        self.title = title
        self.artist = artist
        self.ext = ext
        self.duration = duration
        self.error = nil
    }

    func getUrl() -> URL? {
        return runBlocking {
            return await getUrlForPlayer()
        }
    }

    func getUrlForPlayer() async -> URL? {
        if isLocalURL(url) {
            return self.url
        } else {
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

            // Define the local file path
            let localFileUrl = appMusicFolder.appendingPathComponent(
                "\(self.id).\(self.ext)")

            // Check if file already exists
            if fileManager.fileExists(atPath: localFileUrl.path) {
                print("File already exists, no need to download.")
            } else {
                do {
                    // TODO: Streaming
                    print("Downloading file from \(self.url) to \(localFileUrl)")

                    let (data, _) = try await URLSession.shared.data(from: self.url)
                    try data.write(to: localFileUrl)
                } catch {
                    print("Error downloading or saving the file: \(error)")
                    return nil
                }
            }
            return localFileUrl
        }
    }
}
