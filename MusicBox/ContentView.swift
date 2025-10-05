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

// MARK: - JSON Utilities
struct JSONUtils {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func encodeToJSON<T: Encodable>(_ value: T) -> String {
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func decodeFromJSON<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    static func loadDecodableState<T: Decodable>(forKey: String, type: T.Type) -> T? {
        guard let savedData = UserDefaults.standard.object(forKey: forKey) as? Data else {
            return nil
        }
        return try? decoder.decode(type, from: savedData)
    }

    static func saveEncodableState<T: Encodable>(forKey: String, data: T) {
        guard let encoded = try? encoder.encode(data) else { return }
        UserDefaults.standard.set(encoded, forKey: forKey)
    }
}

// MARK: - Legacy Function Support
func encodeObjToJSON<T: Encodable>(_ value: T) -> String {
    JSONUtils.encodeToJSON(value)
}

func decodeJSONToObj<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
    JSONUtils.decodeFromJSON(type, json)
}

func loadDecodableState<T: Decodable>(forKey: String, type: T.Type) -> T? {
    JSONUtils.loadDecodableState(forKey: forKey, type: type)
}

func saveEncodableState<T: Encodable>(forKey: String, data: T) {
    JSONUtils.saveEncodableState(forKey: forKey, data: data)
}

class UserInfo: ObservableObject {
    @Published var profile: CloudMusicApi.Profile?
    @Published var likelist: Set<UInt64> = []
    @Published var playlists: [CloudMusicApi.PlayListItem] = []
}

enum NavigationScreen: Hashable, Equatable, Encodable {
    case account
    case explore
    case cloudFiles
    case playlist(playlist: PlaylistMetadata)

    enum CodingKeys: String, CodingKey {
        case account, explore, playlist
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .account:
            try container.encode("account", forKey: .account)
        case .explore:
            try container.encode("explore", forKey: .explore)
        case .playlist:
            try container.encode("playlist", forKey: .playlist)
        case .cloudFiles:
            break  // Handle if needed
        }
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

struct PlaylistRowView: View {
    let playlist: CloudMusicApi.PlayListItem

    var body: some View {
        HStack {
            AsyncImageWithCache(url: URL(string: playlist.coverImgUrl.https)) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading) {
                HStack(spacing: 4) {
                    if playlist.privacy != 0 {
                        Image(systemName: "lock.fill")
                            .foregroundColor(.secondary)
                            .font(.body)
                    }
                    Text(playlist.name)
                        .font(.body)
                        .lineLimit(1)
                }
                Text("\(playlist.trackCount ?? 0)首 • \(playlist.creator.nickname)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 2)
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

    @MainActor
    func togglePlayingDetail() {
        isPresented.toggle()
    }

    @MainActor
    func openPlayingDetail() {
        isPresented = true
    }

    @MainActor
    func closePlayingDetail() {
        isPresented = false
    }
}

class AlertModal: ObservableObject {
    @Published var text: String = ""
    @Published var title: String = ""
    @Published var showSaveOption: Bool = false
    @Published var saveCallback: (() -> Void)?

    static let showAlertName = Notification.Name("showAlertName")
    static let showAlertWithSaveName = Notification.Name("showAlertWithSaveName")

    // Static property to hold the callback
    static var pendingSaveCallback: (() -> Void)?

    static func showAlert(_ title: String, _ text: String) {
        NotificationCenter.default.post(
            name: AlertModal.showAlertName,
            object: nil,
            userInfo: [
                "title": title,
                "text": text,
            ]
        )
    }

    static func showAlert(_ text: String) {
        showAlert("Alert", text)
    }

    static func showAlertWithSaveOption(
        _ title: String, _ text: String, saveCallback: @escaping () -> Void
    ) {
        // Store the callback in a static property
        pendingSaveCallback = saveCallback

        NotificationCenter.default.post(
            name: AlertModal.showAlertWithSaveName,
            object: nil,
            userInfo: [
                "title": title,
                "text": text,
            ]
        )
    }

    init() {
        NotificationCenter.default.addObserver(
            forName: AlertModal.showAlertName,
            object: nil,
            queue: OperationQueue.main
        ) { [weak self] notification in
            if let title = notification.userInfo?["title"] as? String {
                self?.title = title
            } else {
                self?.title = "Alert"
            }
            if let text = notification.userInfo?["text"] as? String {
                self?.text = text
            }
            self?.showSaveOption = false
            self?.saveCallback = nil
        }

        NotificationCenter.default.addObserver(
            forName: AlertModal.showAlertWithSaveName,
            object: nil,
            queue: OperationQueue.main
        ) { [weak self] notification in
            if let title = notification.userInfo?["title"] as? String {
                self?.title = title
            } else {
                self?.title = "Alert"
            }
            if let text = notification.userInfo?["text"] as? String {
                self?.text = text
            }
            // Get the callback from the static property
            self?.saveCallback = AlertModal.pendingSaveCallback
            self?.showSaveOption = true
        }
    }
}

struct ContentView: View {
    @StateObject var playlistStatus = PlaylistStatus()
    @StateObject var playStatus = PlayStatus()
    @State private var selection: NavigationScreen = .explore
    @StateObject private var userInfo = UserInfo()
    @StateObject private var playingDetailModel = PlayingDetailModel()
    @StateObject private var appSettings = AppSettings.shared

    @StateObject private var alertModel = AlertModal()

    @State private var isInitialized = false

    private var currentSelection: NavigationScreen {
        userInfo.profile == nil ? .account : selection
    }

    private var selectionBinding: Binding<NavigationScreen> {
        Binding(
            get: { currentSelection },
            set: { newValue in
                // Only update selection if user is not logged in
                if userInfo.profile != nil {
                    selection = newValue
                }
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selectionBinding) {
                Section(header: Text("General")) {
                    if userInfo.profile != nil {
                        TextWithImage("Explore", image: "music.house")
                            .tag(NavigationScreen.explore)
                    }
                    TextWithImage("Settings", image: "gearshape.fill")
                        .tag(NavigationScreen.account)
                    if userInfo.profile != nil {
                        TextWithImage("My Cloud Files", image: "icloud")
                            .tag(NavigationScreen.cloudFiles)
                    }
                }

                if userInfo.profile != nil {
                    Section(header: Text("Created Playlists")) {
                        ForEach(userInfo.playlists.filter { !$0.subscribed }) {
                            playlist in
                            let metadata = PlaylistMetadata.netease(
                                playlist.id, playlist.name)
                            PlaylistRowView(playlist: playlist)
                                .tag(NavigationScreen.playlist(playlist: metadata))
                        }
                    }

                    Section(header: Text("Favored Playlists")) {
                        ForEach(userInfo.playlists.filter { $0.subscribed }) {
                            playlist in
                            let metadata = PlaylistMetadata.netease(
                                playlist.id, playlist.name)
                            PlaylistRowView(playlist: playlist)
                                .tag(NavigationScreen.playlist(playlist: metadata))
                        }
                    }
                }
            }
            .listStyle(SidebarListStyle())
            .frame(minWidth: 200, idealWidth: 250)
        } detail: {
            ZStack(alignment: .bottom) {
                switch currentSelection {
                case .account:
                    if isInitialized {
                        AccountView()
                            .environmentObject(userInfo)
                            .environmentObject(playlistStatus)
                            .environmentObject(appSettings)
                            .navigationTitle("Settings")
                    } else {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .cloudFiles:
                    CloudFilesView()
                        .environmentObject(userInfo)
                        .navigationTitle("My Cloud Files")
                case .explore:
                    ExploreView(isInitialized: isInitialized)
                        .environmentObject(userInfo)
                        .environmentObject(playlistStatus)
                        .navigationTitle("Explore")
                case let .playlist(playlist):
                    let metadata = PlaylistMetadata.netease(
                        playlist.id, playlist.name)
                    PlayListView(playlistMetadata: metadata)
                        .environmentObject(userInfo)
                        .environmentObject(playlistStatus)
                        .navigationTitle(playlist.name)
                }

                // Floating PlayerControlView
                PlayerControlView()
                    .environmentObject(playlistStatus)
                    .environmentObject(playStatus)
                    .environmentObject(userInfo)
                    .environmentObject(playingDetailModel)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
            }
            .inspector(isPresented: $playingDetailModel.isPresented) {
                PlayingDetailView()
                    .environmentObject(playStatus)
                    .environmentObject(playlistStatus)
                    .environmentObject(appSettings)
            }
        }
        .task {
            // Connect PlayStatus with PlayingDetailModel before loading state
            playStatus.setPlayingDetailModel(playingDetailModel)

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await initUserData(userInfo: userInfo)
                }
                group.addTask {
                    // Load playlist first, then load play status
                    await playlistStatus.loadState()
                    await playStatus.loadState()
                }

                // Wait for all tasks to complete
                await group.waitForAll()
            }

            // Initialize Now Playing Center after everything is loaded
            // This ensures system media controls work from app startup
            playStatus.nowPlayingInit()

            // Re-register remote commands to ensure they work reliably from startup
            // This helps ensure media keys work immediately when the app launches
            playlistStatus.reinitializeRemoteCommands()

            isInitialized = true
        }
        .alert(
            isPresented: Binding<Bool>(
                get: { !alertModel.text.isEmpty },
                set: {
                    if !$0 {
                        alertModel.text = ""
                        alertModel.title = ""
                        alertModel.showSaveOption = false
                        alertModel.saveCallback = nil
                        // Clear the static callback when alert is dismissed
                        AlertModal.pendingSaveCallback = nil
                    }
                }
            )
        ) {
            if alertModel.showSaveOption {
                Alert(
                    title: Text(alertModel.title),
                    message: Text(alertModel.text),
                    primaryButton: .default(Text("Save to File")) {
                        alertModel.saveCallback?()
                    },
                    secondaryButton: .cancel(Text("OK"))
                )
            } else {
                Alert(title: Text(alertModel.title), message: Text(alertModel.text))
            }
        }
    }
}

#Preview {
    ContentView()
}
