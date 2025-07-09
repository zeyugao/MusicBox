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

extension Notification.Name {
    static let uploadToCloud = Notification.Name("uploadToCloud")
    static let refreshPlaylist = Notification.Name("refreshPlaylist")
}

enum PlaylistMetadata: Hashable, Equatable {
    static func == (lhs: PlaylistMetadata, rhs: PlaylistMetadata) -> Bool {
        lhs.id == rhs.id
    }

    static func hash(into hasher: inout Hasher, value: PlaylistMetadata) {
        hasher.combine(value.id)
    }

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

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

class PlaylistDetailModel: ObservableObject {
    var originalSongs: [CloudMusicApi.Song]?
    @Published var songs: [CloudMusicApi.Song]?
    var curId: UInt64?

    var sortOrder: [KeyPathComparator<CloudMusicApi.Song>]? = nil
    var searchText = ""

    func updatePlaylistDetail(metadata: PlaylistMetadata, force: Bool = false) async {
        switch metadata {
        case .netease(let id, _):
            let cacheTtl = if force { 0.0 } else { 10 * 60.0 }

            if let playlist = await CloudMusicApi(cacheTtl: cacheTtl).playlist_detail(id: id) {
                let trackIds = playlist.trackIds
                let tracks = playlist.tracks

                if let cur = curId, cur != id {
                    return
                }

                if trackIds.count == tracks.count {
                    self.originalSongs = tracks
                    await MainActor.run {
                        self.songs = tracks
                    }
                } else {
                    if let playlist = await CloudMusicApi(cacheTtl: cacheTtl).song_detail(
                        ids: trackIds)
                    {
                        self.originalSongs = playlist
                        await MainActor.run {
                            self.songs = playlist
                        }
                    }
                }
            }
        case .songs(let songs, _, _):
            self.originalSongs = songs
            await MainActor.run {
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
        Task {
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
            let newSongs = songs

            await MainActor.run {
                self.songs = newSongs
            }
        }
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

func likeSong(
    likelist: inout Set<UInt64>, songId: UInt64, favored: Bool
)
    async
{
    do {
        try await CloudMusicApi().like(id: songId, like: !favored)
        if favored {
            likelist.remove(songId)
        } else {
            likelist.insert(songId)
        }
    } catch let error as RequestError {
        AlertModal.showAlert(error.localizedDescription)
    } catch {
        AlertModal.showAlert(error.localizedDescription)
    }
}

func uploadCloudFile(songId: UInt64, url: URL, userInfo: UserInfo) async throws -> Bool {
    if let metadata = await loadMetadata(url: url) {
        if let privateSongId = try await CloudMusicApi().cloud(
            filePath: url,
            songName: metadata.title,
            artist: metadata.artist,
            album: metadata.album
        ) {
            print("Private song ID: \(privateSongId)")
            try await CloudMusicApi().cloud_match(
                userId: userInfo.profile?.userId ?? 0,
                songId: privateSongId,
                adjustSongId: songId
            )
            return true
        } else {
            throw RequestError.Request("Failed to upload file to cloud")
        }

    } else {
        throw RequestError.Request("Failed to load metadata from file")
    }
}

@MainActor
func selectAudioFile() async -> URL? {
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
                                AsyncImageWithCache(url: URL(string: playlist.coverImgUrl.https)) {
                                    image in
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

struct SongContextMenu: View {
    let song: CloudMusicApi.Song
    let playlistMetadata: PlaylistMetadata?
    let onPlay: () -> Void
    let onAddToNowPlaying: () -> Void
    let onAddToPlaylist: () -> Void
    let onDeleteFromPlaylist: () -> Void
    let onUploadToCloud: () -> Void

    var body: some View {
        Button("Play") {
            onPlay()
        }

        Button("Add to Now Playing") {
            onAddToNowPlaying()
        }

        Button("Add to Playlist") {
            onAddToPlaylist()
        }

        if case .netease = playlistMetadata {
            Button("Delete from Playlist") {
                onDeleteFromPlaylist()
            }
        }

        Button("Upload to Cloud") {
            onUploadToCloud()
        }

        Button("Copy Title") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(song.name, forType: .string)
        }

        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                "https://music.163.com/#/song?id=\(song.id)", forType: .string)
        }
    }
}

struct SongTitleCell: View {
    let song: CloudMusicApi.Song

    // 缓存计算结果，避免重复计算
    private let aliasText: String?
    private let statusIcon:
        (systemName: String, help: String, width: CGFloat, height: CGFloat, padding: CGFloat)?

    init(song: CloudMusicApi.Song) {
        self.song = song
        self.aliasText = song.tns?.first ?? song.alia.first

        // 预计算状态图标信息
        if song.pc != nil {
            self.statusIcon = ("cloud", "Cloud", 18, 12, 0)
        } else {
            switch song.fee {
            case .vip, .album:
                self.statusIcon = ("dollarsign.circle", "Need buy", 16, 16, 1)
            case .trial:
                self.statusIcon = ("gift", "Trial", 16, 16, 1)
            default:
                self.statusIcon = nil
            }
        }
    }

    var body: some View {
        HStack {
            // Main title
            Text(song.name)

            // Alias text
            if let alias = aliasText {
                Text("( \(alias) )")
                    .foregroundColor(.secondary)
            }

            // Status icon
            if let icon = statusIcon {
                Spacer()
                Image(systemName: icon.systemName)
                    .resizable()
                    .frame(width: icon.width, height: icon.height)
                    .help(icon.help)
                    .padding(.horizontal, icon.padding)
                    .frame(width: 18, height: 16)
            }
        }
    }
}

struct SongFavoriteButton: View {
    let song: CloudMusicApi.Song
    let userInfo: UserInfo

    // 缓存 songId，避免重复访问
    private let songId: UInt64

    init(song: CloudMusicApi.Song, userInfo: UserInfo) {
        self.song = song
        self.userInfo = userInfo
        self.songId = song.id
    }

    private var isFavorite: Bool {
        userInfo.likelist.contains(songId)
    }

    private func toggleFavorite() {
        let currentFavoriteState = isFavorite

        Task {
            var likelist = userInfo.likelist
            await likeSong(
                likelist: &likelist,
                songId: songId,
                favored: currentFavoriteState
            )
            await MainActor.run {
                // 使用捕获的状态，避免重复计算
                if currentFavoriteState {
                    userInfo.likelist.remove(songId)
                } else {
                    userInfo.likelist.insert(songId)
                }
            }
        }
    }

    var body: some View {
        let favorite = isFavorite

        Button(action: toggleFavorite) {
            Image(systemName: favorite ? "heart.fill" : "heart")
                .resizable()
                .frame(width: 16, height: 14)
                .help(favorite ? "Unfavor" : "Favor")
                .padding(.trailing, 4)
        }
    }
}

struct SongArtistCell: View {
    let song: CloudMusicApi.Song

    // 缓存艺术家名称，避免重复计算
    private let artistNames: String

    init(song: CloudMusicApi.Song) {
        self.song = song
        self.artistNames = song.ar.map(\.name).joined(separator: ", ")
    }

    var body: some View {
        Text(artistNames)
    }
}

struct SongDurationCell: View {
    let song: CloudMusicApi.Song

    // 缓存格式化的时长，避免重复计算
    private let formattedDuration: String

    init(song: CloudMusicApi.Song) {
        self.song = song
        let duration = song.parseDuration()
        self.formattedDuration = String(format: "%02d:%02d", duration.minute, duration.second)
    }

    var body: some View {
        Text(formattedDuration)
    }
}

struct SongTableView: View {
    let songs: [CloudMusicApi.Song]?
    @Binding var selectedItem: CloudMusicApi.Song.ID?
    @Binding var sortOrder: [KeyPathComparator<CloudMusicApi.Song>]
    let userInfo: UserInfo
    let playlistStatus: PlaylistStatus
    let playlistMetadata: PlaylistMetadata?
    let onSortChange: ([KeyPathComparator<CloudMusicApi.Song>]) -> Void
    @Binding var selectedSongToAdd: CloudMusicApi.Song?
    let onDeleteFromPlaylist: (CloudMusicApi.Song) -> Void
    let onUploadToCloud: (CloudMusicApi.Song, URL) -> Void

    var body: some View {
        Table(
            of: CloudMusicApi.Song.self,
            selection: $selectedItem,
            sortOrder: $sortOrder
        ) {
            TableColumn("") { song in
                SongFavoriteButton(song: song, userInfo: userInfo)
            }
            .width(16)

            TableColumn("Title", value: \.name) { song in
                SongTitleCell(song: song)
            }
            .width(min: 500)

            TableColumn("Artist", value: \.ar[0].name) { song in
                SongArtistCell(song: song)
            }

            TableColumn("Album", value: \.al.name)

            TableColumn("Duration", value: \.dt) { song in
                SongDurationCell(song: song)
            }
            .width(max: 60)
        } rows: {
            if let songs = songs {
                ForEach(songs) { song in
                    TableRow(song)
                        .contextMenu {
                            SongContextMenu(
                                song: song,
                                playlistMetadata: playlistMetadata,
                                onPlay: {
                                    Task {
                                        let newItem = loadItem(song: song)
                                        let _ = await playlistStatus.addItemAndSeekTo(
                                            newItem, shouldPlay: true)
                                    }
                                },
                                onAddToNowPlaying: {
                                    let newItem = loadItem(song: song)
                                    let _ = playlistStatus.addItemToPlaylist(newItem)
                                },
                                onAddToPlaylist: {
                                    selectedSongToAdd = song
                                },
                                onDeleteFromPlaylist: { onDeleteFromPlaylist(song) },
                                onUploadToCloud: {
                                    Task {
                                        if let url = await selectAudioFile() {
                                            onUploadToCloud(song, url)
                                        }
                                    }
                                }
                            )
                        }
                        .dropDestination(for: URL.self) { urls in
                            if let url = urls.first {
                                onUploadToCloud(song, url)
                            }
                        }
                }
            }
        }
        .onTapGesture(count: 2) { location in
            print("location: \(location)")
        }
        .onChange(of: sortOrder) { prevSortOrder, newSortOrder in
            if prevSortOrder.count >= 1, newSortOrder.count >= 1,
                prevSortOrder[0].keyPath == newSortOrder[0].keyPath,
                newSortOrder[0].order == .forward
            {
                sortOrder.removeAll()
            }

            onSortChange(sortOrder)
        }
    }
}

struct PlaylistToolbar: ToolbarContent {
    let songs: [CloudMusicApi.Song]
    let playlistMetadata: PlaylistMetadata?
    let playlistStatus: PlaylistStatus
    let userInfo: UserInfo
    let onRefresh: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup {
            Button(action: {
                Task {
                    let newItems = songs.map { song in
                        loadItem(song: song)
                    }
                    let _ = await playlistStatus.replacePlaylist(
                        newItems, continuePlaying: true, shouldSaveState: true)
                }
            }) {
                Image(systemName: "play")
            }
            .help("Play All")

            Button(action: {
                Task {
                    let newItems = songs.map { song in
                        loadItem(song: song)
                    }
                    let _ = await playlistStatus.addItemsToPlaylist(
                        newItems, continuePlaying: false, shouldSaveState: true)
                }
            }) {
                Image(systemName: "plus")
            }
            .help("Add All to Playlist")

            DownloadAllButton(songs: songs)

            UploadButton(userInfo: userInfo, onRefresh: onRefresh)

            if case .netease = playlistMetadata {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh Playlist")
            }
        }
    }
}

struct UploadQueueItem: Identifiable {
    let id = UUID()
    let songId: UInt64
    let songName: String
    let url: URL
    var isCompleted: Bool = false
    var isFailed: Bool = false
    var errorMessage: String?
}

struct UploadProgressRow: View {
    let item: UploadQueueItem

    private var truncatedErrorMessage: String {
        guard let errorMessage = item.errorMessage else { return "Upload failed" }
        return errorMessage.count > 30 ? String(errorMessage.prefix(30)) + "..." : errorMessage
    }

    var body: some View {
        HStack {
            Text(item.songName)
                .lineLimit(1)

            Spacer()

            if item.isCompleted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else if item.isFailed {
                HStack {
                    Text(truncatedErrorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                        .lineLimit(1)
                        .frame(maxWidth: 300, alignment: .trailing)
                        .help(item.errorMessage ?? "Upload failed")

                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                        .help(item.errorMessage ?? "Upload failed")
                }
            } else {
                ProgressView()
                    .progressViewStyle(LinearProgressViewStyle())
                    .frame(width: 300)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

struct UploadProgressDialog: View {
    @Binding var uploadQueue: [UploadQueueItem]
    @Binding var isPresented: Bool
    @Binding var canceled: Bool

    var completedCount: Int {
        uploadQueue.filter { $0.isCompleted }.count
    }

    var failedCount: Int {
        uploadQueue.filter { $0.isFailed }.count
    }

    var isUploading: Bool {
        uploadQueue.contains { !$0.isCompleted && !$0.isFailed }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Upload to Cloud")
                    .font(.headline)
                Spacer()
            }

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(uploadQueue) { item in
                        UploadProgressRow(item: item)
                    }
                }
            }
            .frame(maxHeight: 200)

            HStack {
                Text("Completed: \(completedCount), Failed: \(failedCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                if isUploading {
                    Button(canceled ? "Canceling" : "Cancel") {
                        canceled = true
                    }
                    .disabled(canceled)
                }
            }
        }
        .padding(20)
        .frame(width: 500)
        .frame(minHeight: 150)
    }
}

@MainActor
class UploadManager: ObservableObject {
    @Published var uploadQueue: [UploadQueueItem] = []
    @Published var isUploading: Bool = false
    @Published var canceled: Bool = false

    private let userInfo: UserInfo
    private let onRefresh: (() -> Void)?

    init(userInfo: UserInfo, onRefresh: (() -> Void)? = nil) {
        self.userInfo = userInfo
        self.onRefresh = onRefresh
    }

    var completedCount: Int {
        uploadQueue.filter { $0.isCompleted }.count
    }

    var failedCount: Int {
        uploadQueue.filter { $0.isFailed }.count
    }

    var totalCount: Int {
        uploadQueue.count
    }

    var progress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(completedCount) / Double(totalCount)
    }

    func addUploadTask(songId: UInt64, songName: String, url: URL) {
        let item = UploadQueueItem(songId: songId, songName: songName, url: url)
        uploadQueue.append(item)

        if !isUploading {
            startUploading()
        }
    }

    private func startUploading() {
        isUploading = true
        canceled = false

        Task {
            await processUploadQueue()
        }
    }

    private func processUploadQueue() async {
        var hasAnySuccess = false

        var i = 0
        while i < uploadQueue.count {
            if canceled {
                break
            }

            let item = uploadQueue[i]
            if item.isCompleted || item.isFailed {
                i += 1
                continue
            }

            do {
                let success = try await uploadCloudFile(
                    songId: item.songId, url: item.url, userInfo: userInfo)

                await MainActor.run {
                    uploadQueue[i].isCompleted = success
                    if !success {
                        uploadQueue[i].isFailed = true
                        uploadQueue[i].errorMessage = "Upload failed"
                    } else {
                        hasAnySuccess = true
                    }
                }
            } catch let error as RequestError {
                await MainActor.run {
                    uploadQueue[i].isFailed = true
                    uploadQueue[i].errorMessage = error.localizedDescription
                }
            } catch {
                await MainActor.run {
                    uploadQueue[i].isFailed = true
                    uploadQueue[i].errorMessage = error.localizedDescription
                }
            }

            i += 1
        }

        await MainActor.run {
            isUploading = false
            canceled = false

            // 如果有任何成功上传，发送刷新通知
            if hasAnySuccess {
                NotificationCenter.default.post(name: .refreshPlaylist, object: nil)
            }
        }
    }

    func clearCompleted() {
        uploadQueue.removeAll { $0.isCompleted }
    }

    func clearAll() {
        uploadQueue.removeAll()
        isUploading = false
        canceled = false
    }
}

struct UploadButton: View {
    let userInfo: UserInfo
    let onRefresh: (() -> Void)?

    @StateObject private var uploadManager: UploadManager
    @State private var showUploadDialog = false

    init(userInfo: UserInfo, onRefresh: (() -> Void)? = nil) {
        self.userInfo = userInfo
        self.onRefresh = onRefresh
        self._uploadManager = StateObject(
            wrappedValue: UploadManager(userInfo: userInfo, onRefresh: onRefresh))
    }

    var body: some View {
        Button(action: {
            showUploadDialog.toggle()
        }) {
            if uploadManager.isUploading && uploadManager.totalCount > 0 {
                // 显示上传中图标
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundColor(.blue)
                    .symbolEffect(.pulse, options: .repeating)
            } else if uploadManager.totalCount > 0 {
                // 根据是否有失败显示不同的完成状态
                if uploadManager.failedCount > 0 {
                    Image(systemName: "xmark.circle")
                        .foregroundColor(.red)
                } else {
                    Image(systemName: "checkmark.circle")
                        .foregroundColor(.green)
                }
            } else {
                // 默认状态
                Image(systemName: "icloud.and.arrow.up")
            }
        }
        .help(
            uploadManager.isUploading
                ? "Uploading \(uploadManager.completedCount)/\(uploadManager.totalCount)"
                : uploadManager.totalCount > 0
                    ? (uploadManager.failedCount > 0
                        ? "Upload completed with \(uploadManager.failedCount) failed"
                        : "Upload completed successfully")
                    : "Upload to Cloud"
        )
        .popover(isPresented: $showUploadDialog) {
            UploadProgressDialog(
                uploadQueue: $uploadManager.uploadQueue,
                isPresented: $showUploadDialog,
                canceled: $uploadManager.canceled
            )
        }
        .environmentObject(uploadManager)
        .onReceive(NotificationCenter.default.publisher(for: .uploadToCloud)) { notification in
            if let userInfo = notification.userInfo,
                let songId = userInfo["songId"] as? UInt64,
                let songName = userInfo["songName"] as? String,
                let url = userInfo["url"] as? URL
            {
                uploadManager.addUploadTask(songId: songId, songName: songName, url: url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshPlaylist)) { _ in
            onRefresh?()
        }
    }
}

struct DownloadAllButton: View {
    @State private var presentDownloadAllSongDialog = false
    @State private var canceledDownloadAllSong = false
    @State private var downloadProgress: Double = 0.0

    @State private var downloading = false
    @State private var showConfirmationPopover = false

    @State private var text: String = "Downloading"

    var songs: [CloudMusicApi.Song]

    var body: some View {
        Button(action: {
            if downloading {
                presentDownloadAllSongDialog.toggle()
                return
            }
            showConfirmationPopover = true
        }) {
            if downloading {
                ProgressView(value: downloadProgress)
                    .progressViewStyle(CircularProgressViewStyle())
                    .controlSize(.small)
            } else {
                Image(systemName: "square.and.arrow.down")
            }
        }
        .help(downloading ? "Downloading" : "Download All")
        .popover(
            isPresented: $showConfirmationPopover
        ) {
            VStack(spacing: 15) {
                Text("Download All Songs")
                    .font(.headline)

                Text("Are you sure you want to download all \(songs.count) songs?")
                    .multilineTextAlignment(.center)

                HStack(spacing: 10) {
                    Button("Cancel") {
                        showConfirmationPopover = false
                    }
                    .buttonStyle(.borderless)

                    Button("Download") {
                        showConfirmationPopover = false
                        presentDownloadAllSongDialog = true
                        downloading = true

                        Task {
                            let totalCnt = songs.count

                            for (idx, song) in songs.enumerated() {
                                text = "Downloading \(idx + 1) / \(totalCnt)"
                                if getCachedMusicFile(id: song.id) != nil {
                                } else {
                                    if let songData = await CloudMusicApi().song_url_v1(id: [
                                        song.id
                                    ]) {
                                        let songData = songData[0]
                                        let ext = songData.type
                                        if let url = URL(string: songData.url.https) {
                                            let _ = await downloadMusicFile(
                                                url: url, id: song.id, ext: ext)
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
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(width: 300)
        }
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
    @EnvironmentObject var playlistStatus: PlaylistStatus

    @State private var selectedItem: CloudMusicApi.Song.ID?
    @State private var sortOrder = [KeyPathComparator<CloudMusicApi.Song>]()
    @State private var loadingTask: Task<Void, Never>? = nil
    @State private var isLoading = false
    @State private var currentLoadingTaskId = UUID()

    @State private var searchText = ""
    @State private var selectedSongToAdd: CloudMusicApi.Song?

    var playlistMetadata: PlaylistMetadata?

    private func handleUploadToCloud(song: CloudMusicApi.Song, url: URL) async {
        // 发送通知给 UploadButton 来处理上传队列
        NotificationCenter.default.post(
            name: .uploadToCloud,
            object: nil,
            userInfo: [
                "songId": song.id,
                "songName": song.name,
                "url": url,
            ]
        )
    }

    var body: some View {
        ZStack {
            SongTableView(
                songs: model.songs,
                selectedItem: $selectedItem,
                sortOrder: $sortOrder,
                userInfo: userInfo,
                playlistStatus: playlistStatus,
                playlistMetadata: playlistMetadata,
                onSortChange: handleSortChange,
                selectedSongToAdd: $selectedSongToAdd,
                onDeleteFromPlaylist: { song in
                    Task {
                        if case .netease(let songId, _) = playlistMetadata {
                            do {
                                try await CloudMusicApi().playlist_tracks(
                                    op: .del, playlistId: songId,
                                    trackIds: [song.id])
                                updatePlaylist()
                            } catch let error as RequestError {
                                AlertModal.showAlert(error.localizedDescription)
                            } catch {
                                AlertModal.showAlert(error.localizedDescription)
                            }
                        }
                    }
                },
                onUploadToCloud: { song, url in
                    // 暂时保持原来的上传方法
                    Task {
                        await handleUploadToCloud(song: song, url: url)
                    }
                }
            )
            .onChange(of: searchText) { prevSearchText, searchText in
                model.applySearch(by: searchText)
                model.update()
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
                                try await CloudMusicApi().playlist_tracks(
                                    op: .add, playlistId: selectedPlaylist.id,
                                    trackIds: [selectedSong.id])
                            } catch let error as RequestError {
                                AlertModal.showAlert(error.localizedDescription)
                            } catch {
                                AlertModal.showAlert(error.localizedDescription)
                            }
                        }
                    }
                }
            }
            .navigationTitle((playlistMetadata?.name) ?? "Playlist")
            .searchable(text: $searchText, prompt: "Search in Playlist")
            .toolbar {
                PlaylistToolbar(
                    songs: model.songs ?? [],
                    playlistMetadata: playlistMetadata,
                    playlistStatus: playlistStatus,
                    userInfo: userInfo,
                    onRefresh: {
                        Task {
                            updatePlaylist(force: true)
                        }
                    }
                )
            }
            .onChange(of: playlistMetadata?.id) {
                updatePlaylist()
            }
            .task {
                updatePlaylist()
            }
            .onDisappear {
                loadingTask?.cancel()
            }
            .onReceive(NotificationCenter.default.publisher(for: .refreshPlaylist)) { _ in
                Task {
                    updatePlaylist(force: true)
                }
            }

            if isLoading {
                LoadingIndicatorView()
            }
        }
    }

    private func updatePlaylist(force: Bool = false) {
        if let playlistMetadata = playlistMetadata {
            isLoading = true

            // model.songs = nil
            // model.originalSongs = nil

            model.curId = playlistMetadata.id
            loadingTask?.cancel()

            // Generate a new task ID for this loading operation
            let taskId = UUID()
            currentLoadingTaskId = taskId

            loadingTask = Task {
                await model.updatePlaylistDetail(metadata: playlistMetadata, force: force)

                // Only update loading state if this is still the current task
                if taskId == currentLoadingTaskId {
                    isLoading = false
                }

                searchText = ""
                sortOrder = []
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
