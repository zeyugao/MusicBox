//
//  ContentView.swift
//  MusicBox
//
//  Created by Elsa on 2024/4/16.
//

import Combine
import Foundation
import SwiftUI

enum DisplayContentType {
    case userinfo
    case playlist
}

func loadDecodableState<T: Decodable>(forKey: String, type: T.Type) -> T? {
    if let savedData = UserDefaults.standard.object(forKey: forKey)
        as? Data
    {
        let decoder = JSONDecoder()
        return try? decoder.decode(type, from: savedData)
    }
    return nil
}

func saveEncodableState<T: Encodable>(forKey: String, data: T) {
    let encoder = JSONEncoder()
    if let encoded = try? encoder.encode(data) {
        UserDefaults.standard.set(encoded, forKey: forKey)
    }
}

class UserInfo: ObservableObject {
    @Published var profile: CloudMusicApi.Profile?
    @Published var likelist: Set<UInt64> = []
    @Published var playlists: [CloudMusicApi.PlayListItem] = []
}

struct ContentView: View {
    @StateObject var playController = PlayController()
    @State private var selection: String?  // = "Now Playing"
    @StateObject private var userInfo = UserInfo()

    @State private var showPlayDetail = false

    var body: some View {
        ZStack(
            alignment: Alignment(horizontal: .trailing, vertical: .bottom),
            content: {
                NavigationSplitView {
                    List(selection: $selection) {
                        NavigationLink(
                            destination: AccountView()
                                .environmentObject(userInfo)
                                .environmentObject(playController)
                                .navigationTitle("Account")
                        ) {
                            Label(
                                "Account", systemImage: "person.crop.circle")
                        }.tag("Account")

                        NavigationLink(
                            destination: NowPlayingView()
                                .environmentObject(playController)
                                .navigationTitle("Now Playing")
                        ) {
                            Label("Now Playing", systemImage: "dot.radiowaves.left.and.right")
                        }.tag("Now Playing")

                        NavigationLink(
                            destination: ExploreView()
                                .environmentObject(userInfo)
                                .environmentObject(playController)
                                .navigationTitle("Explore")
                        ) {
                            Label("Explore", systemImage: "music.house")
                        }.tag("Explore")

                        #if DEBUG
                            NavigationLink(
                                destination: PlayerView()
                                    .environmentObject(playController)
                                    .navigationTitle("Debug")
                            ) {
                                Label("Debug", systemImage: "skew")
                            }.tag("Debug")
                        #endif

                        if userInfo.profile != nil {
                            Section(header: Text("Created Playlists")) {
                                ForEach(userInfo.playlists.filter { !$0.subscribed }) { playlist in
                                    let metadata = PlaylistMetadata.netease(
                                        playlist.id, playlist.name)
                                    NavigationLink(
                                        destination: PlayListView(
                                            playlistMetadata: metadata
                                        )
                                        .environmentObject(playController)
                                        .environmentObject(userInfo)
                                    ) {
                                        Label(playlist.name, systemImage: "music.note.list")
                                    }
                                }
                            }

                            Section(header: Text("Favored Playlists")) {
                                ForEach(userInfo.playlists.filter { $0.subscribed }) { playlist in
                                    let metadata = PlaylistMetadata.netease(
                                        playlist.id, playlist.name)
                                    NavigationLink(
                                        destination: PlayListView(
                                            playlistMetadata: metadata
                                        )
                                        .environmentObject(playController)
                                        .environmentObject(userInfo)
                                    ) {
                                        Label(playlist.name, systemImage: "music.note.list")
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(SidebarListStyle())
                    .frame(minWidth: 200, idealWidth: 250)
                    // .toolbar(removing: .sidebarToggle)
                } detail: {
                }
                .padding(.bottom, 80)
                .toolbar {}
                .onAppear {
                    DispatchQueue.main.async {
                        Task {
                            try await Task.sleep(for: .seconds(0.01))
                            selection = "Account"
                        }
                    }
                }

                PlayerControlView(showPlayDetail: $showPlayDetail)
                    .environmentObject(playController)
                    .environmentObject(userInfo)
                    .frame(height: 80)
                    .overlay(
                        Rectangle()
                            .frame(height: 1)
                            .foregroundStyle(
                                Color(red: 0.925, green: 0.925, blue: 0.925)
                            ),
                        alignment: .top
                    )
                    .background(Color.white)
                    .frame(minWidth: 800)
                // .fullScreenCover(isPresented: $showPlayDetail) {
                //     PlayingDetailView()
                // }
            }
        )
        .onKeyPress { press in
            if press.characters == " " {
                DispatchQueue.main.async {
                    Task { await playController.togglePlayPause() }
                }
                return .handled
            }
            return .ignored
        }
        .onAppear {
            Task {
                await initUserData(userInfo: userInfo)
            }

            Task {
                await playController.loadState(continuePlaying: false)
            }
        }
    }
}

#Preview {
    ContentView()
}
