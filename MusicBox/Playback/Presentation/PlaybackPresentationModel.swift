import Foundation

import Observation

struct QueueDisplayEntry: Identifiable, Equatable {
    let id: UUID
    let item: PlaylistItem
    let isCurrent: Bool
    let explicitNextPosition: Int?

    var isExplicitNext: Bool { explicitNextPosition != nil }
}

// Keeps the player UI moving smoothly between authoritative engine samples.
struct PlaybackDisplayClock {
    private var anchorPosition: Double
    private var duration: Double
    private var anchorTime: TimeInterval
    private var isAdvancing: Bool

    init(position: Double, duration: Double, isAdvancing: Bool, now: TimeInterval) {
        self.duration = Self.normalizedDuration(duration)
        anchorPosition = Self.boundedPosition(position, duration: self.duration)
        anchorTime = now
        self.isAdvancing = isAdvancing
    }

    mutating func synchronize(position: Double, duration: Double, at now: TimeInterval) {
        self.duration = Self.normalizedDuration(duration)
        anchorPosition = Self.boundedPosition(position, duration: self.duration)
        anchorTime = now
    }

    mutating func setAdvancing(_ isAdvancing: Bool, at now: TimeInterval) {
        if self.isAdvancing, !isAdvancing {
            anchorPosition = position(at: now)
        }
        anchorTime = now
        self.isAdvancing = isAdvancing
    }

    func position(at now: TimeInterval) -> Double {
        guard isAdvancing else { return anchorPosition }
        return Self.boundedPosition(anchorPosition + max(0, now - anchorTime), duration: duration)
    }

    private static func normalizedDuration(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 0
    }

    private static func boundedPosition(_ value: Double, duration: Double) -> Double {
        let position = value.isFinite ? max(0, value) : 0
        guard duration > 0 else { return position }
        return min(position, duration)
    }
}

@MainActor
@Observable
final class PlaybackPresentationModel {
    private let playback: PlaybackStore
    private let currentUptime: () -> TimeInterval
    private var eventToken: UUID?
    private var displayClock: PlaybackDisplayClock

    private(set) var currentItem: PlaylistItem?
    private(set) var phase: PlaybackPhase
    private(set) var position: Double
    private(set) var duration: Double
    private(set) var volume: Float
    private(set) var mode: PlaybackMode
    private(set) var isSeeking: Bool
    private(set) var bufferingProgress: Double?
    private(set) var errorMessage: String?
    private(set) var queueEntries: [QueueDisplayEntry] = []

    init(
        playback: PlaybackStore,
        currentUptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.playback = playback
        self.currentUptime = currentUptime
        let state = playback.state
        displayClock = PlaybackDisplayClock(
            position: state.position,
            duration: state.duration,
            isAdvancing: Self.shouldAdvanceDisplayClock(for: state),
            now: currentUptime()
        )
        currentItem = state.currentItem
        phase = state.phase
        position = state.position
        duration = state.duration
        volume = state.volume
        mode = state.mode
        isSeeking = state.isSeeking
        bufferingProgress = state.bufferingProgress
        errorMessage = state.errorMessage
        refreshQueue()
        eventToken = playback.addEventListener { [weak self] event in
            self?.refresh(for: event)
        }
    }

    var isPlaying: Bool { phase == .playing }
    var isLoading: Bool { phase == .preparing }
    var hasCurrentItem: Bool { currentItem != nil }
    var explicitNextCount: Int { playback.queue.upcomingCount }
    var lyrics: LyricsState { playback.lyrics.state }
    var displayedPosition: Double { displayClock.position(at: currentUptime()) }
    var shouldAnimateDisplayedPosition: Bool {
        phase == .playing && !isSeeking && duration > 0
    }

    func toggle() { playback.toggle() }
    func play() { playback.play() }
    func pause() { playback.pause() }
    func next() { playback.next() }
    func previous() { playback.previous() }
    func seek(to seconds: Double) {
        guard hasCurrentItem else { return }
        let target = boundedPosition(seconds)
        let now = currentUptime()
        position = target
        isSeeking = true
        displayClock.synchronize(position: target, duration: duration, at: now)
        displayClock.setAdvancing(false, at: now)
        playback.seek(to: target)
    }
    func setVolume(_ value: Float) {
        playback.setVolume(value)
        volume = min(max(value, 0), 1)
    }
    func cycleMode() { playback.cycleMode() }
    func play(entryID: UUID) { playback.play(entryID: entryID) }
    func enqueueNext(_ item: PlaylistItem) { playback.enqueueNext(item) }
    func remove(entryID: UUID) { playback.removeEntry(entryID) }
    func clearQueue() { playback.clearQueue() }

    private func refresh(for event: PlaybackEvent) {
        let state = playback.state
        let now = currentUptime()
        switch event {
        case .itemChanged, .positionChanged:
            displayClock.synchronize(position: state.position, duration: state.duration, at: now)
        case .queueChanged, .modeChanged, .playbackChanged, .didStart, .didEnd, .failed:
            break
        }
        displayClock.setAdvancing(Self.shouldAdvanceDisplayClock(for: state), at: now)
        currentItem = state.currentItem
        phase = state.phase
        position = state.position
        duration = state.duration
        volume = state.volume
        mode = state.mode
        isSeeking = state.isSeeking
        bufferingProgress = state.bufferingProgress
        errorMessage = state.errorMessage
        refreshQueue()
    }

    private static func shouldAdvanceDisplayClock(for state: PlaybackState) -> Bool {
        state.phase == .playing && !state.isSeeking && state.duration > 0
    }

    private func boundedPosition(_ value: Double) -> Double {
        let position = value.isFinite ? max(0, value) : 0
        guard duration > 0 else { return position }
        return min(position, duration)
    }

    private func refreshQueue() {
        let snapshot = playback.queue.snapshot
        let currentID = snapshot.current?.id
        let explicitNextPositions = Dictionary(
            uniqueKeysWithValues: snapshot.upNext.enumerated().map { ($0.element.id, $0.offset + 1) }
        )
        queueEntries = playback.queue.visibleEntries.map {
            QueueDisplayEntry(
                id: $0.id,
                item: $0.item,
                isCurrent: $0.id == currentID,
                explicitNextPosition: explicitNextPositions[$0.id]
            )
        }
    }
}
