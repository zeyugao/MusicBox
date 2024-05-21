//
//  Explore.swift
//  MusicBox
//
//  Created by Elsa on 2024/5/18.
//

import Foundation
import SwiftUI

struct RecommendResourceIcon: View {
    var res: CloudMusicApi.RecommandPlaylistItem

    var body: some View {
        VStack(alignment: .center) {
            if res.picUrl.starts(with: "http") {
                AsyncImageWithCache(url: URL(string: res.picUrl.https)) { image in
                    image.resizable()
                        .interpolation(.high)
                } placeholder: {
                    Color.white
                }
                .frame(width: 100, height: 100)
                .cornerRadius(5)
                .frame(width: 100, height: 100)
            } else {
                Image(systemName: res.picUrl)
                    .resizable()
                    .frame(width: 50, height: 50)
                    .cornerRadius(5)
                    .frame(width: 100, height: 100)
            }

            Text(res.name)
        }
        .frame(width: 100, height: 150, alignment: .top)
    }
}

struct AlbumListView: View {
    @State var recommendResource: [CloudMusicApi.RecommandPlaylistItem] = []
    @State private var selectedResource: CloudMusicApi.RecommandPlaylistItem?
    @State private var searchText = ""
    @State private var searchSuggestions = [CloudMusicApi.Song]()
    @State private var searchResult = [CloudMusicApi.Song]()
    @State private var task: Task<Void, Never>?
    @State private var isLoading = false

    @EnvironmentObject var playController: PlayController
    @EnvironmentObject private var userInfo: UserInfo

    var body: some View {
        ZStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))]) {
                    ForEach(recommendResource) { res in
                        RecommendResourceIcon(res: res)
                            .padding()
                            .onTapGesture {
                                selectedResource = res
                            }
                    }
                }
            }
            .onAppear {
                Task {
                    let currentDate = Date()
                    let calendar = Calendar.current
                    let day = calendar.component(.day, from: currentDate)
                    let dialyRecommend = CloudMusicApi.RecommandPlaylistItem(
                        creator: nil,
                        picUrl: "\(day).square",
                        userId: 0,
                        id: CloudMusicApi.RecommandSongPlaylistId,
                        name: "每日歌曲推荐",
                        playcount: 0,
                        trackCount: 0
                    )
                    var newRes = [dialyRecommend]
                    if let res = await CloudMusicApi.recommend_resource() {
                        newRes.append(contentsOf: res)
                    }
                    recommendResource = newRes
                }
            }
            .navigationDestination(
                isPresented: Binding<Bool>(
                    get: { selectedResource != nil },
                    set: { if !$0 { selectedResource = nil } }
                )
            ) {
                if let res = selectedResource {
                    let metadata = PlaylistMetadata.netease(res.id, res.name)
                    PlayListView(playlistMetadata: metadata)
                        .environmentObject(userInfo)
                        .environmentObject(playController)
                }
            }
            .searchable(
                text: $searchText,
                suggestions: {
                    ForEach(searchSuggestions, id: \.self) { suggestion in
                        Text(suggestion.name + " - " + suggestion.al.name)
                            .lineLimit(1)
                            .searchCompletion(
                                "##%%ID" + String(suggestion.id))
                    }
                }
            )
            .onSubmit(of: .search) {
                Task {
                    isLoading = true
                    defer { isLoading = false }

                    if searchText.starts(with: "##%%ID") {
                        let data = searchText.dropFirst(6)
                        let id = UInt64(data) ?? 0

                        if let res = await CloudMusicApi.song_detail(ids: [id]) {
                            searchResult = res
                        }

                        defer { searchText = "" }
                        return
                    }

                    if let res = await CloudMusicApi.search(keyword: searchText) {
                        let res = res.map { $0.convertToSong() }
                        searchResult = res
                    }
                }
            }
            .navigationDestination(
                isPresented: Binding<Bool>(
                    get: { !searchResult.isEmpty },
                    set: { if !$0 { searchResult.removeAll() } }
                )
            ) {
                if !searchResult.isEmpty {
                    let metadata = PlaylistMetadata.songs(
                        searchResult,
                        searchResult.map { $0.id }.reduce(0, +),
                        "搜索结果")
                    PlayListView(playlistMetadata: metadata)
                        .environmentObject(userInfo)
                        .environmentObject(playController)
                }
            }
            .onChange(of: searchText) { _, text in
                task?.cancel()

                guard !searchText.isEmpty else {
                    return
                }

                task = Task {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(0.3 * 1_000_000_000))
                    } catch {
                        return
                    }

                    if let res = await CloudMusicApi.search_suggest(keyword: text) {
                        DispatchQueue.main.async {
                            self.searchSuggestions = res.map { $0.convertToSong() }
                        }
                    }
                }
            }

            if isLoading {
                LoadingIndicatorView()
            }
        }
    }
}

struct ExploreView: View {
    var body: some View {
        NavigationStack {
            AlbumListView()
        }
    }
}
