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

enum NavigationScreen: Hashable, Equatable, Encodable {
    case account
    case nowPlaying
    case explore
    case playlist(playlist: PlaylistMetadata)

    enum CodingKeys: String, CodingKey {
        case account, nowPlaying, explore, playlist
    }

    func encode(to encoder: Encoder) throws {
        let _ = encoder.container(keyedBy: CodingKeys.self)
        //        var container = encoder.container(keyedBy: CodingKeys.self)
        //        switch self {
        //        case .account:
        //            try container.encode(0, forKey: .account)
        //        case .nowPlaying:
        //            try container.encode(0, forKey: .nowPlaying)
        //        case .explore:
        //            try container.encode(0, forKey: .explore)
        //        case .playlist:
        //            try container.encode(0, forKey: .playlist)
        //        }
    }
}

enum PlayingDetailPath: Hashable, Codable {
    case playing

    enum CodingKeys: String, CodingKey {
        case playing
    }

    func encode(to encoder: Encoder) throws {
        let _ = encoder.container(keyedBy: CodingKeys.self)
        //        var container = encoder.container(keyedBy: CodingKeys.self)
        //        switch self {
        //        case .playing:
        //            try container.encode(0, forKey: .playing)
        //        }
    }
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
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16)
            }
            Text(text)
        }
    }
}

// final class NavigationStore: ObservableObject {
//     @Published var path = NavigationPath()

//     private let decoder = JSONDecoder()
//     private let encoder = JSONEncoder()

//     func encoded() -> Data? {
//         try? path.codable.map(encoder.encode)
//     }

//     func restore(from data: Data) {
//         do {
//             let codable = try decoder.decode(
//                 NavigationPath.CodableRepresentation.self, from: data
//             )
//             path = NavigationPath(codable)
//         } catch {
//             path = NavigationPath()
//         }
//     }
// }

class PlayingDetailModel: ObservableObject {
    @Published var isPresented = false

    static let targetName = String(reflecting: PlayingDetailPath.self)

    func checkIsDetailFront(navigationPath: NavigationPath) {
        if let data = try? navigationPath.codable.map(JSONEncoder().encode),
            let items = data.asType([String].self)
        {
            let newIsPresented: Bool
            if items.first == Self.targetName {
                newIsPresented = true
            } else {
                newIsPresented = false
            }

            DispatchQueue.main.async {
                self.isPresented = newIsPresented
            }
        }
    }

    @MainActor
    func togglePlayingDetail(navigationPath: inout NavigationPath) {
        if isPresented {
            navigationPath.removeLast()
        } else {
            navigationPath.append(PlayingDetailPath.playing)
        }
    }

    @MainActor
    func openPlayingDetail(navigationPath: inout NavigationPath) {
        if !isPresented {
            navigationPath.append(PlayingDetailPath.playing)
        }
    }

    @MainActor
    func closePlayingDetail(navigationPath: inout NavigationPath) {
        if isPresented {
            navigationPath.removeLast()
        }
    }
}

struct ContentView: View {
    @StateObject var playController = PlayController()
    @State private var selection: NavigationScreen = .explore
    @StateObject private var userInfo = UserInfo()
    @StateObject private var playingDetailModel = PlayingDetailModel()

    @State private var navigationPath = NavigationPath()

    var body: some View {
        ZStack(
            alignment: Alignment(horizontal: .trailing, vertical: .bottom),
            content: {
                NavigationSplitView {
                    List(selection: $selection) {
                        Section(header: Text("General")) {
                            if userInfo.profile != nil {
                                TextWithImage("Explore", image: "music.house")
                                    .tag(NavigationScreen.explore)
                            }
                            TextWithImage("Account", image: "person.crop.circle")
                                .tag(NavigationScreen.account)
                            if userInfo.profile != nil {
                                TextWithImage("Now Playing", image: "dot.radiowaves.left.and.right")
                                    .tag(NavigationScreen.nowPlaying)
                            }
                        }

                        if userInfo.profile != nil {
                            Section(header: Text("Created Playlists")) {
                                ForEach(userInfo.playlists.filter { !$0.subscribed }) {
                                    playlist in
                                    let metadata = PlaylistMetadata.netease(
                                        playlist.id, playlist.name)
                                    TextWithImage(playlist.name, image: "music.note.list")
                                        .tag(NavigationScreen.playlist(playlist: metadata))
                                }
                            }

                            Section(header: Text("Favored Playlists")) {
                                ForEach(userInfo.playlists.filter { $0.subscribed }) {
                                    playlist in
                                    let metadata = PlaylistMetadata.netease(
                                        playlist.id, playlist.name)
                                    TextWithImage(playlist.name, image: "music.note.list")
                                        .tag(NavigationScreen.playlist(playlist: metadata))
                                }
                            }
                        }
                    }
                    .listStyle(SidebarListStyle())
                    .frame(minWidth: 200, idealWidth: 250)
                } detail: {
                    NavigationStack(path: $navigationPath) {
                        switch selection {
                        case .account:
                            AccountView()
                                .environmentObject(userInfo)
                                .environmentObject(playController)
                                .navigationTitle("Account")
                                .navigationDestination(for: PlayingDetailPath.self) { _ in
                                    PlayingDetailView()
                                        .environmentObject(playController)
                                }
                        case .nowPlaying:
                            NowPlayingView()
                                .environmentObject(playController)
                                .navigationTitle("Now Playing")
                                .navigationDestination(for: PlayingDetailPath.self) { _ in
                                    PlayingDetailView()
                                        .environmentObject(playController)
                                }
                        case .explore:
                            ExploreView(navigationPath: $navigationPath)
                                .environmentObject(userInfo)
                                .environmentObject(playController)
                                .navigationTitle("Explore")
                                .navigationDestination(for: PlayingDetailPath.self) { _ in
                                    PlayingDetailView()
                                        .environmentObject(playController)
                                }
                        case let .playlist(playlist):
                            let metadata = PlaylistMetadata.netease(
                                playlist.id, playlist.name)
                            PlayListView(playlistMetadata: metadata)
                                .environmentObject(userInfo)
                                .environmentObject(playController)
                                .navigationTitle(playlist.name)
                                .navigationDestination(for: PlayingDetailPath.self) { _ in
                                    PlayingDetailView()
                                        .environmentObject(playController)
                                }
                        }
                    }
                }
                .onChange(of: navigationPath) { _, newValue in
                    playingDetailModel.checkIsDetailFront(navigationPath: newValue)
                }
                .padding(.bottom, 80)

                PlayerControlView(navigationPath: $navigationPath)
                    .environmentObject(playController)
                    .environmentObject(userInfo)
                    .environmentObject(playingDetailModel)
                    .frame(height: 80)
                    .background(Color(nsColor: NSColor.textBackgroundColor))
                    .frame(minWidth: 800)
            }
        )
        .task {
            async let initUserDataTask: () = initUserData(userInfo: userInfo)
            async let loadStateTask: () = playController.loadState(continuePlaying: false)

            await initUserDataTask
            await loadStateTask
        }
    }
}

#Preview {
    ContentView()
}
