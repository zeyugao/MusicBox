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
    var originalSongs: [CloudMusicApi.Song]?
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
                self.originalSongs = tracks
                DispatchQueue.main.async {
                    self.songs = tracks
                }
            } else {
                if let playlist = await CloudMusicApi.song_detail(ids: trackIds) {
                    self.originalSongs = playlist
                    DispatchQueue.main.async {
                        self.songs = playlist
                    }
                }
            }
        }
    }

    func applySorting(by sortOrder: [KeyPathComparator<CloudMusicApi.Song>]) {
        guard let originalSongs = originalSongs else { return }
        songs = originalSongs.sorted(using: sortOrder)
    }

    func resetSorting() {
        songs = originalSongs
    }
}

func loadItem(song: CloudMusicApi.Song, songData: CloudMusicApi.SongData) async -> PlaylistItem? {
    guard let url = URL(string: songData.url.https) else { return nil }
    let newItem = PlaylistItem(
        id: songData.id,
        url: url,
        title: song.name,
        artist: song.ar.map(\.name).joined(separator: ", "),
        albumId: song.al.id,
        ext: songData.type,
        duration: CMTime(value: songData.time, timescale: 1000),
        artworkUrl: URL(string: song.al.picUrl.https)
    )
    return newItem
}

func loadItem(song: CloudMusicApi.Song) -> PlaylistItem {
    let newItem = PlaylistItem(
        id: song.id,
        url: nil,
        title: song.name,
        artist: song.ar.map(\.name).joined(separator: ", "),
        albumId: song.al.id,
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
            let newItems = songs.map { song in
                loadItem(song: song)
            }
            let _ = playController.replacePlaylist(newItems, continuePlaying: false)
            playController.startPlaying()
        }) {
            Image(systemName: "play.circle")
                .resizable()
                .frame(width: 16, height: 16)
        }
        .buttonStyle(BorderlessButtonStyle())
        .help("Play All")

        Button(action: {
            let newItems = songs.map { song in
                loadItem(song: song)
            }
            let _ = playController.addItemsToPlaylist(newItems)
            playController.startPlaying()
        }) {
            Image(systemName: "plus.circle")
                .resizable()
                .frame(width: 16, height: 16)
        }
        .buttonStyle(BorderlessButtonStyle())
        .help("Add All to Playlist")
    }
}

struct PlayListView: View {
    @StateObject var model = PlaylistDetailModel()

    @State private var selectedItem: CloudMusicApi.Song.ID?
    @State private var sortOrder = [KeyPathComparator<CloudMusicApi.Song>]()
    @State private var loadingTask: Task<Void, Never>? = nil
    @State private var isSorted = false

    var neteasePlaylist: CloudMusicApi.PlayListItem?

    let currencyStyle = Decimal.FormatStyle.Currency(code: "USD")

    var body: some View {
        Table(
            of: CloudMusicApi.Song.self,
            selection: $selectedItem,
            sortOrder: $sortOrder
        ) {
            TableColumn("Title", value: \.name) { song in
                HStack {
                    Text(song.name)

                    if let alia = song.tns?.first ?? song.alia.first {
                        Text("( \(alia) )")
                            .foregroundColor(.secondary)
                    }

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
            }.width(min: 500)
            TableColumn("Artist", value: \.ar[0].name) { song in
                Text(song.ar.map(\.name).joined(separator: ", "))
            }
            TableColumn("Ablum", value: \.al.name)
            TableColumn("Duration", value: \.dt) { song in
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
        .onChange(of: sortOrder) { prevSortOrder, sortOrder in
            if prevSortOrder.count >= 1, self.sortOrder.count >= 1,
                prevSortOrder[0].keyPath == self.sortOrder[0].keyPath,
                self.sortOrder[0].order == .forward
            {
                self.sortOrder.removeAll()
            }

            handleSortChange(sortOrder: self.sortOrder)
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

    private func handleSortChange(sortOrder: [KeyPathComparator<CloudMusicApi.Song>]) {
        guard !sortOrder.isEmpty else {
            model.resetSorting()
            isSorted = false
            return
        }

        isSorted = true
        model.applySorting(by: [sortOrder[0]])
    }
}
