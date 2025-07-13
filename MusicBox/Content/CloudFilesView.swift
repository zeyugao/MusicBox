//
//  CloudFiles.swift
//  MusicBox
//
//  Created by Elsa on 2024/5/6.
//

import Foundation
import SwiftUI

struct CloudFilesView: View {
    @EnvironmentObject var userInfo: UserInfo
    @State private var cloudFiles: [CloudMusicApi.CloudFile] = []
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var hasMoreFiles = true
    @State private var selectedFileForMatch: CloudMusicApi.CloudFile?
    private let pageSize = 30

    var body: some View {
        Group {
            if isLoading {
                VStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading cloud files...")
                        .foregroundColor(.secondary)
                        .padding(.top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if cloudFiles.isEmpty {
                VStack {
                    Image(systemName: "icloud.slash")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No cloud files found")
                        .foregroundColor(.secondary)
                        .padding(.top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(cloudFiles, id: \.id) { file in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(file.fileName)
                                        .font(.body)
                                        .lineLimit(1)

                                    Spacer()

                                    Text(file.parseFileSize())
                                        .font(.caption)
                                        .foregroundColor(.secondary)

                                    Image(
                                        systemName: file.isMatched
                                            ? "checkmark.circle.fill" : "xmark.circle.fill"
                                    )
                                    .foregroundColor(file.isMatched ? .green : .red)
                                    .font(.caption)
                                }

                                if let simpleSong = file.simpleSong,
                                    let artistName = simpleSong.ar.first?.name,
                                    let albumName = simpleSong.al.name,
                                    let name = simpleSong.name
                                {
                                    Text("\(name) - \(artistName) - \(albumName)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .contextMenu {
                            Button("Match with") {
                                selectedFileForMatch = file
                            }
                        }
                        .onAppear {
                            if file.id == cloudFiles.last?.id && hasMoreFiles && !isLoadingMore {
                                Task {
                                    await loadMoreFiles()
                                }
                            }
                        }
                    }

                    if isLoadingMore {
                        HStack {
                            Spacer()
                            ProgressView()
                                .scaleEffect(0.5)
                            Text("Loading more...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding()
                    }
                }
                .listStyle(PlainListStyle())
                .refreshable {
                    await loadCloudFiles(reset: true)
                }
            }
        }
        .task {
            await loadCloudFiles()
        }
        .sheet(item: $selectedFileForMatch) { file in
            MatchWithModalView(cloudFile: file, userInfo: userInfo) {
                Task {
                    await loadCloudFiles(reset: true)
                }
            }
        }
    }

    private func loadCloudFiles(reset: Bool = false) async {
        if reset {
            DispatchQueue.main.async {
                self.cloudFiles = []
                self.hasMoreFiles = true
            }
        }

        isLoading = true
        if let files = await CloudMusicApi().user_cloud(limit: pageSize, offset: 0) {
            DispatchQueue.main.async {
                self.cloudFiles = files
                self.hasMoreFiles = files.count == self.pageSize
                self.isLoading = false
            }
        } else {
            DispatchQueue.main.async {
                self.cloudFiles = []
                self.hasMoreFiles = false
                self.isLoading = false
            }
        }
    }

    private func loadMoreFiles() async {
        guard !isLoadingMore && hasMoreFiles else { return }

        isLoadingMore = true
        let offset = cloudFiles.count

        if let newFiles = await CloudMusicApi().user_cloud(limit: pageSize, offset: offset) {
            DispatchQueue.main.async {
                self.cloudFiles.append(contentsOf: newFiles)
                self.hasMoreFiles = newFiles.count == self.pageSize
                self.isLoadingMore = false
            }
        } else {
            DispatchQueue.main.async {
                self.hasMoreFiles = false
                self.isLoadingMore = false
            }
        }
    }
}

struct MatchWithModalView: View {
    let cloudFile: CloudMusicApi.CloudFile
    let userInfo: UserInfo
    let onMatchSuccess: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPlaylist: CloudMusicApi.PlayListItem?
    @State private var playlistSongs: [CloudMusicApi.Song] = []
    @State private var isLoadingPlaylist = false
    @State private var selectedSongForMatch: CloudMusicApi.Song?

    var body: some View {
        NavigationSplitView {
            // Left sidebar - Playlist selection
            if userInfo.playlists.isEmpty {
                VStack {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No playlists found")
                        .foregroundColor(.secondary)
                        .padding(.top)
                    Text("Create some playlists first")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Select Playlist")
            } else {
                List(userInfo.playlists, id: \.id, selection: $selectedPlaylist) { playlist in
                    PlaylistRowView(playlist: playlist)
                        .tag(playlist)
                }
                .listStyle(SidebarListStyle())
                .navigationTitle("Select Playlist")
                .onChange(of: selectedPlaylist) { _, newPlaylist in
                    if let playlist = newPlaylist {
                        Task {
                            await loadPlaylistSongs(playlist: playlist)
                        }
                    }
                }
            }
        } detail: {
            // Right detail view - Playlist songs
            if let selectedPlaylist = selectedPlaylist {
                if isLoadingPlaylist {
                    VStack {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Loading songs...")
                            .foregroundColor(.secondary)
                            .padding(.top)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle(selectedPlaylist.name)
                } else {
                    List(playlistSongs, id: \.id) { song in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(song.name)
                                    .font(.body)
                                    .lineLimit(1)
                                Text(song.ar.map { $0.name }.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            let duration = song.parseDuration()
                            Text(String(format: "%02d:%02d", duration.minute, duration.second))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }.contentShape(Rectangle())
                            .padding(.vertical, 2)
                            .padding(.horizontal, 8)
                            .background(
                                selectedSongForMatch?.id == song.id
                                    ? Color.blue.opacity(0.2) : Color.clear
                            )
                            .cornerRadius(8)
                            .onTapGesture {
                                selectedSongForMatch = song
                            }
                    }
                    .listStyle(PlainListStyle())
                    .navigationTitle(selectedPlaylist.name)
                }
            } else {
                VStack {
                    Image(systemName: "music.note")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Select a playlist")
                        .foregroundColor(.secondary)
                        .padding(.top)
                    Text("Choose a playlist from the sidebar to see its songs")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Songs")
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Confirm") {
                    if let selectedSong = selectedSongForMatch {
                        Task {
                            await matchCloudFile(targetSong: selectedSong)
                        }
                    }
                }
                .disabled(selectedSongForMatch == nil)
            }
        }
    }

    private func loadPlaylistSongs(playlist: CloudMusicApi.PlayListItem) async {
        isLoadingPlaylist = true

        if let result = await CloudMusicApi().playlist_detail(id: playlist.id) {
            DispatchQueue.main.async {
                self.playlistSongs = result.tracks
                self.isLoadingPlaylist = false
            }
        } else {
            DispatchQueue.main.async {
                self.playlistSongs = []
                self.isLoadingPlaylist = false
            }
        }
    }

    private func matchCloudFile(targetSong: CloudMusicApi.Song) async {
        guard let userId = userInfo.profile?.userId else { return }

        do {
            try await CloudMusicApi().cloud_match(
                userId: UInt64(userId),
                songId: cloudFile.privateCloud.songId,
                adjustSongId: targetSong.id
            )

            DispatchQueue.main.async {
                onMatchSuccess()
                dismiss()
            }

        } catch let error as RequestError {
            DispatchQueue.main.async {
                dismiss()
                AlertModal.showAlert(error.localizedDescription)
            }
        } catch {
            DispatchQueue.main.async {
                dismiss()
                AlertModal.showAlert(error.localizedDescription)
            }
        }
    }
}
