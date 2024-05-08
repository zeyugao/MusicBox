//
//  PlayList.swift
//  MusicBox
//
//  Created by Elsa on 2024/4/19.
//

import Cocoa
import CoreMedia
import Foundation
import SwiftUI
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

class PlaylistDetailModel: ObservableObject {
    @Published var songs: [CloudMusicApi.Song]?

    func updatePlaylistDetail(id: UInt64) async {
        if let playlist = await CloudMusicApi.playlist_detail(id: id) {
            let trackIds = playlist.trackIds
            let tracks = playlist.tracks

            if trackIds.count == tracks.count {
                DispatchQueue.main.async {
                    self.songs = tracks
                }
            } else {
                if let playlist = await CloudMusicApi.song_detail(ids: trackIds) {
                    DispatchQueue.main.async {
                        self.songs = playlist
                    }
                }
            }
        }
    }
}

func loadItem(song: CloudMusicApi.Song, songData: CloudMusicApi.SongData) async -> PlaylistItem? {
    let fileManager = FileManager.default
    guard
        let musicFolder = fileManager.urls(
            for: .musicDirectory, in: .userDomainMask
        ).first
    else {
        return nil
    }
    let appMusicFolder = musicFolder.appendingPathComponent("MusicBox")

    print("appMusicFolder: \(appMusicFolder)")

    // Create the directory if it does not exist
    if !fileManager.fileExists(atPath: appMusicFolder.path) {
        do {
            try fileManager.createDirectory(at: appMusicFolder, withIntermediateDirectories: true)
        } catch {
            print("Failed to create directory: \(error)")
            return nil
        }
    }

    // Define the local file path
    let localFileUrl = appMusicFolder.appendingPathComponent(
        "\(songData.id).\(songData.type)")

    // Check if file already exists
    if fileManager.fileExists(atPath: localFileUrl.path) {
        print("File already exists, no need to download.")
    } else {
        // Download the file
        guard let songDownloadUrl = URL(string: songData.url.https) else {
            return nil
        }

        do {
            // TODO: Streaming
            print("Downloading file from \(songData.url) to \(localFileUrl)")

            let (data, _) = try await URLSession.shared.data(from: songDownloadUrl)
            try data.write(to: localFileUrl)
        } catch {
            print("Error downloading or saving the file: \(error)")
            return nil
        }
    }

    print("Playing  \(localFileUrl)")

    let newItem = PlaylistItem(
        id: String(songData.id),
        url: localFileUrl,
        title: song.name,
        artist: song.ar.map(\.name).joined(separator: ", "),
        ext: songData.type,
        duration: CMTime(value: songData.time, timescale: 1000)
    )
    return newItem
}

struct PlayListView: View {
    @EnvironmentObject var playController: PlayController
    @StateObject var model = PlaylistDetailModel()

    @State private var selectedItem: CloudMusicApi.Song.ID?
    @State private var sortOrder = [KeyPathComparator(\CloudMusicApi.Song.name)]

    var neteasePlaylist: CloudMusicApi.PlayListItem?

    let currencyStyle = Decimal.FormatStyle.Currency(code: "USD")

    var body: some View {
        if let songs = model.songs {
            Table(of: CloudMusicApi.Song.self, selection: $selectedItem, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name)
                TableColumn("Artist") { song in
                    Text(song.ar.map(\.name).joined(separator: ", "))
                }
                TableColumn("Ablum", value: \.al.name)
                TableColumn("Duration") { song in
                    let ret = song.parseDuration()
                    Text(String(format: "%02d:%02d", ret.minute, ret.second))
                }.width(max: 60)
            } rows: {
                ForEach(songs) { song in
                    TableRow(song)
                        .contextMenu {
                            Button("Play") {
                                Task {
                                    if let songData = await CloudMusicApi.song_download_url(
                                        id: song.id),
                                        let newItem = await loadItem(song: song, songData: songData)
                                    {
                                        playController.sampleBufferPlayer.insertItem(newItem, at: 0)
                                        playController.togglePlayPause()
                                    }
                                }
                            }
                        }
                }
            }
            .navigationTitle(neteasePlaylist?.name ?? "Playlist")
            .onChange(of: neteasePlaylist) {
                if let _ = neteasePlaylist?.id {
                    model.songs = nil
                }
            }
            .onChange(of: sortOrder) { _, sortOrder in
                print(sortOrder)
                print(sortOrder.count)
            }
        } else {
            HStack(alignment: .center, spacing: 4) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(0.5)
                Text("Loading")
            }
            .onAppear {
                Task {
                    if let id = neteasePlaylist?.id {
                        await model.updatePlaylistDetail(id: id)
                    }
                }
            }
            .onChange(of: neteasePlaylist) {
                Task {
                    if let id = neteasePlaylist?.id {
                        await model.updatePlaylistDetail(id: id)
                    }
                }
            }
        }
    }
}
