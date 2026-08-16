//
//  PlaybackQueue.swift
//  MusicBox
//
//  A deterministic, UI-independent playback queue.
//

import Foundation

enum PlaybackMode: String, Codable, CaseIterable {
    case repeatAll
    case shuffle
    case repeatOne

    var next: PlaybackMode {
        switch self {
        case .repeatAll: return .shuffle
        case .shuffle: return .repeatOne
        case .repeatOne: return .repeatAll
        }
    }

    var relayValue: String {
        switch self {
        case .repeatAll: return "list_loop"
        case .shuffle: return "random"
        case .repeatOne: return "single_loop"
        }
    }
}

struct PlaybackQueueEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var item: PlaylistItem

    init(id: UUID = UUID(), item: PlaylistItem) {
        self.id = id
        self.item = item
    }
}

struct PlaybackQueueSnapshot: Codable, Equatable {
    var source: [PlaybackQueueEntry]
    var current: PlaybackQueueEntry?
    var upNext: [PlaybackQueueEntry]
    var history: [PlaybackQueueEntry]
    var mode: PlaybackMode
    var shuffleOrder: [UUID]
    var shuffleCursor: Int
}

struct PlaybackQueue: Codable {
    private(set) var source: [PlaybackQueueEntry] = []
    private(set) var current: PlaybackQueueEntry?
    private(set) var upNext: [PlaybackQueueEntry] = []
    private(set) var history: [PlaybackQueueEntry] = []
    private(set) var mode: PlaybackMode = .repeatAll
    private var shuffleOrder: [UUID] = []
    private var shuffleCursor = 0

    init() {}

    init(snapshot: PlaybackQueueSnapshot) {
        source = snapshot.source
        current = snapshot.current
        upNext = snapshot.upNext
        history = snapshot.history
        mode = snapshot.mode
        shuffleOrder = snapshot.shuffleOrder
        shuffleCursor = snapshot.shuffleCursor
        normalizeShuffleState()
    }

    var snapshot: PlaybackQueueSnapshot {
        PlaybackQueueSnapshot(
            source: source,
            current: current,
            upNext: upNext,
            history: history,
            mode: mode,
            shuffleOrder: shuffleOrder,
            shuffleCursor: shuffleCursor
        )
    }

    var currentItem: PlaylistItem? { current?.item }
    var currentEntryID: UUID? { current?.id }
    var sourceIndex: Int? {
        guard let currentID = current?.id else { return nil }
        return source.firstIndex { $0.id == currentID }
    }

    var visibleEntries: [PlaybackQueueEntry] {
        var result: [PlaybackQueueEntry] = []
        if let current { result.append(current) }
        result.append(contentsOf: upNext)
        for entry in source where entry.id != current?.id && !upNext.contains(where: { $0.id == entry.id }) {
            result.append(entry)
        }
        return result
    }

    var upcomingCount: Int { upNext.count }

    mutating func replaceSource(
        _ items: [PlaylistItem],
        startIndex: Int = 0,
        mode: PlaybackMode? = nil
    ) -> PlaybackQueueEntry? {
        source = items.map { PlaybackQueueEntry(item: $0) }
        upNext = []
        history = []
        if let mode { self.mode = mode }

        guard !source.isEmpty else {
            current = nil
            shuffleOrder = []
            shuffleCursor = 0
            return nil
        }

        let index = max(0, min(startIndex, source.count - 1))
        current = source[index]
        rebuildShuffle(anchoredAt: current?.id)
        return current
    }

    mutating func appendToSource(_ items: [PlaylistItem]) {
        guard !items.isEmpty else { return }
        source.append(contentsOf: items.map { PlaybackQueueEntry(item: $0) })
        if current == nil {
            current = source.first
        }
        rebuildShuffle(anchoredAt: current?.id)
    }

    mutating func enqueueNext(_ items: [PlaylistItem]) -> [PlaybackQueueEntry] {
        let entries = items.map { PlaybackQueueEntry(item: $0) }
        guard !entries.isEmpty else { return [] }
        upNext.insert(contentsOf: entries, at: 0)
        return entries
    }

    mutating func cycleMode() -> PlaybackMode {
        mode = mode.next
        if mode == .shuffle {
            rebuildShuffle(anchoredAt: current?.id)
        }
        return mode
    }

    mutating func setMode(_ newMode: PlaybackMode) {
        mode = newMode
        if newMode == .shuffle {
            rebuildShuffle(anchoredAt: current?.id)
        }
    }

    mutating func playNow(_ entry: PlaybackQueueEntry) -> PlaybackQueueEntry? {
        guard current?.id != entry.id else { return current }
        if let current { history.append(current) }
        upNext.removeAll { $0.id == entry.id }
        current = entry
        alignShuffleToCurrent()
        return current
    }

    mutating func playSourceEntry(id: UUID) -> PlaybackQueueEntry? {
        guard let entry = source.first(where: { $0.id == id }) else { return nil }
        return playNow(entry)
    }

    mutating func playEntry(id: UUID) -> PlaybackQueueEntry? {
        if let entry = source.first(where: { $0.id == id }) {
            return playNow(entry)
        }
        if let entry = upNext.first(where: { $0.id == id }) {
            return playNow(entry)
        }
        return current?.id == id ? current : nil
    }

    mutating func next(isNaturalCompletion: Bool) -> PlaybackQueueEntry? {
        guard current != nil || !source.isEmpty || !upNext.isEmpty else { return nil }

        if let first = upNext.first {
            upNext.removeFirst()
            return advance(to: first)
        }

        if isNaturalCompletion, mode == .repeatOne, let current {
            return current
        }

        guard !source.isEmpty else {
            current = nil
            return nil
        }

        switch mode {
        case .shuffle:
            return advance(to: nextShuffleEntry())
        case .repeatAll, .repeatOne:
            return advance(to: nextSequentialEntry())
        }
    }

    mutating func previous() -> PlaybackQueueEntry? {
        if let prior = history.popLast() {
            if let current { upNext.insert(current, at: 0) }
            current = prior
            alignShuffleToCurrent()
            return current
        }

        guard !source.isEmpty else { return current }
        guard let currentIndex = sourceIndex else {
            current = source.last
            alignShuffleToCurrent()
            return current
        }
        let index = (currentIndex - 1 + source.count) % source.count
        current = source[index]
        alignShuffleToCurrent()
        return current
    }

    mutating func removeEntry(id: UUID) -> PlaybackQueueEntry? {
        if current?.id == id {
            let removedSourceIndex = source.firstIndex { $0.id == id }
            current = nil
            source.removeAll { $0.id == id }
            upNext.removeAll { $0.id == id }
            history.removeAll { $0.id == id }

            if let explicitNext = upNext.first {
                upNext.removeFirst()
                rebuildShuffle(anchoredAt: explicitNext.id)
                return advance(to: explicitNext)
            }

            guard !source.isEmpty else {
                rebuildShuffle(anchoredAt: nil)
                return nil
            }

            switch mode {
            case .shuffle:
                rebuildShuffle(anchoredAt: nil)
                return advance(to: shuffleOrder.first.flatMap { id in source.first { $0.id == id } })
            case .repeatAll, .repeatOne:
                let index = min(removedSourceIndex ?? 0, source.count - 1)
                return advance(to: source[index])
            }
        }

        source.removeAll { $0.id == id }
        upNext.removeAll { $0.id == id }
        history.removeAll { $0.id == id }
        normalizeShuffleState()
        return current
    }

    mutating func clear() {
        source = []
        current = nil
        upNext = []
        history = []
        shuffleOrder = []
        shuffleCursor = 0
    }

    mutating func restoreCurrent(_ entry: PlaybackQueueEntry?) {
        current = entry
        normalizeShuffleState()
    }

    private mutating func advance(to entry: PlaybackQueueEntry?) -> PlaybackQueueEntry? {
        guard let entry else {
            current = nil
            return nil
        }
        if let current, current.id != entry.id {
            history.append(current)
        }
        current = entry
        alignShuffleToCurrent()
        return current
    }

    private func nextSequentialEntry() -> PlaybackQueueEntry? {
        guard !source.isEmpty else { return nil }
        guard let currentIndex = sourceIndex else { return source.first }
        return source[(currentIndex + 1) % source.count]
    }

    private mutating func nextShuffleEntry() -> PlaybackQueueEntry? {
        guard !source.isEmpty else { return nil }
        normalizeShuffleState()
        guard !shuffleOrder.isEmpty else { return source.first }

        if shuffleCursor + 1 >= shuffleOrder.count {
            rebuildShuffle(anchoredAt: current?.id)
            if shuffleOrder.count > 1 {
                shuffleCursor = 1
            }
        } else {
            shuffleCursor += 1
        }

        guard shuffleCursor >= 0, shuffleCursor < shuffleOrder.count else { return source.first }
        let id = shuffleOrder[shuffleCursor]
        return source.first { $0.id == id } ?? source.first
    }

    private mutating func alignShuffleToCurrent() {
        guard mode == .shuffle else { return }
        guard let currentID = current?.id else { return }
        if let index = shuffleOrder.firstIndex(of: currentID) {
            shuffleCursor = index
        } else {
            rebuildShuffle(anchoredAt: currentID)
        }
    }

    private mutating func normalizeShuffleState() {
        let sourceIDs = Set(source.map(\.id))
        shuffleOrder.removeAll { !sourceIDs.contains($0) }
        if shuffleOrder.count != source.count || shuffleOrder.isEmpty {
            rebuildShuffle(anchoredAt: current?.id)
            return
        }
        if let currentID = current?.id, let index = shuffleOrder.firstIndex(of: currentID) {
            shuffleCursor = index
        } else {
            shuffleCursor = max(0, min(shuffleCursor, shuffleOrder.count - 1))
        }
    }

    private mutating func rebuildShuffle(anchoredAt anchor: UUID?) {
        guard !source.isEmpty else {
            shuffleOrder = []
            shuffleCursor = 0
            return
        }

        let ids = source.map(\.id)
        guard let anchor, ids.contains(anchor) else {
            shuffleOrder = ids.shuffled()
            shuffleCursor = 0
            return
        }

        var remainder = ids.filter { $0 != anchor }.shuffled()
        if remainder.first == anchor, remainder.count > 1 {
            remainder.swapAt(0, 1)
        }
        shuffleOrder = [anchor] + remainder
        shuffleCursor = 0
    }
}
