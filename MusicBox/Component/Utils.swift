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
    private let fileManager = FileManager.default
    private static let urlSession = URLSession.shared
    private static let imageCache = NSCache<NSString, NSImage>()

    init(url: URL?) {
        self.url = url
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

    private func getImagePath() -> URL? {
        guard let url = url else { return nil }
        let hash = md5(string: url.absoluteString)

        let imageCachePath = getDocumentsDirectory().appendingPathComponent("CacheImage")

        if !fileManager.fileExists(atPath: imageCachePath.path) {
            do {
                try fileManager.createDirectory(
                    at: imageCachePath, withIntermediateDirectories: true)
            } catch {
                print("Failed to create directory: \(error)")
                return nil
            }
        }

        return imageCachePath.appendingPathComponent("\(hash).dat")
    }

    private func checkForSavedImage() {
        guard let file = getImagePath(),
            fileManager.fileExists(atPath: file.path),
            let data = try? Data(contentsOf: file),
            let img = NSImage(data: data)
        else { return }

        image = img

        // Cache in memory for faster access
        if let url = url {
            let cacheKey = NSString(string: url.absoluteString)
            Self.imageCache.setObject(img, forKey: cacheKey)
        }
    }

    deinit {
        cancellable?.cancel()
    }

    func load() {
        guard image == nil, cancellable == nil, let url = url else { return }

        cancellable = Self.urlSession.dataTaskPublisher(for: url)
            .map { $0.data }
            .replaceError(with: nil)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data in
                guard let self = self, let data = data, let img = NSImage(data: data) else {
                    return
                }

                self.image = img
                self.saveImage(data: data)

                // Cache in memory for faster access
                let cacheKey = NSString(string: url.absoluteString)
                Self.imageCache.setObject(img, forKey: cacheKey)
            }
    }

    private func saveImage(data: Data) {
        let file = getImagePath()

        guard let file = file else { return }

        do {
            try data.write(to: file)
        } catch {
            print("Error saving image data to \(file): \(error)")
        }
    }

    private func getDocumentsDirectory() -> URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
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
