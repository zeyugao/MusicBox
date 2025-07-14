//
//  LoadingIndicator.swift
//  MusicBox
//
//  Created by Elsa on 2024/5/19.
//

import AVFoundation
import Combine
import CryptoKit
import Foundation
import SwiftUI

struct LoadingIndicatorView: View {
    @State private var isVisible = false
    @State private var delayTask: Task<Void, Never>?

    var body: some View {
        Group {
            if isVisible {
                HStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .accentColor))
                        .controlSize(.small)
                        .frame(width: 16, height: 16)

                    Text("Loading...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .onAppear {
            delayTask = Task {
                try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds
                await MainActor.run {
                    isVisible = true
                }
            }
        }
        .onDisappear {
            delayTask?.cancel()
            delayTask = nil
            isVisible = false
        }
    }
}

struct AsyncImageWithCache<I: View, P: View>: View {
    @StateObject private var loader: ImageLoader
    private let placeholder: P
    private let image: (Image) -> I

    init(
        url: URL?,
        @ViewBuilder image: @escaping (Image) -> I,
        @ViewBuilder placeholder: () -> P
    ) {
        self.placeholder = placeholder()
        self.image = image
        _loader = StateObject(wrappedValue: ImageLoader(url: url))
    }

    var body: some View {
        content
            .onAppear(perform: loader.load)
    }

    private var content: some View {
        Group {
            if let uiImage = loader.image {
                image(Image(nsImage: uiImage))
            } else {
                placeholder
            }
        }
    }
}

class ImageLoader: ObservableObject {
    @Published var image: NSImage?

    private let url: URL?
    private var cancellable: AnyCancellable?
    private static let fileManager = FileManager.default
    private static let urlSession = URLSession.shared
    private static let imageCache = NSCache<NSString, NSImage>()

    // Track ongoing downloads to prevent duplicates
    private static var activeDownloads = Set<String>()
    private static let downloadLock = NSLock()

    // Configure cache once
    private static let cacheConfigured: Void = {
        imageCache.countLimit = 100  // Limit to 100 images
        imageCache.totalCostLimit = 50 * 1024 * 1024  // 50MB memory limit
        return ()
    }()

    init(url: URL?) {
        self.url = url
        _ = Self.cacheConfigured  // Ensure cache is configured
        checkForCachedImage()
    }

    private func checkForCachedImage() {
        guard let url = url else { return }

        let cacheKey = NSString(string: url.absoluteString)
        if let cachedImage = Self.imageCache.object(forKey: cacheKey) {
            image = cachedImage
            return
        }

        checkForSavedImage()
    }

    private static var imageCacheDirectory: URL? = {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let imageCachePath = documentsDir.appendingPathComponent("CacheImage")

        // Create directory once and reuse
        do {
            try FileManager.default.createDirectory(
                at: imageCachePath, withIntermediateDirectories: true)
            return imageCachePath
        } catch {
            return nil
        }
    }()

    private func getImagePath() -> URL? {
        guard let url = url,
            let cacheDir = Self.imageCacheDirectory
        else { return nil }

        let hash = md5(string: url.absoluteString)
        return cacheDir.appendingPathComponent("\(hash).dat")
    }

    private func checkForSavedImage() {
        guard let file = getImagePath() else { return }

        // Avoid file system check if we can
        guard Self.fileManager.fileExists(atPath: file.path) else { return }

        // Load image data in background to avoid blocking UI
        Task { [weak self, file] in
            guard let data = try? Data(contentsOf: file) else { return }

            // Create image on main thread since NSImage is not Sendable
            let img = NSImage(data: data)
            guard let img = img else { return }

            let imageSize = data.count
            let urlString = self?.url?.absoluteString

            DispatchQueue.main.async { [weak self] in
                self?.image = img
            }

            // Cache in memory for faster access
            if let urlString = urlString {
                let cacheKey = NSString(string: urlString)
                Self.imageCache.setObject(img, forKey: cacheKey, cost: imageSize)
            }
        }
    }

    deinit {
        cancellable?.cancel()
    }

    func load() {
        guard image == nil, cancellable == nil, let url = url else { return }

        let urlString = url.absoluteString

        // Check if this URL is already being downloaded
        Self.downloadLock.lock()
        defer { Self.downloadLock.unlock() }

        if Self.activeDownloads.contains(urlString) {
            // Already downloading, try again in a moment
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.checkForCachedImage()
            }
            return
        }

        Self.activeDownloads.insert(urlString)

        cancellable = Self.urlSession.dataTaskPublisher(for: url)
            .map { $0.data }
            .replaceError(with: nil)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data in
                defer {
                    Self.downloadLock.lock()
                    Self.activeDownloads.remove(urlString)
                    Self.downloadLock.unlock()
                }

                guard let self = self, let data = data, let img = NSImage(data: data) else {
                    return
                }

                self.image = img

                // Save and cache in background
                let urlString = url.absoluteString
                let imageSize = data.count
                Task { [weak self] in
                    self?.saveImage(data: data)

                    // Cache in memory for faster access (already on main thread)
                    let cacheKey = NSString(string: urlString)
                    Self.imageCache.setObject(img, forKey: cacheKey, cost: imageSize)
                }
            }
    }

    private func saveImage(data: Data) {
        guard let file = getImagePath() else { return }

        // Save image in background to avoid blocking
        do {
            try data.write(to: file)
        } catch {
            // Silently fail - memory cache is sufficient for most cases
        }
    }

    private func getDocumentsDirectory() -> URL {
        ImageLoader.fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func md5(string: String) -> String {
        let md5Data = Insecure.MD5.hash(data: Data(string.utf8))
        return md5Data.map { String(format: "%02hhx", $0) }.joined()
    }
}

// MARK: - Metadata Loading
class MetadataLoader {
    private static let metadataCache = NSCache<NSString, MetadataResult>()

    class MetadataResult {
        let title: String
        let artist: String
        let duration: CMTime
        let album: String

        init(title: String, artist: String, duration: CMTime, album: String) {
            self.title = title
            self.artist = artist
            self.duration = duration
            self.album = album
        }
    }

    static func loadMetadata(url: URL) async -> MetadataResult? {
        let cacheKey = NSString(string: url.absoluteString)

        // Check cache first
        if let cached = metadataCache.object(forKey: cacheKey) {
            return cached
        }

        let asset = AVAsset(url: url)
        do {
            // Load all needed properties in parallel
            async let metadataItems = asset.load(.commonMetadata)
            async let duration = asset.load(.duration)

            let metadata = try await metadataItems
            let assetDuration = try await duration

            let titleItem = metadata.first(where: { $0.commonKey?.rawValue == "title" })
            let artistItem = metadata.first(where: { $0.commonKey?.rawValue == "artist" })
            let albumItem = metadata.first(where: { $0.commonKey?.rawValue == "albumTitle" })

            // Load metadata values in parallel
            async let title = titleItem?.load(.value) as? String ?? "Unknown"
            async let artist = artistItem?.load(.value) as? String ?? "Unknown"
            async let album = albumItem?.load(.value) as? String ?? "Unknown"

            let result = MetadataResult(
                title: try await title,
                artist: try await artist,
                duration: assetDuration,
                album: try await album
            )

            // Cache the result
            metadataCache.setObject(result, forKey: cacheKey)

            return result
        } catch {
            print("Error loading asset properties: \(error)")
        }
        return nil
    }
}

// MARK: - Legacy Function Support
func loadMetadata(url: URL) async -> (
    title: String, artist: String, duration: CMTime, album: String
)? {
    guard let result = await MetadataLoader.loadMetadata(url: url) else { return nil }
    return (result.title, result.artist, result.duration, result.album)
}
