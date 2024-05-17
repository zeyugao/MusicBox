//
//  Account.swift
//  MusicBox
//
//  Created by Elsa on 2024/4/19.
//

import AVFoundation
import Combine
import CoreImage.CIFilterBuiltins
import Foundation
import SwiftUI
import UniformTypeIdentifiers

func loadMetadata(url: URL) async -> (
    title: String, artist: String, duration: CMTime, album: String
)? {
    let asset = AVAsset(url: url)
    do {
        // Asynchronously load the needed properties
        let metadataItems = try await asset.load(.commonMetadata)
        let titleItem = metadataItems.first(where: { $0.commonKey?.rawValue == "title" })
        let artistItem = metadataItems.first(where: { $0.commonKey?.rawValue == "artist" })
        let albumItem = metadataItems.first(where: { $0.commonKey?.rawValue == "albumTitle" })

        // Fetching values using load method
        let title = try await titleItem?.load(.value) as? String ?? "Unknown"
        let artist = try await artistItem?.load(.value) as? String ?? "Unknown"
        let album = try await albumItem?.load(.value) as? String ?? "Unknown"

        let duration = try await asset.load(.duration)

        return (title, artist, duration, album)
    } catch {
        print("Error loading asset properties: \(error)")
    }
    return nil
}

func loadAsset(url: URL) async -> PlaylistItem? {
    if let metadata = await loadMetadata(url: url) {
        let newItem = PlaylistItem(
            id: 0,
            url: url, title: metadata.title, artist: metadata.artist,
            albumId: 0,
            ext: url.pathExtension,
            duration: metadata.duration, artworkUrl: nil, nsSong: nil)
        return newItem
    }
    return nil
}

struct AddArticleView: View {
    @Environment(\.dismiss) private var dismiss

    @State var title: String = ""

    var body: some View {
        VStack(spacing: 10) {
            Text("Add a new article")
                .font(.title)
            TextField(text: $title, prompt: Text("Title of the article")) {
                Text("Title")
            }

            HStack {
                Button("Cancel") {
                    // Cancel saving and dismiss.
                    dismiss()
                }
                Spacer()
                Button("Confirm") {
                    // Save the article and dismiss.
                    dismiss()
                }
            }
        }
        .padding(20)
        .frame(width: 300, height: 200)
    }
}
struct PlayerView: View {
    @EnvironmentObject var playController: PlayController

    @State var presentAddArticleSheet = false

    private func selectAndProcessAudioFile() async {
        if let url = await selectFile() {
            if let newItem = await loadAsset(url: url) {
                let _ = playController.addItemAndPlay(newItem)
                playController.startPlaying()
            }
        }
    }

    func selectFile() async -> URL? {
        let openPanel = NSOpenPanel()
        openPanel.prompt = "Select Audio File"
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.allowedContentTypes = [UTType.mp3, UTType.audio]

        let result = await openPanel.begin()

        if result == .OK, let url = openPanel.url {
            return url
        }
        return nil
    }

    private func uploadCloud() async {
        if let url = await selectFile() {
            if let metadata = await loadMetadata(url: url) {
                if let _ = await CloudMusicApi.cloud(
                    filePath: url,
                    songName: metadata.title,
                    artist: metadata.artist,
                    album: metadata.album
                ) {
                    // await CloudMusicApi.cloud_match(

                    // )
                }
            }
        }
    }

    var body: some View {
        VStack {
            Button("Select and Play") {
                Task {
                    await selectAndProcessAudioFile()
                }
            }

            Button("Upload to Cloud") {
                Task {
                    await uploadCloud()
                }
            }

            Button("Add Article") {
                presentAddArticleSheet.toggle()
            }.sheet(
                isPresented: $presentAddArticleSheet
            ) {
                AddArticleView()
            }
        }
    }
}
