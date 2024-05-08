//
//  ContentView.swift
//  MusicBox
//
//  Created by Elsa on 2024/4/16.
//

import Combine
import Foundation
import SwiftUI

//class PlaylistItemTest: Identifiable {
//    let id = UUID()
//    let name: String
//    var children: [PlaylistItemTest]?
//
//    init(name: String, children: [PlaylistItemTest]? = nil) {
//        self.name = name
//        self.children = children
//    }
//}

class UserInfo: ObservableObject {
    @Published var profile: CloudMusicApi.Profile?
    @Published var playlists: [CloudMusicApi.PlayListItem] = []
}

struct ContentView: View {
    @StateObject var playController = PlayController()
    @State private var selection: String = "Home"
    @StateObject private var userInfo = UserInfo()

    var body: some View {
        ZStack(
            alignment: Alignment(horizontal: .trailing, vertical: .bottom),
            content: {
                NavigationSplitView {
                    List(selection: $selection) {
                        Section(header: Text("Apple Music")) {
                            NavigationLink(
                                destination: HomeContentView()
                                    .environmentObject(playController)
                                    .environmentObject(userInfo)
                                    .navigationTitle("Home")
                            ) {
                                Label("Home", systemImage: "house.fill")
                            }.tag("Home")
                            
                            NavigationLink(
                                destination: PlayerView()
                                    .environmentObject(playController)
                                    .navigationTitle("Player")
                            ) {
                                Label("Player", systemImage: "dot.radiowaves.left.and.right")
                            }.tag("Player")
                            
                            NavigationLink(
                                destination: NowPlayingView()
                                    .environmentObject(playController)
                                    .navigationTitle("Now Playing")
                            ) {
                                Label("Now Playing", systemImage: "dot.radiowaves.left.and.right")
                            }.tag("Now Playing")
                        }

                        Section(header: Text("Library")) {
                            NavigationLink(destination: Text("Recently Added View")) {
                                Label("Recently Added", systemImage: "clock.fill")
                            }.tag("Recently Added")

                            NavigationLink(destination: Text("Artists View")) {
                                Label("Artists", systemImage: "music.mic")
                            }.tag("Artists")

                            NavigationLink(destination: Text("Albums View")) {
                                Label("Albums", systemImage: "rectangle.stack.fill")
                            }.tag("Albums")

                            NavigationLink(destination: Text("Songs View")) {
                                Label("Songs", systemImage: "music.note.list")
                            }.tag("Songs")
                        }

                        Section(header: Text("Created Playlists")) {
                            ForEach(userInfo.playlists.filter { !$0.subscribed }) { playlist in
                                NavigationLink(
                                    destination: PlayListView(neteasePlaylist: playlist)
                                        .environmentObject(playController)
                                ) {
                                    Label(playlist.name, systemImage: "music.note.list")
                                }
                            }
                        }

                        Section(header: Text("Favored Playlists")) {
                            ForEach(userInfo.playlists.filter { $0.subscribed }) { playlist in
                                NavigationLink(
                                    destination: Text("Favored Playlist Detail View")
                                ) {
                                    Label(playlist.name, systemImage: "music.note.list")
                                }
                            }
                        }
                    }
                    .listStyle(SidebarListStyle())
                    .frame(minWidth: 200, idealWidth: 250)
                } detail: {
                    Text("Hello")
                }
                .navigationTitle("Home")
                .toolbar {
                }
                .searchable(text: .constant(""), prompt: "Search")
                .padding(.bottom, 80)

                PlayerControlView()
                    .environmentObject(playController)
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
            }
        )
        .onAppear {
            Task {
                if let profile = await CloudMusicApi.login_status() {
                    userInfo.profile = profile

                    if let playlists = try? await CloudMusicApi.user_playlist(uid: profile.userId) {
                        userInfo.playlists = playlists
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
