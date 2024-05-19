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

enum PlaylistMetadata {
    case netease(UInt64, String)  // id, name
    case songs([CloudMusicApi.Song], UInt64, String)  // all songs, id, name

    var name: String {
        switch self {
        case .netease(_, let name):
            return name
        case .songs(_, _, let name):
            return name
        }
    }

    var id: UInt64 {
        switch self {
        case .netease(let id, _):
            return id
        case .songs(_, let id, _):
            return id
        }
    }
}

class PlaylistDetailModel: ObservableObject {
    var originalSongs: [CloudMusicApi.Song]?
    @Published var songs: [CloudMusicApi.Song]?
    var curId: UInt64?

    var sortOrder: [KeyPathComparator<CloudMusicApi.Song>]? = nil
    var searchText = ""

    func updatePlaylistDetail(metadata: PlaylistMetadata) async {
        switch metadata {
        case .netease(let id, _):
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
        case .songs(let songs, _, _):
            self.originalSongs = songs
            DispatchQueue.main.async {
                self.songs = songs
            }
        }
    }

    func applySorting(by sortOrder: [KeyPathComparator<CloudMusicApi.Song>]) {
        self.sortOrder = sortOrder
    }

    func applySearch(by keyword: String) {
        searchText = keyword
    }

    func resetSorting() {
        sortOrder = nil
    }

    func resetSearchText() {
        searchText = ""
    }

    func update() {
        guard let originalSongs = originalSongs else { return }
        var songs = originalSongs
        if !searchText.isEmpty {
            let keyword = searchText.lowercased()
            songs = songs.filter { song in
                song.name.lowercased().contains(keyword)
                    || song.ar.map(\.name).joined(separator: "").lowercased().contains(keyword)
                    || song.al.name.lowercased().contains(keyword)
            }
        }

        if let sortOrder = sortOrder {
            songs = songs.sorted(using: sortOrder)
        }

        self.songs = songs
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
        artworkUrl: URL(string: song.al.picUrl.https),
        nsSong: song
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
        artworkUrl: URL(string: song.al.picUrl.https),
        nsSong: song
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
            Task {
                let newItem = loadItem(song: song)
                let _ = await playController.addItemAndPlay(newItem)
                await playController.startPlaying()
            }
        }
        Button("Add to Now Playing") {
            let newItem = loadItem(song: song)
            let _ = playController.addItemToPlaylist(newItem)
        }
    }
}

struct ListPlaylistDialogView: View {
    @EnvironmentObject var userInfo: UserInfo
    @Environment(\.dismiss) private var dismiss

    var onSelect: ((CloudMusicApi.PlayListItem) -> Void)?

    var body: some View {
        VStack {
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(userInfo.playlists.filter { !$0.subscribed }) { playlist in
                        
                        Button(action: {
                            onSelect?(playlist)
                            dismiss()
                        }) {
                            HStack {
                                let height = 64.0
                                AsyncImage(url: URL(string: playlist.coverImgUrl.https)) { image in
                                    image.resizable()
                                        .scaledToFit()
                                        .frame(width: height, height: height)
                                } placeholder: {
                                    Image(systemName: "music.note")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 30, height: 30)
                                        .padding()
                                        .frame(width: height, height: height)
                                        .background(Color.gray.opacity(0.2))
                                }
                                Text(playlist.name)
                                    .font(.title2)
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .onHover { inside in
                            if inside {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 400, maxHeight: 600)

            Button("Cancel") {
                dismiss()
            }
        }.padding()
    }
}

struct PlayAllButton: View {
    @EnvironmentObject var playController: PlayController

    var songs: [CloudMusicApi.Song]

    var body: some View {
        Button(action: {
            Task {
                let newItems = songs.map { song in
                    loadItem(song: song)
                }
                let _ = await playController.replacePlaylist(newItems, continuePlaying: false)
                await playController.startPlaying()
            }
        }) {
            Image(systemName: "play.circle")
                .resizable()
                .frame(width: 16, height: 16)
        }
        .buttonStyle(BorderlessButtonStyle())
        .help("Play All")

        Button(action: {
            Task {
                let newItems = songs.map { song in
                    loadItem(song: song)
                }
                let _ = await playController.addItemsToPlaylist(newItems)
            }
        }) {
            Image(systemName: "plus.circle")
                .resizable()
                .frame(width: 16, height: 16)
        }
        .buttonStyle(BorderlessButtonStyle())
        .help("Add All to Playlist")
    }
}

struct DownloadProgressDialog: View {
    var text: String

    @Binding var value: Double
    @Binding var canceled: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(text)

                Spacer()
            }

            ProgressView(value: value)

            HStack {
                Spacer()
                Button(canceled ? "Canceling" : "Cancel") {
                    canceled = true
                }
            }
        }
        .padding(20)
        .frame(width: 300, height: 100)
    }
}

struct DownloadAllButton: View {
    @State private var presentDownloadAllSongDialog = false
    @State private var canceledDownloadAllSong = false
    @State private var downloadProgress: Double = 0.0

    @State private var downloading = false

    @State private var text: String = "Downloading"

    var songs: [CloudMusicApi.Song]

    var body: some View {
        Button(action: {
            if downloading {
                presentDownloadAllSongDialog.toggle()
                return
            }
            downloading = true

            Task {
                let totalCnt = songs.count

                for (idx, song) in songs.enumerated() {
                    text = "Downloading \(idx + 1) / \(totalCnt)"
                    if let _ = getCachedMusicFile(id: song.id) {
                    } else {
                        if let songData = await CloudMusicApi.song_url_v1(id: [song.id]) {
                            let songData = songData[0]
                            let ext = songData.type
                            if let url = URL(string: songData.url.https) {
                                let _ = await downloadMusicFile(url: url, id: song.id, ext: ext)
                            }
                        }
                    }

                    downloadProgress = Double(idx + 1) / Double(totalCnt)

                    if canceledDownloadAllSong {
                        break
                    }
                }
                canceledDownloadAllSong = false
                presentDownloadAllSongDialog = false
                downloading = false
            }
        }) {
            if downloading {
                ProgressView(value: downloadProgress)
                    .progressViewStyle(CircularProgressViewStyle())
                    .controlSize(.small)
                    .help("Downloading")
            } else {
                Image(systemName: "arrow.down.circle")
                    .resizable()
                    .frame(width: 16, height: 16)
                    .help("Download All")
            }
        }
        .buttonStyle(BorderlessButtonStyle())
        .popover(
            isPresented: $presentDownloadAllSongDialog
        ) {
            DownloadProgressDialog(
                text: text,
                value: $downloadProgress,
                canceled: $canceledDownloadAllSong
            )
        }
    }
}

struct PlayListView: View {
    @StateObject var model = PlaylistDetailModel()

    @EnvironmentObject private var userInfo: UserInfo

    @State private var selectedItem: CloudMusicApi.Song.ID?
    @State private var sortOrder = [KeyPathComparator<CloudMusicApi.Song>]()
    @State private var loadingTask: Task<Void, Never>? = nil
    @State private var isLoading = false

    @State private var searchText = ""
    @State private var errorText = ""
    @State private var selectedSongToAdd: CloudMusicApi.Song?

    var playlistMetadata: PlaylistMetadata?

    let currencyStyle = Decimal.FormatStyle.Currency(code: "USD")

    func uploadCloud(songId: UInt64, url: URL) async {
        isLoading = true
        defer { isLoading = false }
        if let metadata = await loadMetadata(url: url) {
            if let privateSongId = await CloudMusicApi.cloud(
                filePath: url,
                songName: metadata.title,
                artist: metadata.artist,
                album: metadata.album
            ) {
                await CloudMusicApi.cloud_match(
                    userId: userInfo.profile?.userId ?? 0,
                    songId: privateSongId,
                    adjustSongId: songId
                )
                updatePlaylist()
                return
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

    var body: some View {
        ZStack {
            Table(
                of: CloudMusicApi.Song.self,
                selection: $selectedItem,
                sortOrder: $sortOrder
            ) {
                TableColumn("") { song in
                    let favored = (userInfo.likelist.contains(song.id))

                    Button(action: {
                        Task {
                            if await CloudMusicApi.like(id: song.id, like: !favored) {
                                if favored {
                                    userInfo.likelist.remove(song.id)
                                } else {
                                    userInfo.likelist.insert(song.id)
                                }
                            }
                        }
                    }) {
                        Image(systemName: favored ? "heart.fill" : "heart")
                            .resizable()
                            .frame(width: 16, height: 14)
                            .help(favored ? "Unfavor" : "Favor")
                            .padding(.trailing, 4)
                    }
                }
                .width(16)

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
                }
                .width(min: 500)

                TableColumn("Artist", value: \.ar[0].name) { song in
                    Text(song.ar.map(\.name).joined(separator: ", "))
                }

                TableColumn("Ablum", value: \.al.name)

                TableColumn("Duration", value: \.dt) { song in
                    let ret = song.parseDuration()
                    Text(String(format: "%02d:%02d", ret.minute, ret.second))
                }
                .width(max: 60)
            } rows: {
                if let songs = model.songs {
                    ForEach(songs) { song in
                        TableRow(song)
                            .contextMenu {
                                TableContextMenu(song: song)

                                Button("Add to Playlist") {
                                    selectedSongToAdd = song
                                }

                                if case .netease(let songId, _) = playlistMetadata {
                                    Button("Delete from Playlist") {
                                        Task {
                                            do {
                                                try await CloudMusicApi.playlist_tracks(
                                                    op: .del, playlistId: songId,
                                                    trackIds: [song.id])
                                                updatePlaylist()
                                            } catch let error as RequestError {
                                                errorText = error.localizedDescription
                                            } catch {
                                                errorText = error.localizedDescription
                                            }
                                        }
                                    }
                                }

                                Button("Upload to Cloud") {
                                    Task {
                                        if let url = await selectFile() {
                                            await uploadCloud(songId: song.id, url: url)
                                        }
                                    }
                                }

                                Button("Copy Title") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(song.name, forType: .string)
                                }
                            }
                            .dropDestination(for: URL.self) { urls in
                                if let url = urls.first {
                                    Task {
                                        await uploadCloud(songId: song.id, url: url)
                                    }
                                }
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
            .sheet(
                isPresented: Binding<Bool>(
                    get: { selectedSongToAdd != nil },
                    set: { if !$0 { selectedSongToAdd = nil } }
                )
            ) {
                if let selectedSong = selectedSongToAdd {
                    ListPlaylistDialogView { selectedPlaylist in
                        Task {
                            do {
                                try await CloudMusicApi.playlist_tracks(
                                    op: .add, playlistId: selectedPlaylist.id,
                                    trackIds: [selectedSong.id])
                            } catch let error as RequestError {
                                errorText = error.localizedDescription
                            } catch {
                                errorText = error.localizedDescription
                            }
                        }
                    }
                }
            }
            .onChange(of: searchText) { prevSearchText, searchText in
                model.applySearch(by: searchText)
                model.update()
            }
            .navigationTitle((playlistMetadata?.name) ?? "Playlist")
            .searchable(text: $searchText, prompt: "Search in Playlist")
            .toolbar {
                PlayAllButton(songs: model.songs ?? [])
                DownloadAllButton(songs: model.songs ?? [])
            }
            .onChange(of: playlistMetadata?.id) {
                updatePlaylist()
            }
            .onAppear {
                updatePlaylist()
            }
            .onDisappear {
                loadingTask?.cancel()
            }
            .alert(
                isPresented: Binding<Bool>(
                    get: { !errorText.isEmpty },
                    set: { if !$0 { errorText = "" } }
                )
            ) {
                Alert(title: Text("Error"), message: Text(errorText))
            }

            if isLoading {
                ProgressView()
                    .colorInvert()
                    .progressViewStyle(CircularProgressViewStyle())
                    .controlSize(.small)
                    .frame(width: 48, height: 48)
                    .background(Color.black.opacity(0.75))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func updatePlaylist() {
        if let playlistMetadata = playlistMetadata {
            isLoading = true

            searchText = ""
            sortOrder = []

            model.songs = nil
            model.originalSongs = nil

            model.curId = playlistMetadata.id
            loadingTask?.cancel()
            loadingTask = Task {
                await model.updatePlaylistDetail(metadata: playlistMetadata)
                isLoading = false
            }
        }
    }

    private func handleSortChange(sortOrder: [KeyPathComparator<CloudMusicApi.Song>]) {
        guard !sortOrder.isEmpty else {
            model.resetSorting()
            model.update()
            return
        }

        model.applySorting(by: [sortOrder[0]])
        model.update()
    }
}
