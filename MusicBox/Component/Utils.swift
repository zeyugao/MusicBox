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

        // Check memory cache first using shared method
        if let cachedImage = Self.loadImageFromMemoryCache(url: url) {
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

    private func checkForSavedImage() {
        guard let url = url else { return }

        // Use shared async method but adapt for sync context
        Task { [weak self] in
            if let imageData = await Self.loadImageFromFileCache(url: url) {
                await MainActor.run { [weak self] in
                    let cachedImage = NSImage(data: imageData)
                    self?.image = cachedImage
                    // Cache in memory using shared method
                    if let cachedImage = cachedImage {
                        Self.cacheImageInMemory(cachedImage, for: url)
                    }
                }
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
        let isAlreadyDownloading = Self.downloadLock.withLock {
            let isDownloading = Self.activeDownloads.contains(urlString)
            if !isDownloading {
                Self.activeDownloads.insert(urlString)
            }
            return isDownloading
        }

        if isAlreadyDownloading {
            // Already downloading, try again in a moment
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.checkForCachedImage()
            }
            return
        }

        cancellable = Self.urlSession.dataTaskPublisher(for: url)
            .map { $0.data }
            .replaceError(with: nil)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data in
                defer {
                    _ = Self.downloadLock.withLock {
                        Self.activeDownloads.remove(urlString)
                    }
                }

                guard let self = self, let data = data, let img = NSImage(data: data) else {
                    return
                }

                self.image = img

                // Use shared methods for caching
                Self.cacheImageInMemory(img, for: url, cost: data.count)

                // Save to file cache in background using shared method
                Task {
                    await Self.saveImageToFileCache(data: data, url: url)
                }
            }
    }

    // MARK: - Shared utility methods
    private static func md5Hash(string: String) -> String {
        let md5Data = Insecure.MD5.hash(data: Data(string.utf8))
        return md5Data.map { String(format: "%02hhx", $0) }.joined()
    }

    private static func getImageFilePath(for url: URL) -> URL? {
        guard let cacheDir = imageCacheDirectory else { return nil }
        let hash = md5Hash(string: url.absoluteString)
        return cacheDir.appendingPathComponent("\(hash).dat")
    }

    private static func loadImageFromMemoryCache(url: URL) -> NSImage? {
        let cacheKey = NSString(string: url.absoluteString)
        return imageCache.object(forKey: cacheKey)
    }

    private static func cacheImageInMemory(_ image: NSImage, for url: URL, cost: Int = 0) {
        let cacheKey = NSString(string: url.absoluteString)
        imageCache.setObject(image, forKey: cacheKey, cost: cost)
    }

    private static func loadImageFromFileCache(url: URL) async -> Data? {
        guard let file = getImageFilePath(for: url),
            fileManager.fileExists(atPath: file.path)
        else { return nil }

        return await withCheckedContinuation { continuation in
            Task {
                do {
                    let data = try Data(contentsOf: file)
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func saveImageToFileCache(data: Data, url: URL) async {
        guard let file = getImageFilePath(for: url) else { return }

        do {
            try data.write(to: file)
        } catch {
            // Silently fail - memory cache is sufficient for most cases
        }
    }

    private static func downloadImageData(from url: URL) async throws -> Data {
        let (data, _) = try await urlSession.data(from: url)
        return data
    }

    // MARK: - Static async method for NowPlayingCenter
    static func loadImageAsync(from url: URL) async -> NSImage? {
        // Ensure cache is configured
        _ = Self.cacheConfigured

        // Check memory cache first
        if let cachedImage = loadImageFromMemoryCache(url: url) {
            return cachedImage
        }

        // Check file cache
        if let imageData = await loadImageFromFileCache(url: url),
            let image = NSImage(data: imageData)
        {
            // Cache in memory for faster access
            cacheImageInMemory(image, for: url)
            return image
        }

        // Download from network with duplicate prevention
        return await downloadAndCacheImage(url: url)
    }

    private static func downloadAndCacheImage(url: URL) async -> NSImage? {
        let urlString = url.absoluteString

        // Check if already downloading
        let isAlreadyDownloading = downloadLock.withLock {
            let isDownloading = activeDownloads.contains(urlString)
            if !isDownloading {
                activeDownloads.insert(urlString)
            }
            return isDownloading
        }

        if isAlreadyDownloading {
            // Wait a bit and try cache again
            try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1 seconds
            return loadImageFromMemoryCache(url: url)
        }

        defer {
            _ = downloadLock.withLock {
                activeDownloads.remove(urlString)
            }
        }

        do {
            let data = try await downloadImageData(from: url)
            guard let image = NSImage(data: data) else { return nil }

            // Cache in memory
            cacheImageInMemory(image, for: url, cost: data.count)

            // Save to file cache in background
            Task {
                await saveImageToFileCache(data: data, url: url)
            }

            return image
        } catch {
            return nil
        }
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
