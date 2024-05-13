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
    @Published var playlists: [CloudMusicApi.PlayListItem] = []
}

struct ContentView: View {
    @StateObject var playController = PlayController()
    @State private var selection: String?  // = "Now Playing"
    @StateObject private var userInfo = UserInfo()

    var body: some View {
        ZStack(
            alignment: Alignment(horizontal: .trailing, vertical: .bottom),
            content: {
                NavigationSplitView {
                    AccountHeaderView()
                        .environmentObject(userInfo)
                    List(selection: $selection) {
                        if userInfo.profile == nil {
                            Section(header: Text("Account")) {
                                NavigationLink(
                                    destination: LoginView()
                                        .environmentObject(playController)
                                        .navigationTitle("Login")
                                ) {
                                    Label(
                                        "Login", systemImage: "person.crop.circle")
                                }.tag("Login")
                            }
                        }

                        Section(header: Text("Music")) {
                            NavigationLink(
                                destination: NowPlayingView()
                                    .environmentObject(playController)
                                    .navigationTitle("Now Playing")
                            ) {
                                Label("Now Playing", systemImage: "dot.radiowaves.left.and.right")
                            }.tag("Now Playing")

                            NavigationLink(
                                destination: PlayerView()
                                    .environmentObject(playController)
                                    .navigationTitle("Debug")
                            ) {
                                Label("Debug", systemImage: "skew")
                            }.tag("Debug")
                        }

                        Section(header: Text("Created Playlists")) {
                            ForEach(userInfo.playlists.filter { !$0.subscribed }) { playlist in
                                NavigationLink(
                                    destination: PlayListView(neteasePlaylist: playlist)
                                        .environmentObject(playController)
                                        .environmentObject(userInfo)
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
                    .toolbar(removing: .sidebarToggle)
                } detail: {
                    Text("Hello")
                }
                .navigationTitle("Home")
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
                    .frame(minWidth: 800)
            }
        )
        .onAppear {
            Task {
                if let profile = loadDecodableState(
                    forKey: "profile", type: CloudMusicApi.Profile.self)
                {
                    userInfo.profile = profile
                }

                if let playlists = loadDecodableState(
                    forKey: "playlists", type: [CloudMusicApi.PlayListItem].self)
                {
                    userInfo.playlists = playlists
                }

                if let profile = await CloudMusicApi.login_status() {
                    userInfo.profile = profile
                    saveEncodableState(forKey: "profile", data: profile)

                    if let playlists = try? await CloudMusicApi.user_playlist(uid: profile.userId) {
                        userInfo.playlists = playlists
                        saveEncodableState(forKey: "playlists", data: playlists)
                    }
                }
            }

            Task {
                playController.loadState(continuePlaying: false)
            }
        }
    }
}

#Preview {
    ContentView()
}
