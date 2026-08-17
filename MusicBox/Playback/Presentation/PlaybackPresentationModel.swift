import Foundation

import Observation

struct QueueDisplayEntry: Identifiable, Equatable {
    let id: UUID
    let item: PlaylistItem
    let isCurrent: Bool
    let explicitNextPosition: Int?

    var isExplicitNext: Bool { explicitNextPosition != nil }
}

@MainActor
@Observable
final class PlaybackPresentationModel {
    private let playback: PlaybackStore
    private var eventToken: UUID?

    private(set) var currentItem: PlaylistItem?
    private(set) var phase: PlaybackPhase
    private(set) var duration: Double
    private(set) var volume: Float
    private(set) var mode: PlaybackMode
    private(set) var isSeeking: Bool
    private(set) var errorMessage: String?
    private(set) var queueEntries: [QueueDisplayEntry] = []

    init(playback: PlaybackStore) {
        self.playback = playback
        let state = playback.state
        currentItem = state.currentItem
        phase = state.phase
        duration = state.duration
        volume = state.volume
        mode = state.mode
        isSeeking = state.isSeeking
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
    var displayedPosition: Double { playback.currentPosition }
    var shouldAnimateDisplayedPosition: Bool {
        phase == .playing && !isSeeking && duration > 0
    }

    func toggle() { playback.toggle() }
    func play() { playback.play() }
    func pause() { playback.pause() }
    func next() { playback.next() }
    func previous() { playback.previous() }
    func seek(to seconds: Double) { playback.seek(to: seconds) }
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
        switch event {
        case .queueChanged:
            refreshQueue()
            update(&mode, with: state.mode)
            if state.currentItem == nil {
                update(&currentItem, with: nil)
            }
        case .modeChanged:
            update(&mode, with: state.mode)
        case .itemChanged:
            update(&currentItem, with: state.currentItem)
            update(&phase, with: state.phase)
            update(&duration, with: state.duration)
            update(&isSeeking, with: state.isSeeking)
            update(&errorMessage, with: state.errorMessage)
        case .playbackChanged:
            update(&phase, with: state.phase)
            update(&isSeeking, with: state.isSeeking)
        case .positionChanged:
            update(&phase, with: state.phase)
            update(&duration, with: state.duration)
            update(&isSeeking, with: state.isSeeking)
        case .failed:
            update(&phase, with: state.phase)
            update(&errorMessage, with: state.errorMessage)
            update(&isSeeking, with: state.isSeeking)
        case .didStart, .didEnd:
            break
        }
    }

    private func update<T: Equatable>(_ value: inout T, with newValue: T) {
        guard value != newValue else { return }
        value = newValue
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
