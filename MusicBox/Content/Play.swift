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

func loadAsset(url: URL) async -> PlaylistItem? {
    let asset = AVAsset(url: url)
    do {
        // Asynchronously load the needed properties
        let metadataItems = try await asset.load(.commonMetadata)
        let titleItem = metadataItems.first(where: { $0.commonKey?.rawValue == "title" })
        let artistItem = metadataItems.first(where: { $0.commonKey?.rawValue == "artist" })

        // Fetching values using load method
        let title = try await titleItem?.load(.value) as? String ?? "Unknown"
        let artist = try await artistItem?.load(.value) as? String ?? "Unknown"

        let duration = try await asset.load(.duration)

        let newItem = PlaylistItem(
            id: 0,
            url: url, title: title, artist: artist,
            albumId: 0,
            ext: url.pathExtension,
            duration: duration, artworkUrl: nil)
        return newItem
    } catch {
        print("Error loading asset properties: \(error)")
    }
    return nil
}
struct PlayerView: View {
    @EnvironmentObject var playController: PlayController

    private func selectAndProcessAudioFile() async {
        let openPanel = NSOpenPanel()
        openPanel.prompt = "Select Audio File"
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.allowedContentTypes = [UTType.mp3, UTType.audio]

        let result = await openPanel.begin()
        if result == .OK, let url = openPanel.url {
            if let newItem = await loadAsset(url: url) {
                let _ = playController.addItemAndPlay(newItem)
                playController.startPlaying()
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
        }
    }
}
