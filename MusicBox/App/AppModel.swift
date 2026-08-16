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

enum TransferDirection: String, CaseIterable, Equatable, Sendable {
    case upload
    case download
}

enum TransferStage: Equatable, Sendable {
    case preparing
    case transferring
    case finalizing
}

struct TransferProgress: Equatable, Sendable {
    let completedBytes: Int64
    let totalBytes: Int64?
    let stage: TransferStage

    var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(max(Double(completedBytes) / Double(totalBytes), 0), 1)
    }
}

typealias TransferProgressHandler = @Sendable (TransferProgress) -> Void

enum TransferPhase: Equatable {
    case waiting
    case running
    case succeeded
    case failed(String)
    case cancelled

    var isFinished: Bool {
        switch self {
        case .succeeded, .failed, .cancelled:
            true
        case .waiting, .running:
            false
        }
    }
}

struct TransferJob: Identifiable, Equatable {
    let id: UUID
    let direction: TransferDirection
    let name: String
    var phase: TransferPhase
    var progress: TransferProgress?
    fileprivate var attempt: Int
}

@MainActor
@Observable
final class TransferCenter {
    typealias UploadOperation = @MainActor (
        _ fileURL: URL,
        _ title: String?,
        _ artist: String?,
        _ album: String?,
        _ progress: @escaping TransferProgressHandler
    ) async throws -> Void
    typealias DownloadOperation = @MainActor (
        _ item: PlaylistItem,
        _ progress: @escaping TransferProgressHandler
    ) async throws -> Void

    private enum Payload {
        case upload(fileURL: URL, title: String?, artist: String?, album: String?)
        case download(PlaylistItem)
    }

    private let uploadOperation: UploadOperation
    private let downloadOperation: DownloadOperation
    private var payloads: [UUID: Payload] = [:]
    private var uploadWorker: Task<Void, Never>?
    private var downloadWorker: Task<Void, Never>?

    private(set) var jobs: [TransferJob] = []

    init(repository: any PlaylistRepository) {
        let resolver = AudioSourceResolver(repository: repository)
        uploadOperation = { fileURL, title, artist, album, progress in
            _ = try await repository.uploadCloudFile(
                fileURL,
                title: title,
                artist: artist,
                album: album,
                progress: progress
            )
        }
        downloadOperation = { item, progress in
            _ = try await resolver.download(item, progress: progress)
        }
    }

    init(
        upload: @escaping UploadOperation,
        download: @escaping DownloadOperation
    ) {
        uploadOperation = upload
        downloadOperation = download
    }

    var hasJobs: Bool { !jobs.isEmpty }

    func hasPendingJobs(in direction: TransferDirection) -> Bool {
        jobs.contains { $0.direction == direction && !$0.phase.isFinished }
    }

    func enqueueUpload(
        fileURL: URL,
        title: String?,
        artist: String?,
        album: String?
    ) {
        let id = UUID()
        jobs.append(
            TransferJob(
                id: id,
                direction: .upload,
                name: fileURL.lastPathComponent,
                phase: .waiting,
                progress: nil,
                attempt: 0
            )
        )
        payloads[id] = .upload(
            fileURL: fileURL,
            title: title,
            artist: artist,
            album: album
        )
        startWorker(for: .upload)
    }

    func enqueueDownloads(_ items: [PlaylistItem]) {
        for item in items {
            let id = UUID()
            jobs.append(
                TransferJob(
                    id: id,
                    direction: .download,
                    name: item.title,
                    phase: .waiting,
                    progress: nil,
                    attempt: 0
                )
            )
            payloads[id] = .download(item)
        }
        startWorker(for: .download)
    }

    func cancel(_ direction: TransferDirection) {
        worker(for: direction)?.cancel()
        for index in jobs.indices where jobs[index].direction == direction {
            if jobs[index].phase == .waiting {
                jobs[index].phase = .cancelled
            }
        }
    }

    func retry(_ id: UUID) {
        guard payloads[id] != nil,
            let index = jobs.firstIndex(where: { $0.id == id }),
            jobs[index].phase.isFinished
        else { return }
        jobs[index].attempt += 1
        jobs[index].phase = .waiting
        jobs[index].progress = nil
        startWorker(for: jobs[index].direction)
    }

    func clearFinished() {
        let removedIDs = Set(jobs.filter { $0.phase.isFinished }.map(\.id))
        jobs.removeAll { removedIDs.contains($0.id) }
        for id in removedIDs {
            payloads[id] = nil
        }
    }

    func clearFinished(in direction: TransferDirection) {
        let removedIDs = Set(
            jobs.filter { $0.direction == direction && $0.phase.isFinished }.map(\.id)
        )
        jobs.removeAll { removedIDs.contains($0.id) }
        for id in removedIDs {
            payloads[id] = nil
        }
    }

    private func startWorker(for direction: TransferDirection) {
        guard worker(for: direction) == nil,
            jobs.contains(where: { $0.direction == direction && $0.phase == .waiting })
        else { return }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.processQueue(direction)
        }
        setWorker(task, for: direction)
    }

    private func processQueue(_ direction: TransferDirection) async {
        defer {
            setWorker(nil, for: direction)
            startWorker(for: direction)
        }

        while !Task.isCancelled,
            let index = jobs.firstIndex(where: { $0.direction == direction && $0.phase == .waiting })
        {
            let id = jobs[index].id
            let attempt = jobs[index].attempt
            guard let payload = payloads[id] else {
                jobs[index].phase = .failed(String(localized: "transfer.error.missing_operation"))
                continue
            }

            jobs[index].phase = .running
            jobs[index].progress = TransferProgress(
                completedBytes: 0,
                totalBytes: initialTotalBytes(for: payload),
                stage: .preparing
            )

            let progress: TransferProgressHandler = { [weak self] value in
                Task { @MainActor [weak self] in
                    self?.updateProgress(id: id, attempt: attempt, value: value)
                }
            }

            do {
                switch payload {
                case .upload(let fileURL, let title, let artist, let album):
                    try await uploadOperation(fileURL, title, artist, album, progress)
                case .download(let item):
                    try await downloadOperation(item, progress)
                }
                try Task.checkCancellation()
                finish(id: id, attempt: attempt, phase: .succeeded)
            } catch is CancellationError {
                finish(id: id, attempt: attempt, phase: .cancelled)
                break
            } catch {
                if Task.isCancelled {
                    finish(id: id, attempt: attempt, phase: .cancelled)
                    break
                }
                finish(id: id, attempt: attempt, phase: .failed(error.localizedDescription))
            }
        }
    }

    private func updateProgress(id: UUID, attempt: Int, value: TransferProgress) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
            jobs[index].attempt == attempt,
            jobs[index].phase == .running
        else { return }

        let previous = jobs[index].progress
        let total = value.totalBytes.flatMap { $0 > 0 ? $0 : nil } ?? previous?.totalBytes
        let completed = min(
            max(value.completedBytes, previous?.completedBytes ?? 0),
            total ?? Int64.max
        )
        let stage = stageRank(value.stage) >= stageRank(previous?.stage)
            ? value.stage
            : previous?.stage ?? value.stage
        jobs[index].progress = TransferProgress(
            completedBytes: completed,
            totalBytes: total,
            stage: stage
        )
    }

    private func finish(id: UUID, attempt: Int, phase: TransferPhase) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].attempt == attempt else { return }
        jobs[index].phase = phase
    }

    private func initialTotalBytes(for payload: Payload) -> Int64? {
        guard case .upload(let fileURL, _, _, _) = payload else { return nil }
        return try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
    }

    private func stageRank(_ stage: TransferStage?) -> Int {
        switch stage {
        case .preparing, nil: 0
        case .transferring: 1
        case .finalizing: 2
        }
    }

    private func worker(for direction: TransferDirection) -> Task<Void, Never>? {
        switch direction {
        case .upload: uploadWorker
        case .download: downloadWorker
        }
    }

    private func setWorker(_ task: Task<Void, Never>?, for direction: TransferDirection) {
        switch direction {
        case .upload: uploadWorker = task
        case .download: downloadWorker = task
        }
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
    let playbackPresentation: PlaybackPresentationModel
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
        transfers = TransferCenter(repository: repository)
        settings = appSettings
        playback = playbackStore
        playbackPresentation = PlaybackPresentationModel(playback: playbackStore)
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
