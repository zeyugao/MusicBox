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

func encodeObjToJSON<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    if let data = try? encoder.encode(value) {
        return String(data: data, encoding: .utf8) ?? "{}"
    }
    return "{}"
}

func decodeJSONToObj<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
    if let data = json.data(using: .utf8) {
        let decoder = JSONDecoder()
        return try? decoder.decode(type, from: data)
    }
    return nil
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

enum Sidebar: Hashable {
    case account
    case nowPlaying
    case explore
    case debug
    case playlist(playlist: CloudMusicApi.PlayListItem)
}

struct TextWithImage: View {
    var text: String
    var image: String?

    init(_ text: String, image: String? = nil) {
        self.text = text
        self.image = image
    }

    var body: some View {
        HStack {
            if let image = image {
                Image(systemName: image)
                    .foregroundStyle(.blue)
            }
            Text(text)
        }
    }
}

class PlayingDetailModel: ObservableObject {
    @Published var isPresented = false
    private var openPlayingDetailObserver: NSObjectProtocol?
    private var closePlayingDetailObserver: NSObjectProtocol?
    private var togglePlayingDetailObserver: NSObjectProtocol?
    static let openPlayingDetailName = Notification.Name("openPlayingDetail")
    static let closePlayingDetailName = Notification.Name("closePlayingDetail")
    static let togglePlayingDetailName = Notification.Name("togglePlayingDetail")

    static func togglePlayingDetail() {
        NotificationCenter.default.post(name: togglePlayingDetailName, object: nil)
    }

    static func openPlayingDetail() {
        NotificationCenter.default.post(name: openPlayingDetailName, object: nil)
    }

    static func closePlayingDetail() {
        NotificationCenter.default.post(name: closePlayingDetailName, object: nil)
    }

    init() {
        let notificationCenter = NotificationCenter.default
        openPlayingDetailObserver = notificationCenter.addObserver(
            forName: PlayingDetailModel.openPlayingDetailName,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.isPresented = true
        }

        closePlayingDetailObserver = notificationCenter.addObserver(
            forName: PlayingDetailModel.closePlayingDetailName,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.isPresented = false
        }

        togglePlayingDetailObserver = notificationCenter.addObserver(
            forName: PlayingDetailModel.togglePlayingDetailName,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.isPresented.toggle()
        }
    }

    deinit {
        if let obs = openPlayingDetailObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = closePlayingDetailObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = togglePlayingDetailObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }
}

struct ContentView: View {
    @StateObject var playController = PlayController()
    @State private var selection: Sidebar = .nowPlaying
    @StateObject private var userInfo = UserInfo()
    @StateObject private var playingDetailModel = PlayingDetailModel()

    var body: some View {
        ZStack(
            alignment: Alignment(horizontal: .trailing, vertical: .bottom),
            content: {

                NavigationSplitView {
                    List(selection: $selection) {
                        TextWithImage("Account", image: "person.crop.circle")
                            .tag(Sidebar.account)
                        TextWithImage("Now Playing", image: "dot.radiowaves.left.and.right")
                            .tag(Sidebar.nowPlaying)
                        TextWithImage("Explore", image: "music.house")
                            .tag(Sidebar.explore)
                        #if DEBUG
                            TextWithImage("Debug", image: "skew")
                                .tag(Sidebar.debug)
                        #endif

                        if userInfo.profile != nil {
                            Section(header: Text("Created Playlists")) {
                                ForEach(userInfo.playlists.filter { !$0.subscribed }) {
                                    playlist in
                                    TextWithImage(playlist.name, image: "music.note.list")
                                        .tag(Sidebar.playlist(playlist: playlist))
                                }
                            }

                            Section(header: Text("Favored Playlists")) {
                                ForEach(userInfo.playlists.filter { $0.subscribed }) {
                                    playlist in
                                    TextWithImage(playlist.name, image: "music.note.list")
                                        .tag(Sidebar.playlist(playlist: playlist))
                                }
                            }
                        }
                    }
                    .listStyle(SidebarListStyle())
                    .frame(minWidth: 200, idealWidth: 250)
                } detail: {
                    if playingDetailModel.isPresented {
                        PlayingDetailView()
                            .environmentObject(playController)
                            .navigationTitle("Detail")
                    } else {
                        switch selection {
                        case .account:
                            AccountView()
                                .environmentObject(userInfo)
                                .environmentObject(playController)
                                .navigationTitle("Account")
                        case .nowPlaying:
                            NowPlayingView()
                                .environmentObject(playController)
                                .navigationTitle("Now Playing")
                        case .explore:
                            ExploreView()
                                .environmentObject(userInfo)
                                .environmentObject(playController)
                                .navigationTitle("Explore")
                        case .debug:
                            DebugView()
                                .environmentObject(playController)
                                .navigationTitle("Debug")
                        case let .playlist(playlist):
                            let metadata = PlaylistMetadata.netease(playlist.id, playlist.name)
                            PlayListView(playlistMetadata: metadata)
                                .environmentObject(userInfo)
                                .environmentObject(playController)
                                .navigationTitle(playlist.name)
                        }
                    }
                }
                .onChange(of: selection) {
                    if playingDetailModel.isPresented {
                        PlayingDetailModel.closePlayingDetail()
                    }
                }
                .padding(.bottom, 80)

                PlayerControlView()
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
            }
        )
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
