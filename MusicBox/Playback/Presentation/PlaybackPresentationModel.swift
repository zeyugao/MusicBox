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
    private(set) var position: Double
    private(set) var duration: Double
    private(set) var volume: Float
    private(set) var mode: PlaybackMode
    private(set) var isSeeking: Bool
    private(set) var bufferingProgress: Double?
    private(set) var errorMessage: String?
    private(set) var queueEntries: [QueueDisplayEntry] = []

    init(playback: PlaybackStore) {
        self.playback = playback
        currentItem = playback.state.currentItem
        phase = playback.state.phase
        position = playback.state.position
        duration = playback.state.duration
        volume = playback.state.volume
        mode = playback.state.mode
        isSeeking = playback.state.isSeeking
        bufferingProgress = playback.state.bufferingProgress
        errorMessage = playback.state.errorMessage
        refreshQueue()
        eventToken = playback.addEventListener { [weak self] _ in
            self?.refresh()
        }
    }

    var isPlaying: Bool { phase == .playing }
    var isLoading: Bool { phase == .preparing }
    var hasCurrentItem: Bool { currentItem != nil }
    var explicitNextCount: Int { queueEntries.filter(\.isExplicitNext).count }
    var lyrics: LyricsState { playback.lyrics.state }

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

    private func refresh() {
        let state = playback.state
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

    private func refreshQueue() {
        let snapshot = playback.queue.snapshot
        let currentID = snapshot.current?.id
        let explicitNextPositions = Dictionary(
            uniqueKeysWithValues: snapshot.upNext.enumerated().map { ($0.element.id, $0.offset + 1) }
        )
        var entries = snapshot.source

        if let current = snapshot.current,
            let currentIndex = entries.firstIndex(where: { $0.id == current.id })
        {
            entries.insert(contentsOf: snapshot.upNext, at: currentIndex + 1)
        } else {
            if let current = snapshot.current {
                entries.insert(current, at: 0)
            }
            entries.insert(contentsOf: snapshot.upNext, at: min(entries.count, currentID == nil ? 0 : 1))
        }

        queueEntries = entries.map {
            QueueDisplayEntry(
                id: $0.id,
                item: $0.item,
                isCurrent: $0.id == currentID,
                explicitNextPosition: explicitNextPositions[$0.id]
            )
        }
    }
}
