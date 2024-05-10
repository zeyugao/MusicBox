//
//  PlayList.swift
//  MusicBox
//
//  Created by Elsa on 2024/4/19.
//

import Cocoa
import CoreImage.CIFilterBuiltins
import CoreMedia
import Foundation
import SwiftUI
import UniformTypeIdentifiers

class PlaylistDetailModel: ObservableObject {
    @Published var songs: [CloudMusicApi.Song]?
    var curId: UInt64?

    func updatePlaylistDetail(id: UInt64) async {
        if let playlist = await CloudMusicApi.playlist_detail(id: id) {
            let trackIds = playlist.trackIds
            let tracks = playlist.tracks

            if let cur = curId, cur != id {
                return
            }

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
    guard let url = URL(string: songData.url.https) else { return nil }
    let newItem = PlaylistItem(
        id: String(songData.id),
        url: url,
        title: song.name,
        artist: song.ar.map(\.name).joined(separator: ", "),
        ext: songData.type,
        duration: CMTime(value: songData.time, timescale: 1000),
        artworkUrl: URL(string: song.al.picUrl.https)
    )
    return newItem
}

func loadItem(song: CloudMusicApi.Song) -> PlaylistItem {
    let newItem = PlaylistItem(
        id: String(song.id),
        url: nil,
        title: song.name,
        artist: song.ar.map(\.name).joined(separator: ", "),
        ext: nil,
        duration: CMTime(value: song.dt, timescale: 1000),
        artworkUrl: URL(string: song.al.picUrl.https)
    )
    return newItem
}

struct TableContextMenu: View {
    @EnvironmentObject var playController: PlayController

    var song: CloudMusicApi.Song

    init(song: CloudMusicApi.Song) {
        self.song = song
    }

    var body: some View {
        Button("Play") {
            let newItem = loadItem(song: song)
            let _ = playController.addItemAndPlay(newItem)
            playController.startPlaying()
        }
        Button("Add to Playlist") {
            let newItem = loadItem(song: song)
            let _ = playController.addItemToPlaylist(newItem)
        }
    }
}

struct PlayAllButton: View {
    @EnvironmentObject var playController: PlayController

    var songs: [CloudMusicApi.Song]

    var body: some View {
        Button(action: {
            for song in songs {
                let newItem = loadItem(song: song)
                let _ = playController.addItemToPlaylist(newItem)
            }
            playController.startPlaying()
        }) {
            Image(systemName: "play.circle")
                .resizable()
                .frame(width: 16, height: 16)
        }
        .buttonStyle(BorderlessButtonStyle())
        .help("Play All")
    }
}

struct PlayListView: View {
    @StateObject var model = PlaylistDetailModel()

    @State private var selectedItem: CloudMusicApi.Song.ID?
    @State private var sortOrder = [KeyPathComparator(\CloudMusicApi.Song.name)]

    @State private var loadingTask: Task<Void, Never>? = nil

    var neteasePlaylist: CloudMusicApi.PlayListItem?

    let currencyStyle = Decimal.FormatStyle.Currency(code: "USD")

    var body: some View {
        Table(of: CloudMusicApi.Song.self, selection: $selectedItem, sortOrder: $sortOrder) {
            TableColumn("Name") { song in
                HStack {
                    Text(song.name)

                    if let _ = song.pc {
                        Spacer()
                        Image(systemName: "cloud")
                            .resizable()
                            .frame(width: 18, height: 12)
                            .help("Cloud")
                    } else {
                        if song.fee == .vip
                            || song.fee == .album
                        {
                            Spacer()
                            Image(systemName: "dollarsign.circle")
                                .resizable()
                                .frame(width: 16, height: 16)
                                .help("Need buy")
                                .padding(.horizontal, 1)
                                .frame(width: 18, height: 16)
                        } else if song.fee == .trial {
                            Spacer()
                            Image(systemName: "gift")
                                .resizable()
                                .frame(width: 16, height: 16)
                                .help("Trial")
                                .padding(.horizontal, 1)
                                .frame(width: 18, height: 16)
                        }
                    }
                }
            }
            TableColumn("Artist") { song in
                Text(song.ar.map(\.name).joined(separator: ", "))
            }
            TableColumn("Ablum", value: \.al.name)
            TableColumn("Duration") { song in
                let ret = song.parseDuration()
                Text(String(format: "%02d:%02d", ret.minute, ret.second))
            }.width(max: 60)
        } rows: {
            if let songs = model.songs {
                ForEach(songs) { song in
                    TableRow(song)
                        .contextMenu {
                            TableContextMenu(song: song)
                        }
                }
            }
        }
        .navigationTitle(neteasePlaylist?.name ?? "Playlist")
        .toolbar {
            PlayAllButton(songs: model.songs ?? [])
        }
        .onChange(of: neteasePlaylist) {
            if let id = neteasePlaylist?.id {
                model.songs = nil

                model.curId = id
                loadingTask?.cancel()
                loadingTask = Task {
                    await model.updatePlaylistDetail(id: id)
                }
            }
        }
        .onChange(of: sortOrder) { _, sortOrder in
            print(sortOrder)
            print(sortOrder.count)
        }
        .onAppear {
            loadingTask?.cancel()
            loadingTask = Task {
                if let id = neteasePlaylist?.id {
                    model.curId = id
                    await model.updatePlaylistDetail(id: id)
                }
            }
        }
        .onDisappear {
            loadingTask?.cancel()
        }
    }
}
