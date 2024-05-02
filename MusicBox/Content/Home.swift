//
//  Home.swift
//  MusicBox
//
//  Created by Elsa on 2024/4/19.
//

import AVFoundation
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct HomeContentView: View {

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
            let asset = AVAsset(url: url)
            do {
                // Asynchronously load the needed properties
                let metadataItems = try await asset.load(.commonMetadata)
                let titleItem = metadataItems.first(where: { $0.commonKey?.rawValue == "title" })
                let artistItem = metadataItems.first(where: { $0.commonKey?.rawValue == "artist" })

                // Fetching values using load method
                var title = try await titleItem?.load(.value) as? String ?? "Unknown"
                var artist = try await artistItem?.load(.value) as? String ?? "Unknown"

                let duration = try await asset.load(.duration)

                let newItem = PlaylistItem(
                    url: url, title: title, artist: artist, ext: url.pathExtension,
                    duration: duration)
                playController.sampleBufferPlayer.insertItem(newItem, at: 0)
            } catch {
                // Handle errors, possibly using an error presenting mechanism in your UI.
                print("Error loading asset properties: \(error)")
            }
        }
    }
    var body: some View {
        VStack {
            Text("Home Screen")

            Button(action: {
                Task {
                    await self.selectAndProcessAudioFile()
                }
            }) {
                Text("Add to Playlist")
            }

            Button(action: {
                Task {
                    let api = NeteaseMusicAPI()

                    do {
                        // let result = try await api.loginQrKey()
                        print(try await api.loginQrKey())
                        print(try await api.nuserAccount())
                    } catch {
                        print("Error")
                        print(error)
                    }
                }
                //                Task  {
                // CloudMusicApi.login_qr_key()
                //                    print(res)
                //                }
            }) {
                Text("Fetch Key")
            }
        }
    }
}

#Preview {
    HomeContentView()
}
