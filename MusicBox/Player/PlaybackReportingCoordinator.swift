//
//  PlaybackReportingCoordinator.swift
//  MusicBox
//
//  Coordinates native playback lifecycle reporting and NetEase relay handoff.
//

import AppKit
import Foundation

enum PlaybackEndReason {
    case finished
    case switched
    case stopped
    case failed

    var dawnValue: String {
        switch self {
        case .finished, .stopped: return "playend"
        case .switched: return "ui"
        case .failed: return "exception"
        }
    }
}

@MainActor
final class PlaybackReportingCoordinator: ObservableObject {
    @Published private(set) var relayAvailable = false
    @Published private(set) var relayEnabled = false
    @Published private(set) var isUpdatingRelaySetting = false
    @Published private(set) var handoffOffer: RelayHandoffOffer?

    private let client: NeteasePlaybackClient
    private let store: PlaybackReportStore
    private var accountID: UInt64?
    private var relayConfig: RelayConfig?
    private var sourceState: RelaySourceState?
    private var activeItem: PlaylistItem?
    private var outbox: [StoredDawnEvent] = []
    private var pendingRelay: StoredRelayState?
    private var isDrainingDawn = false
    private var dawnRetryTask: Task<Void, Never>?
    private var relayTask: Task<Void, Never>?
    private var relayRetryTask: Task<Void, Never>?
    private var offerExpiryTask: Task<Void, Never>?

    init(
        client: NeteasePlaybackClient = .shared,
        storageURL: URL? = nil
    ) {
        self.client = client
        self.store = PlaybackReportStore(url: storageURL)
    }

    func activate(accountID: UInt64) async {
        guard self.accountID != accountID else {
            if relayConfig == nil {
                await configureRelay()
            }
            return
        }

        // Stop in-flight work for the previous account while preserving its
        // separately keyed queue. It will only be restored after that account
        // signs in again.
        if self.accountID != nil {
            deactivateRuntime()
        }
        self.accountID = accountID
        let persisted = store.load()
        outbox = persisted.dawn.filter { $0.accountID == accountID }
        pendingRelay = persisted.relay?.accountID == accountID ? persisted.relay : nil
        drainDawnOutbox()
        await configureRelay()
    }

    func deactivate() {
        deactivateRuntime()
    }

    func playbackQueueDidChange(items: [PlaylistItem], currentIndex: Int, loopMode: LoopMode) {
        guard !items.isEmpty else {
            sourceState = nil
            pendingRelay = nil
            persist()
            return
        }
        let normalizedIndex = max(0, min(currentIndex, items.count - 1))
        let signature = sourceSignature(items: items, loopMode: loopMode)
        if sourceState?.signature != signature {
            sourceState = makeSourceState(
                items: items,
                currentIndex: normalizedIndex,
                loopMode: loopMode,
                retransmit: false
            )
        } else {
            sourceState?.items = items
            sourceState?.currentIndex = normalizedIndex
            sourceState?.loopMode = loopMode
        }
    }

    func playbackModeDidChange(items: [PlaylistItem], currentIndex: Int, loopMode: LoopMode) {
        playbackQueueDidChange(items: items, currentIndex: currentIndex, loopMode: loopMode)
        guard let item = activeItem else { return }
        reportRelayState(for: item)
    }

    func playbackDidStart(item: PlaylistItem) {
        guard accountID != nil else { return }
        guard activeItem?.id != item.id else { return }
        activeItem = item
        enqueueDawn(makeDawnStartEvent(item: item))

        if sourceState == nil {
            playbackQueueDidChange(items: [item], currentIndex: 0, loopMode: .sequence)
        }
        reportRelayState(for: item)
    }

    func playbackDidEnd(item: PlaylistItem?, playedSeconds: Double, reason: PlaybackEndReason) {
        guard let activeItem else { return }
        guard item == nil || item?.id == activeItem.id else { return }
        self.activeItem = nil
        enqueueDawn(makeDawnEndEvent(item: activeItem, playedSeconds: playedSeconds, reason: reason))
    }

    func refreshHandoffOffer() async {
        guard relayAvailable, relayEnabled else { return }
        do {
            let offer = try await client.handoffOffer()
            setHandoffOffer(offer)
        } catch {
            print("[Relay] failed to fetch handoff offer: \(error)")
        }
    }

    func dismissHandoffOffer() {
        offerExpiryTask?.cancel()
        offerExpiryTask = nil
        handoffOffer = nil
    }

    func updateRelayEnabled(_ enabled: Bool) async {
        guard relayAvailable else { return }
        isUpdatingRelaySetting = true
        defer { isUpdatingRelaySetting = false }
        do {
            try await client.updateRelaySetting(enabled: enabled)
            relayEnabled = enabled
            if enabled {
                await refreshHandoffOffer()
                if let activeItem {
                    reportRelayState(for: activeItem)
                }
            } else {
                dismissHandoffOffer()
            }
        } catch {
            AlertModal.showAlert(error.localizedDescription)
        }
    }

    func continueHandoff(using playlistStatus: PlaylistStatus) async {
        guard let offer = handoffOffer else { return }
        dismissHandoffOffer()
        do {
            let pulled = try await client.pullRelayPlay(offer: offer)
            guard isSupportedHandoffSource(pulled.sourceType),
                pulled.currentResourceType.map(isSupportedHandoffResource) ?? true,
                pulled.resources.allSatisfy({ isSupportedHandoffResource($0.type) })
            else {
                throw RequestError.Request("MusicBox cannot continue this handoff source")
            }
            let restored = try await resolveHandoffPlaylist(pulled)
            guard !restored.items.isEmpty else {
                throw RequestError.Request("The handoff did not contain playable songs")
            }
            let startIndex = restored.items.firstIndex { String($0.id) == pulled.currentResourceID } ?? 0
            await playlistStatus.replacePlaylist(
                restored.items,
                continuePlaying: true,
                shouldSaveState: true,
                startIndex: startIndex,
                startSecond: Double(pulled.progressMilliseconds) / 1_000
            )
        } catch {
            AlertModal.showAlert(error.localizedDescription)
        }
    }

    private func deactivateRuntime() {
        dawnRetryTask?.cancel()
        relayTask?.cancel()
        relayRetryTask?.cancel()
        offerExpiryTask?.cancel()
        dawnRetryTask = nil
        relayTask = nil
        relayRetryTask = nil
        offerExpiryTask = nil
        accountID = nil
        relayConfig = nil
        relayAvailable = false
        relayEnabled = false
        isUpdatingRelaySetting = false
        handoffOffer = nil
        sourceState = nil
        activeItem = nil
        outbox = []
        pendingRelay = nil
        isDrainingDawn = false
    }

    private func configureRelay() async {
        guard accountID != nil, client.hasAuthenticatedSession() else { return }
        do {
            let config = try await client.relayConfig()
            relayConfig = config
            relayAvailable = config.enabled
            guard config.enabled else {
                relayEnabled = false
                pendingRelay = nil
                persist()
                return
            }
            relayEnabled = try await client.relaySetting()
            if relayEnabled {
                await refreshHandoffOffer()
                flushPersistedRelayState()
            }
        } catch {
            relayConfig = nil
            relayAvailable = false
            relayEnabled = false
            print("[Relay] configuration unavailable: \(error)")
        }
    }

    private func setHandoffOffer(_ offer: RelayHandoffOffer?) {
        offerExpiryTask?.cancel()
        handoffOffer = offer
        guard offer != nil else { return }
        offerExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            self?.handoffOffer = nil
        }
    }

    private func resolveHandoffPlaylist(_ pulled: RelayPullResult) async throws -> (items: [PlaylistItem], source: PlaybackSourcePlaylist?) {
        if pulled.sourceType?.lowercased() == "playlist",
            let sourceID = pulled.sourceID,
            let playlistID = UInt64(sourceID),
            let detail = await CloudMusicApi().playlist_detail(id: playlistID)
        {
            let source = PlaybackSourcePlaylist(id: playlistID, name: "")
            let items = detail.tracks.map { song -> PlaylistItem in
                let item = loadItem(song: song)
                item.sourcePlaylist = source
                return item
            }
            return (items, source)
        }

        let ids = pulled.resources.compactMap { UInt64($0.id) }
        guard !ids.isEmpty, let songs = await CloudMusicApi().song_detail(ids: ids) else {
            throw RequestError.Request("Unable to load handoff songs")
        }
        let byID = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        let items = ids.compactMap { byID[$0] }.map(loadItem(song:))
        return (items, nil)
    }

    private func isSupportedHandoffSource(_ sourceType: String?) -> Bool {
        guard let sourceType else { return true }
        switch sourceType.lowercased() {
        case "voice", "voices", "voicelist", "podcast":
            return false
        default:
            // Resource-backed sources such as an album can be rebuilt from
            // their song resource list even though MusicBox has no separate
            // album queue model.
            return true
        }
    }

    private func isSupportedHandoffResource(_ resourceType: String) -> Bool {
        switch resourceType.lowercased() {
        case "song", "track", "downloadtrack", "localtrack", "cloudtrack", "":
            return true
        default:
            return false
        }
    }

    private func sourceSignature(items: [PlaylistItem], loopMode: LoopMode) -> String {
        let sourceID = sharedSourcePlaylist(in: items).map { String($0.id) } ?? "resources"
        return "\(sourceID)|\(relayPlayMode(loopMode))|\(items.map { String($0.id) }.joined(separator: ","))"
    }

    private func makeSourceState(
        items: [PlaylistItem],
        currentIndex: Int,
        loopMode: LoopMode,
        retransmit: Bool
    ) -> RelaySourceState {
        let initialItem = items[currentIndex]
        let sourcePlaylist = sharedSourcePlaylist(in: items)
        let request = RelaySongListRequest(
            retransmit: retransmit,
            sessionID: randomSessionID(),
            initialResourceID: String(initialItem.id),
            playMode: relayPlayMode(loopMode),
            sourceType: sourcePlaylist == nil ? nil : "playlist",
            sourceID: sourcePlaylist.map { String($0.id) },
            resources: sourcePlaylist == nil ? items.map { RelayResource(id: $0.id) } : nil
        )
        return RelaySourceState(
            signature: sourceSignature(items: items, loopMode: loopMode),
            request: request,
            items: items,
            currentIndex: currentIndex,
            loopMode: loopMode,
            submitted: false
        )
    }

    private func sharedSourcePlaylist(in items: [PlaylistItem]) -> PlaybackSourcePlaylist? {
        guard let source = items.first?.sourcePlaylist else { return nil }
        guard items.allSatisfy({ $0.sourcePlaylist?.id == source.id }) else { return nil }
        return source
    }

    private func reportRelayState(for item: PlaylistItem) {
        guard relayAvailable, relayEnabled, let source = sourceState else { return }
        var request = source.request
        request = RelaySongListRequest(
            retransmit: request.retransmit,
            sessionID: request.sessionID,
            initialResourceID: String(item.id),
            playMode: relayPlayMode(source.loopMode),
            sourceType: request.sourceType,
            sourceID: request.sourceID,
            resources: request.resources
        )
        sourceState?.request = request
        let state = RelayPlayStateRequest(
            resource: RelayResource(id: item.id),
            progress: 0,
            sessionID: request.sessionID,
            playMode: request.playMode
        )
        pendingRelay = StoredRelayState(accountID: accountID ?? 0, source: request, state: state)
        persist()

        relayTask?.cancel()
        relayTask = Task { [weak self] in
            guard let self else { return }
            await self.submitRelay(source: request, state: state)
        }
    }

    private func submitRelay(source: RelaySongListRequest, state: RelayPlayStateRequest) async {
        guard relayAvailable, relayEnabled,
            sourceState?.request.sessionID == source.sessionID
        else { return }
        do {
            if sourceState?.submitted != true {
                let code = try await client.submitRelaySongList(source)
                if code == 10001 {
                    forceRetransmit(currentResource: state.resource)
                    return
                }
                guard code == 200 else {
                    throw RequestError.errorCode((code, "Relay song list submission failed"))
                }
                guard sourceState?.request.sessionID == source.sessionID else { return }
                sourceState?.submitted = true
            }

            let code = try await client.submitRelayPlayState(state)
            if code == 10001 {
                forceRetransmit(currentResource: state.resource)
                return
            }
            guard code == 200 else {
                throw RequestError.errorCode((code, "Relay playback state submission failed"))
            }
            if pendingRelay?.state.sessionID == state.sessionID {
                pendingRelay = nil
                persist()
            }
        } catch {
            print("[Relay] reporting failed: \(error)")
            scheduleRelayRetry()
        }
    }

    private func forceRetransmit(currentResource: RelayResource) {
        guard let source = sourceState, !source.items.isEmpty else { return }
        let snapshotSize = relayConfig?.snapshotSize ?? 20
        let index = source.items.firstIndex { String($0.id) == currentResource.id } ?? source.currentIndex
        let lower = max(0, index - snapshotSize / 2)
        let upper = min(source.items.count, lower + snapshotSize)
        let snapshot = Array(source.items[lower..<upper])
        sourceState = makeSourceState(
            items: snapshot,
            currentIndex: min(index - lower, snapshot.count - 1),
            loopMode: source.loopMode,
            retransmit: true
        )
        guard let refreshed = sourceState else { return }
        let state = RelayPlayStateRequest(
            resource: currentResource,
            progress: 0,
            sessionID: refreshed.request.sessionID,
            playMode: refreshed.request.playMode
        )
        pendingRelay = StoredRelayState(accountID: accountID ?? 0, source: refreshed.request, state: state)
        persist()
        relayTask?.cancel()
        relayTask = Task { [weak self] in
            await self?.submitRelay(source: refreshed.request, state: state)
        }
    }

    private func flushPersistedRelayState() {
        guard let pending = pendingRelay,
            pending.accountID == accountID,
            relayAvailable,
            relayEnabled
        else { return }
        sourceState = RelaySourceState(
            signature: "persisted:\(pending.source.sessionID)",
            request: pending.source,
            items: [],
            currentIndex: 0,
            loopMode: loopMode(from: pending.state.playMode),
            submitted: false
        )
        relayTask?.cancel()
        relayTask = Task { [weak self] in
            await self?.submitRelay(source: pending.source, state: pending.state)
        }
    }

    private func scheduleRelayRetry() {
        relayRetryTask?.cancel()
        relayRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled,
                let self,
                let pending = self.pendingRelay,
                self.relayAvailable,
                self.relayEnabled
            else { return }
            await self.submitRelay(source: pending.source, state: pending.state)
        }
    }

    private func enqueueDawn(_ event: DawnEvent) {
        guard let accountID else { return }
        let sequence = store.nextSequence()
        outbox.append(StoredDawnEvent(accountID: accountID, sequence: sequence, event: event))
        persist()
        drainDawnOutbox()
    }

    private func drainDawnOutbox() {
        guard !isDrainingDawn, accountID != nil else { return }
        isDrainingDawn = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isDrainingDawn = false }
            while let event = self.outbox.first,
                event.accountID == self.accountID
            {
                do {
                    try await self.client.uploadDawn(events: [event.event], sequence: event.sequence)
                    guard self.outbox.first?.event.id == event.event.id else { continue }
                    self.outbox.removeFirst()
                    self.persist()
                } catch {
                    print("[Dawn] upload failed: \(error)")
                    self.scheduleDawnRetry()
                    return
                }
            }
        }
    }

    private func scheduleDawnRetry() {
        dawnRetryTask?.cancel()
        dawnRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.drainDawnOutbox()
        }
    }

    private func persist() {
        guard let accountID else { return }
        let existing = store.load()
        let retainedDawn = existing.dawn.filter { $0.accountID != accountID }
        var relay = existing.relay
        if relay?.accountID == accountID || pendingRelay != nil {
            relay = pendingRelay
        }
        store.save(
            PlaybackReportPersistence(
                dawn: retainedDawn + outbox,
                relay: relay
            )
        )
    }

    private func makeDawnStartEvent(item: PlaylistItem) -> DawnEvent {
        DawnEvent(action: "_plv", payload: dawnBasePayload(item: item))
    }

    private func makeDawnEndEvent(
        item: PlaylistItem,
        playedSeconds: Double,
        reason: PlaybackEndReason
    ) -> DawnEvent {
        var payload = dawnBasePayload(item: item)
        let seconds = max(0, Int(playedSeconds.rounded()))
        payload["time"] = .number(Double(seconds))
        payload["realtime"] = .number(Double(seconds))
        payload["end"] = .string(reason.dawnValue)
        payload["channel"] = .string("others")
        payload["curStartChannel"] = .string("")
        payload["lyriceffect"] = .string("-1")
        payload["displayMode"] = .string("")
        return DawnEvent(action: "_pld", payload: payload)
    }

    private func dawnBasePayload(item: PlaylistItem) -> [String: JSONValue] {
        let durationMilliseconds = max(0, Int(item.duration.seconds * 1_000))
        let isLocal = item.url?.isFileURL == true
        let source = item.sourcePlaylist
        return [
            "mode": .string(sourceState.map { relayPlayMode($0.loopMode) } ?? "list_loop"),
            "download": .number(0),
            "status": .string(NSApp.isActive ? "front" : "back"),
            "id": .string(String(item.id)),
            "bitrate": .number(0),
            "type": .string("song"),
            "is_listentogether": .number(0),
            "source": .string(source == nil ? "" : "list"),
            "is_heart": .number(0),
            "resource_ratio": .string(""),
            "resource_time": .number(Double(durationMilliseconds)),
            "musiceffect_id": .string(""),
            "app_mode": .number(1),
            "bitrate_level": .string(""),
            "_addrefer": .string(""),
            "_multirefers": .string(""),
            "vipType": .number(0),
            "is_audition": .number(0),
            "playReason": .array([]),
            "fee": .number(Double(item.nsSong?.fee.rawValue ?? 0)),
            "file": .number(isLocal ? 1 : 4),
            "sourceId": .string(source.map { String($0.id) } ?? ""),
            "sourcetype": .string(source == nil ? "" : "playlist"),
        ]
    }

    private func relayPlayMode(_ mode: LoopMode) -> String {
        switch mode {
        case .once: return "single_loop"
        case .shuffle: return "random"
        case .sequence: return "list_loop"
        }
    }

    private func loopMode(from relayMode: String) -> LoopMode {
        switch relayMode {
        case "single_loop": return .once
        case "random": return .shuffle
        default: return .sequence
        }
    }

    private func randomSessionID() -> String {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return String((0..<12).compactMap { _ in alphabet.randomElement() })
    }
}

private struct RelaySourceState {
    let signature: String
    var request: RelaySongListRequest
    var items: [PlaylistItem]
    var currentIndex: Int
    var loopMode: LoopMode
    var submitted: Bool
}

private struct StoredDawnEvent: Codable {
    let accountID: UInt64
    let sequence: UInt32
    let event: DawnEvent
}

private struct StoredRelayState: Codable {
    let accountID: UInt64
    let source: RelaySongListRequest
    let state: RelayPlayStateRequest
}

private struct PlaybackReportPersistence: Codable {
    var dawn: [StoredDawnEvent]
    var relay: StoredRelayState?
}

private final class PlaybackReportStore {
    private let url: URL
    private let sequenceKey = "NeteasePlaybackDawnSequence"

    init(url: URL?) {
        if let url {
            self.url = url
            return
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("MusicBox", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.url = directory.appendingPathComponent("playback-report-outbox.json")
    }

    func load() -> PlaybackReportPersistence {
        guard let data = try? Data(contentsOf: url),
            let value = try? JSONDecoder().decode(PlaybackReportPersistence.self, from: data)
        else {
            return PlaybackReportPersistence(dawn: [], relay: nil)
        }
        return value
    }

    func save(_ value: PlaybackReportPersistence) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func nextSequence() -> UInt32 {
        let defaults = UserDefaults.standard
        let previous = UInt32(truncatingIfNeeded: defaults.integer(forKey: sequenceKey))
        let next = previous &+ 1
        defaults.set(Int(next), forKey: sequenceKey)
        return next == 0 ? 1 : next
    }
}
