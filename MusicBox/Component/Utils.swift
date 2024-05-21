//
//  LoadingIndicator.swift
//  MusicBox
//
//  Created by Elsa on 2024/5/19.
//

import Combine
import CryptoKit
import Foundation
import SwiftUI

struct LoadingIndicatorView: View {
    var body: some View {
        ProgressView()
            .colorInvert()
            .progressViewStyle(CircularProgressViewStyle())
            .controlSize(.small)
            .frame(width: 48, height: 48)
            .background(Color.black.opacity(0.75))
            .clipShape(RoundedRectangle(cornerRadius: 10))
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

    init(url: URL?) {
        self.url = url
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
        let file = getImagePath()

        guard let file = file, fileManager.fileExists(atPath: file.path) else { return }

        if let data = try? Data(contentsOf: file), let img = NSImage(data: data) {
            image = img
        }
    }

    deinit {
        cancellable?.cancel()
    }

    func load() {
        guard image == nil, cancellable == nil, let url = url else { return }

        cancellable = URLSession.shared.dataTaskPublisher(for: url)
            .map { $0.data }
            .replaceError(with: nil)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data in
                if let data = data {
                    self?.image = NSImage(data: data)
                    self?.saveImage(data: data)
                }
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
