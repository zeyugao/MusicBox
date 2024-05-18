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
                AsyncImage(url: URL(string: res.picUrl.https)) { image in
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
    @EnvironmentObject var playController: PlayController
    @EnvironmentObject private var userInfo: UserInfo

    var body: some View {
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
                PlayListView(neteasePlaylistMetadata: (res.id, res.name))
                    .environmentObject(userInfo)
                    .environmentObject(playController)
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
