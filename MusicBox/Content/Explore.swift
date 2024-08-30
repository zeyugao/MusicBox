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

enum ExploreNavigationPath: Hashable, Codable {
    static func hash(into hasher: inout Hasher, for value: ExploreNavigationPath) {
        hasher.combine(value.id)
    }

    case playlist(UInt64, String)  // id, name
    case searchResult([CloudMusicApi.Song])

    var name: String {
        switch self {
        case let .playlist(_, name):
            return name
        case .searchResult:
            return "搜索结果"
        }
    }

    var id: UInt64 {
        switch self {
        case let .playlist(id, _):
            return id
        case let .searchResult(songs):
            return songs.map { $0.id }.reduce(0, +)
        }
    }

    enum CodingKeys: String, CodingKey {
        case playlist, searchResult
    }

    func encode(to encoder: Encoder) throws {
        let _ = encoder.container(keyedBy: CodingKeys.self)
        // var container = encoder.container(keyedBy: CodingKeys.self)
        // switch self {
        // case .playlist:
        //     try container.encode(0, forKey: .playlist)
        // case .searchResult:
        //     try container.encode(0, forKey: .searchResult)
        // }
    }
}

struct ExploreView: View {
    @State var recommendResource: [CloudMusicApi.RecommandPlaylistItem] = []
    @State private var searchText = ""
    @State private var searchSuggestions = [CloudMusicApi.Song]()
    @State private var task: Task<Void, Never>?
    @State private var isLoading = false

    @Binding private var navigationPath: NavigationPath

    @EnvironmentObject var playController: PlaylistStatus
    @EnvironmentObject private var userInfo: UserInfo

    init(navigationPath: Binding<NavigationPath>) {
        _navigationPath = navigationPath
    }

    private func gotoPlaylist(id: UInt64, name: String) {
        navigationPath.append(ExploreNavigationPath.playlist(id, name))
    }

    private func displaySearchResult(_ result: [CloudMusicApi.Song]) {
        navigationPath.append(ExploreNavigationPath.searchResult(result))
    }

    var body: some View {
        ZStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))]) {
                    ForEach(recommendResource) { res in
                        RecommendResourceIcon(res: res)
                            .padding()
                            .onTapGesture {
                                gotoPlaylist(id: res.id, name: res.name)
                            }
                    }
                }
            }
            .task {
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
                if let res = await CloudMusicApi(cacheTtl: 5 * 60).recommend_resource() {
                    newRes.append(contentsOf: res)
                }
                recommendResource = newRes
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

                        if let res = await CloudMusicApi(cacheTtl: 5 * 60).song_detail(ids: [id]) {
                            displaySearchResult(res)
                        }

                        defer { searchText = "" }
                        return
                    }

                    if let res = await CloudMusicApi(cacheTtl: 5 * 60).search(keyword: searchText) {
                        let res = res.map { $0.convertToSong() }
                        displaySearchResult(res)
                    }
                }
            }
            .navigationDestination(
                for: ExploreNavigationPath.self
            ) { path in
                let metadata =
                    switch path {
                    case let .playlist(id, name):
                        PlaylistMetadata.netease(id, name)
                    case let .searchResult(result):
                        PlaylistMetadata.songs(result, path.id, "搜索结果")
                    }

                PlayListView(playlistMetadata: metadata)
                    .environmentObject(userInfo)
                    .environmentObject(playController)
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

                    if let res = await CloudMusicApi(cacheTtl: 1 * 60).search_suggest(
                        keyword: text)
                    {
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
