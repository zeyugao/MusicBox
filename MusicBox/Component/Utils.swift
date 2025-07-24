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
    private var retryCount: Int = 0
    private let maxRetries: Int = 3
    private let retryDelay: TimeInterval = 1.0
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
        retryCount = 0
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
        // Reset retry count and error state
        retryCount = 0
        hasError = false
        image = nil
        
        // Start loading
        load()
    }
    
    private func loadWithRetry() {
        guard let url = url else { return }
        
        let urlString = url.absoluteString
        log("🚀 Starting loadWithRetry for \(urlString) (attempt \(retryCount + 1)/\(maxRetries + 1))")
        
        // Check if this URL is already being downloaded
        let isAlreadyDownloading = Self.downloadLock.withLock {
            let isDownloading = Self.activeDownloads.contains(urlString)
            if !isDownloading {
                Self.activeDownloads.insert(urlString)
            }
            return isDownloading
        }

        if isAlreadyDownloading {
            log("⏳ URL already downloading, waiting...")
            // Already downloading, wait longer and check cache
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                // Check if image appeared in cache while waiting
                if let cachedImage = Self.loadImageFromMemoryCache(url: url) {
                    self.log("✅ Found image in cache after waiting")
                    self.image = cachedImage
                    self.hasError = false
                } else {
                    // Still not in cache, try to load again if not already loading
                    if !self.isLoading {
                        self.log("⚠️ Still not in cache after waiting, retrying...")
                        self.loadWithRetry()
                    }
                }
            }
            return
        }
        
        isLoading = true
        hasError = false
        cancellable?.cancel()

        cancellable = Self.urlSession.dataTaskPublisher(for: url)
            .timeout(.seconds(10), scheduler: DispatchQueue.global())
            .map { $0.data }
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    defer {
                        _ = Self.downloadLock.withLock {
                            Self.activeDownloads.remove(urlString)
                        }
                    }
                    
                    guard let self = self else { return }
                    
                    switch completion {
                    case .finished:
                        self.isLoading = false
                        self.retryCount = 0
                    case .failure(let error):
                        self.isLoading = false
                        self.log("💥 Network error: \(error.localizedDescription)")
                        
                        if self.retryCount < self.maxRetries {
                            self.retryCount += 1
                            let delay = self.retryDelay * Double(self.retryCount)
                            self.log("🔄 Retrying in \(delay)s (attempt \(self.retryCount + 1)/\(self.maxRetries + 1))")
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                                self.loadWithRetry()
                            }
                        } else {
                            self.log("❌ Max retries exceeded, giving up")
                            self.hasError = true
                            self.retryCount = 0
                        }
                    }
                },
                receiveValue: { [weak self] data in
                    guard let self = self else { return }
                    
                    self.log("📦 Received \(data.count) bytes")
                    
                    guard !data.isEmpty, let img = NSImage(data: data) else {
                        self.log("💥 Invalid image data (\(data.count) bytes), retrying...")
                        // Invalid data, treat as error and potentially retry
                        if self.retryCount < self.maxRetries {
                            self.retryCount += 1
                            let delay = self.retryDelay * Double(self.retryCount)
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                                self.loadWithRetry()
                            }
                        } else {
                            self.log("❌ Max retries exceeded for invalid data")
                            self.hasError = true
                            self.retryCount = 0
                        }
                        return
                    }

                    self.log("✅ Successfully loaded image (\(Int(img.size.width))x\(Int(img.size.height)))")
                    self.image = img
                    self.hasError = false

                    // Use shared methods for caching
                    Self.cacheImageInMemory(img, for: url, cost: data.count)

                    // Save to file cache in background using shared method
                    Task {
                        await Self.saveImageToFileCache(data: data, url: url)
                    }
                }
            )
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
