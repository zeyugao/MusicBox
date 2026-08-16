import Foundation
import Observation

struct PlaylistDestination: Hashable, Codable, Identifiable {
    let id: UInt64
    let name: String
}

enum AppRoute: Hashable, Codable {
    case account
    case explore
    case cloudFiles
    case playlist(PlaylistDestination)
}

struct PlaylistLocateRequest: Equatable, Identifiable {
    let id = UUID()
    let playlistID: UInt64
    let songID: UInt64
}

@MainActor
@Observable
final class AppRouter {
    private static let selectionKey = "AppRouter.selectedRoute"
    private let defaults: UserDefaults

    var selectedRoute: AppRoute {
        didSet { save() }
    }
    var isLyricsPresented = false
    var playlistLocateRequest: PlaylistLocateRequest?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.selectionKey),
            let route = try? JSONDecoder().decode(AppRoute.self, from: data)
        {
            selectedRoute = route
        } else {
            selectedRoute = .explore
        }
    }

    func showPlaylist(_ playlist: PlaylistDestination, songID: UInt64? = nil) {
        playlistLocateRequest = songID.map { PlaylistLocateRequest(playlistID: playlist.id, songID: $0) }
        selectedRoute = .playlist(playlist)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(selectedRoute) else { return }
        defaults.set(data, forKey: Self.selectionKey)
    }
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?
}

@MainActor
@Observable
final class AlertCenter {
    var current: AppAlert?

    func show(_ message: String, title: String = String(localized: "alert.title")) {
        current = AppAlert(title: title, message: message, actionTitle: nil, action: nil)
    }

    func show(
        _ message: String,
        title: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) {
        current = AppAlert(title: title, message: message, actionTitle: actionTitle, action: action)
    }

    func dismiss() {
        current = nil
    }
}

enum TransferPhase: Equatable {
    case running
    case succeeded
    case failed(String)
}

struct TransferJob: Identifiable, Equatable {
    let id: UUID
    let name: String
    var phase: TransferPhase
}

@MainActor
@Observable
final class TransferCenter {
    private(set) var jobs: [TransferJob] = []

    func begin(name: String) -> UUID {
        let id = UUID()
        jobs.append(TransferJob(id: id, name: name, phase: .running))
        return id
    }

    func complete(_ id: UUID) {
        update(id, phase: .succeeded)
    }

    func fail(_ id: UUID, message: String) {
        update(id, phase: .failed(message))
    }

    private func update(_ id: UUID, phase: TransferPhase) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].phase = phase
    }
}

@MainActor
@Observable
final class AccountStore {
    private enum Key {
        static let profile = "profile"
        static let playlists = "playlists"
        static let likes = "likelist"
    }

    private let repository: any AccountRepository
    private let defaults: UserDefaults
    var profile: CloudMusicApi.Profile?
    var playlists: [CloudMusicApi.PlayListItem]
    var likedSongIDs: Set<UInt64>
    var isRefreshing = false
    var errorMessage: String?

    init(repository: any AccountRepository, defaults: UserDefaults = .standard) {
        self.repository = repository
        self.defaults = defaults
        profile = Self.decode(CloudMusicApi.Profile.self, key: Key.profile, defaults: defaults)
        playlists = Self.decode([CloudMusicApi.PlayListItem].self, key: Key.playlists, defaults: defaults) ?? []
        likedSongIDs = Self.decode(Set<UInt64>.self, key: Key.likes, defaults: defaults) ?? []
    }

    func refresh() async {
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }
        guard let profile = await repository.loginStatus() else {
            self.profile = nil
            playlists = []
            likedSongIDs = []
            save()
            return
        }
        self.profile = profile
        async let fetchedPlaylists = try? repository.userPlaylists(for: profile.userId)
        async let fetchedLikes = repository.likedSongIDs(for: profile.userId)
        playlists = await fetchedPlaylists ?? []
        likedSongIDs = Set(await fetchedLikes ?? [])
        save()
    }

    func refreshPlaylists() async {
        guard let profile else { return }
        do {
            playlists = try await repository.userPlaylists(for: profile.userId) ?? []
            save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setLiked(_ songID: UInt64, liked: Bool) async throws {
        try await repository.setLiked(songID: songID, liked: liked)
        if liked {
            likedSongIDs.insert(songID)
        } else {
            likedSongIDs.remove(songID)
        }
        save()
    }

    func signOut() async {
        await repository.logout()
        profile = nil
        playlists = []
        likedSongIDs = []
        save()
    }

    private func save() {
        Self.encode(profile, key: Key.profile, defaults: defaults)
        Self.encode(playlists, key: Key.playlists, defaults: defaults)
        Self.encode(likedSongIDs, key: Key.likes, defaults: defaults)
    }

    private static func encode<T: Encodable>(_ value: T?, key: String, defaults: UserDefaults = .standard) {
        guard let value else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func decode<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

@MainActor
@Observable
final class AppModel {
    let repository: any MusicRepository
    let account: AccountStore
    let router: AppRouter
    let alerts: AlertCenter
    let transfers: TransferCenter
    let settings: AppSettings
    let playback: PlaybackStore
    let reporting: PlaybackReportingCoordinator
    private let systemPlayback: SystemPlaybackBridge
    private var playbackListener: UUID?
    private var playlistRefreshTask: Task<Void, Never>?

    var isStarted = false

    convenience init() {
        self.init(repository: NeteaseMusicRepository())
    }

    init(repository: any MusicRepository) {
        let playbackStore = PlaybackStore(repository: repository)
        let reportingCoordinator = PlaybackReportingCoordinator(repository: repository)
        let alertCenter = AlertCenter()
        let appSettings = AppSettings()
        self.repository = repository
        account = AccountStore(repository: repository)
        router = AppRouter()
        alerts = alertCenter
        transfers = TransferCenter()
        settings = appSettings
        playback = playbackStore
        reporting = reportingCoordinator
        systemPlayback = SystemPlaybackBridge(playback: playbackStore)
        CommentsWindowManager.shared.configure(repository: repository)

        reportingCoordinator.onError = { [weak alertCenter] message in
            alertCenter?.show(message)
        }
        playbackListener = playbackStore.addEventListener { [weak reportingCoordinator, weak appSettings] event in
            guard let reportingCoordinator, let appSettings else { return }
            switch event {
            case .queueChanged(let snapshot):
                let items = snapshot.source.map(\.item)
                let currentIndex = snapshot.current.flatMap { current in
                    snapshot.source.firstIndex(where: { $0.id == current.id })
                } ?? 0
                reportingCoordinator.playbackQueueDidChange(items: items, currentIndex: currentIndex, loopMode: snapshot.mode)
            case .modeChanged(let mode):
                let snapshot = playbackStore.queue.snapshot
                let items = snapshot.source.map(\.item)
                let currentIndex = snapshot.current.flatMap { current in
                    snapshot.source.firstIndex(where: { $0.id == current.id })
                } ?? 0
                reportingCoordinator.playbackModeDidChange(items: items, currentIndex: currentIndex, loopMode: mode)
            case .didStart(let item):
                reportingCoordinator.playbackDidStart(item: item)
            case let .didEnd(item, position, reason):
                reportingCoordinator.playbackDidEnd(item: item, playedSeconds: position, reason: reason)
            case .playbackChanged(let isPlaying):
                appSettings.applyPlaybackState(isPlaying: isPlaying)
            case .itemChanged, .positionChanged, .failed:
                break
            }
        }
    }

    func start() async {
        guard !isStarted else { return }
        isStarted = true
        guard !Self.isRunningTests else { return }
        CloudMusicApi.migrateLegacyAuthenticationIfNeeded()
        playback.restore()
        await refreshAccount()
        schedulePlaylistRefresh()
    }

    func refreshAccount() async {
        await account.refresh()
        if let userID = account.profile?.userId {
            await reporting.activate(accountID: userID)
        } else {
            reporting.deactivate()
        }
    }

    func signOut() async {
        playback.clearQueue()
        await account.signOut()
        reporting.deactivate()
        router.selectedRoute = .account
    }

    func acceptHandoff() async {
        await reporting.continueHandoff(using: playback)
    }

    private static var isRunningTests: Bool {
        let testBundleIsLoaded = (Bundle.allBundles + Bundle.allFrameworks).contains {
            $0.bundleURL.pathExtension == "xctest"
        }
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || testBundleIsLoaded
    }

    private func schedulePlaylistRefresh() {
        playlistRefreshTask?.cancel()
        playlistRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled, let self else { return }
                await self.account.refreshPlaylists()
            }
        }
    }

}
