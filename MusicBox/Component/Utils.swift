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

extension Task {
    func asAnyCancellable() -> AnyCancellable {
        AnyCancellable { self.cancel() }
    }
}

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
    private let url: URL?
    private let placeholder: P
    private let image: (Image) -> I

    init(
        url: URL?,
        @ViewBuilder image: @escaping (Image) -> I,
        @ViewBuilder placeholder: () -> P
    ) {
        self.url = url
        self.placeholder = placeholder()
        self.image = image
        _loader = StateObject(wrappedValue: ImageLoader(url: url))
    }

    var body: some View {
        content
            .onAppear(perform: loader.load)
            .onChange(of: url) { _, newUrl in
                loader.updateURL(newUrl)
            }
    }

    private var content: some View {
        Group {
            if let uiImage = loader.image {
                image(Image(nsImage: uiImage))
            } else if loader.isLoading {
                ZStack {
                    placeholder
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.8)
                }
            } else if loader.hasError {
                ZStack {
                    placeholder
                    Button(action: {
                        loader.retryLoad()
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(.white)
                            .font(.title2)
                            .background(Circle().fill(Color.black.opacity(0.5)).frame(width: 32, height: 32))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            } else {
                placeholder
            }
        }
    }
}

class ImageLoader: ObservableObject {
    @Published var image: NSImage?
    @Published var isLoading: Bool = false
    @Published var hasError: Bool = false

    private var url: URL?
    private var cancellable: AnyCancellable?
    private let loaderId: String = UUID().uuidString.prefix(8).lowercased()
    
    private func log(_ message: String) {
        #if DEBUG
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        print("🖼️ [\(timestamp)] ImageLoader[\(loaderId)]: \(message)")
        #endif
    }
    
    private static let fileManager = FileManager.default
    private static let urlSession = URLSession.shared
    private static let imageCache = NSCache<NSString, NSImage>()

    // Sendable wrapper for NSImage to handle Swift 6 concurrency
    private struct SendableImage: @unchecked Sendable {
        let image: NSImage?
        
        init(_ image: NSImage?) {
            self.image = image
        }
    }

    // Track ongoing download tasks to prevent duplicates
    private static var activeTasks: [String: Task<SendableImage, Never>] = [:]
    private static let taskLock = NSLock()

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
        guard let url = url, isValidImageURL(url) else {
            log("Invalid URL - \(url?.absoluteString ?? "nil")")
            hasError = true
            return
        }

        log("Checking cache for \(url.absoluteString)")

        // Check memory cache first using shared method
        if let cachedImage = Self.loadImageFromMemoryCache(url: url) {
            log("✅ Found in memory cache")
            image = cachedImage
            hasError = false
            return
        }

        log("❌ Not in memory cache, checking file cache")
        checkForSavedImage()
    }
    
    private func isValidImageURL(_ url: URL) -> Bool {
        let validSchemes = ["http", "https"]
        guard let scheme = url.scheme?.lowercased(),
              validSchemes.contains(scheme) else {
            return false
        }
        
        let pathExtension = url.pathExtension.lowercased()
        let validExtensions = ["jpg", "jpeg", "png", "gif", "webp", "bmp"]
        
        // If no extension, assume it's valid (some APIs don't use file extensions)
        return pathExtension.isEmpty || validExtensions.contains(pathExtension)
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
                    if let cachedImage = cachedImage {
                        self?.log("✅ Found valid image in file cache")
                        self?.image = cachedImage
                        self?.hasError = false
                        // Cache in memory using shared method
                        Self.cacheImageInMemory(cachedImage, for: url)
                    } else {
                        self?.log("💥 File cache data corrupted, removing and loading from network")
                        // Remove corrupted cache file
                        if let filePath = Self.getImageFilePath(for: url) {
                            try? FileManager.default.removeItem(at: filePath)
                        }
                        // Try loading from network
                        self?.load()
                    }
                }
            } else {
                await MainActor.run { [weak self] in
                    self?.log("❌ No file cache found, loading from network")
                    self?.load()
                }
            }
        }
    }

    deinit {
        cancellable?.cancel()
    }

    func updateURL(_ newURL: URL?) {
        log("updateURL called - old: \(url?.absoluteString ?? "nil"), new: \(newURL?.absoluteString ?? "nil")")
        
        // Cancel any ongoing loading
        cancellable?.cancel()
        cancellable = nil
        
        // Reset state
        isLoading = false
        hasError = false
        
        // Update URL and check cache
        url = newURL
        image = nil
        
        checkForCachedImage()
    }
    
    func load() {
        guard let url = url, isValidImageURL(url) else {
            hasError = true
            return
        }
        
        // If already loading or has image, don't start again
        guard !isLoading, image == nil else { return }
        
        loadWithRetry()
    }
    
    func retryLoad() {
        log("🔄 Manual retry requested")
        // Reset error state
        hasError = false
        image = nil
        
        // Start loading
        load()
    }
    
    private func loadWithRetry() {
        guard let url = url else { return }
        
        log("🚀 Starting loadWithRetry for \(url.absoluteString)")
        
        // If already loading or has image, don't start again
        guard !isLoading, image == nil else { return }
        
        isLoading = true
        hasError = false
        
        cancellable?.cancel()
        
        // Use the shared download mechanism with retry logic
        cancellable = Task { [weak self] in
            let downloadedImage = await Self.downloadAndCacheImage(url: url)
            
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                
                self.isLoading = false
                
                if let downloadedImage = downloadedImage {
                    self.log("✅ Successfully loaded image via shared task")
                    self.image = downloadedImage.image
                    self.hasError = false
                } else {
                    self.log("❌ Failed to load image via shared task")
                    self.hasError = true
                }
            }
        }.asAnyCancellable()
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
        return await downloadAndCacheImage(url: url)?.image
    }

    private static func downloadAndCacheImage(url: URL) async -> SendableImage? {
        let urlString = url.absoluteString

        // Check if there's already a task for this URL
        let existingTask = taskLock.withLock {
            return activeTasks[urlString]
        }

        if let existingTask = existingTask {
            // Wait for the existing task to complete
            return await existingTask.value
        }

        // Create new download task with retry logic
        let downloadTask = Task<SendableImage, Never> {
            let image = await downloadImageWithRetry(url: url)
            return SendableImage(image)
        }

        // Store the task
        taskLock.withLock {
            activeTasks[urlString] = downloadTask
        }

        // Wait for completion and cleanup
        let result = await downloadTask.value
        
        _ = taskLock.withLock {
            activeTasks.removeValue(forKey: urlString)
        }

        return result
    }

    private static func downloadImageWithRetry(url: URL, maxRetries: Int = 3) async -> NSImage? {
        for attempt in 1...maxRetries {
            do {
                let data = try await downloadImageData(from: url)
                guard !data.isEmpty, let image = NSImage(data: data) else {
                    throw URLError(.badServerResponse)
                }

                // Cache in memory
                cacheImageInMemory(image, for: url, cost: data.count)

                // Save to file cache in background
                Task {
                    await saveImageToFileCache(data: data, url: url)
                }

                return image
            } catch {
                if attempt < maxRetries {
                    let delay = TimeInterval(attempt) * 1.0 // 1s, 2s, 3s
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        return nil
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

        let asset = AVURLAsset(url: url)
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
