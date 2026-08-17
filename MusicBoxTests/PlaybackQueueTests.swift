import CoreMedia
import XCTest

@testable import MusicBox

final class PlaybackQueueTests: XCTestCase {
    func testModeCycleAndRelayValues() {
        var queue = PlaybackQueue()

        XCTAssertEqual(queue.mode, .repeatAll)
        XCTAssertEqual(queue.cycleMode(), .shuffle)
        XCTAssertEqual(queue.cycleMode(), .repeatOne)
        XCTAssertEqual(queue.cycleMode(), .repeatAll)
        XCTAssertEqual(PlaybackMode.repeatAll.relayValue, "list_loop")
        XCTAssertEqual(PlaybackMode.shuffle.relayValue, "random")
        XCTAssertEqual(PlaybackMode.repeatOne.relayValue, "single_loop")
    }

    func testExplicitNextIsLIFOAndPreservesBatchOrder() {
        var queue = PlaybackQueue()
        _ = queue.replaceSource([track(1)])
        _ = queue.enqueueNext([track(2), track(3)])
        _ = queue.enqueueNext([track(4), track(5)])

        let order = (0..<5).compactMap { _ in queue.next(isNaturalCompletion: false)?.item.id }

        XCTAssertEqual(order, [4, 5, 2, 3, 1])
        XCTAssertTrue(queue.upNext.isEmpty)
    }

    func testPlayNextMovesExistingEntryWithoutDuplicatingIt() {
        var queue = PlaybackQueue()
        _ = queue.replaceSource([track(1), track(2), track(3)])
        let original = queue.source[2]

        let queued = queue.enqueueNext([track(3)])

        XCTAssertEqual(queued.map(\.id), [original.id])
        XCTAssertEqual(queue.source.map(\.item.id), [1, 3, 2])
        XCTAssertEqual(queue.upNext.map(\.id), [original.id])
        XCTAssertEqual(queue.visibleEntries.map(\.id), queue.source.map(\.id))
        XCTAssertEqual(Set(queue.visibleEntries.map(\.id)).count, queue.source.count)
    }

    func testRepeatedPlayNextReprioritizesExistingEntryWithoutDuplicatingIt() {
        var queue = PlaybackQueue()
        _ = queue.replaceSource([track(1), track(2), track(3), track(4)])

        _ = queue.enqueueNext([track(3)])
        _ = queue.enqueueNext([track(2)])
        _ = queue.enqueueNext([track(3)])

        XCTAssertEqual(queue.upNext.map(\.item.id), [3, 2])
        XCTAssertEqual(queue.source.map(\.item.id), [1, 3, 2, 4])
        XCTAssertEqual(Set(queue.source.map(\.id)).count, queue.source.count)
    }

    func testPlayNextIgnoresCurrentEntry() {
        var queue = PlaybackQueue()
        _ = queue.replaceSource([track(1), track(2)])

        XCTAssertTrue(queue.enqueueNext([track(1)]).isEmpty)
        XCTAssertTrue(queue.upNext.isEmpty)
        XCTAssertEqual(queue.source.map(\.item.id), [1, 2])
    }

    func testExplicitNextPrecedesNaturalSingleLoop() {
        var queue = PlaybackQueue()
        _ = queue.replaceSource([track(1), track(2)], mode: .repeatOne)
        _ = queue.enqueueNext([track(3)])

        XCTAssertEqual(queue.next(isNaturalCompletion: true)?.item.id, 3)
        XCTAssertEqual(queue.next(isNaturalCompletion: true)?.item.id, 3)
    }

    func testManualNextAdvancesInSingleLoop() {
        var queue = PlaybackQueue()
        _ = queue.replaceSource([track(1), track(2)], mode: .repeatOne)

        XCTAssertEqual(queue.next(isNaturalCompletion: false)?.item.id, 2)
    }

    func testPreviousUsesPlaybackHistoryBeforeSourceFallback() {
        var queue = PlaybackQueue()
        _ = queue.replaceSource([track(1), track(2), track(3)])
        let source = queue.source
        _ = queue.playEntry(id: source[2].id)
        _ = queue.playEntry(id: source[1].id)

        XCTAssertEqual(queue.previous()?.item.id, 3)
        XCTAssertEqual(queue.previous()?.item.id, 1)

        var fallback = PlaybackQueue()
        _ = fallback.replaceSource([track(1), track(2), track(3)])
        XCTAssertEqual(fallback.previous()?.item.id, 3)
    }

    func testPreviousDoesNotCreateExplicitNextAndResumesAfterQueuedSong() {
        var queue = PlaybackQueue()
        _ = queue.replaceSource([track(1), track(2), track(3), track(4), track(5), track(6)], startIndex: 2)

        _ = queue.enqueueNext([track(5)])
        XCTAssertEqual(queue.source.map(\.item.id), [1, 2, 3, 5, 4, 6])

        XCTAssertEqual(queue.previous()?.item.id, 2)
        XCTAssertEqual(queue.upNext.map(\.item.id), [5])
        XCTAssertEqual(queue.upcomingCount, 1)
        XCTAssertEqual(queue.source.map(\.item.id), [1, 2, 5, 3, 4, 6])
        XCTAssertEqual(Set(queue.visibleEntries.map(\.id)).count, queue.source.count)

        XCTAssertEqual(queue.next(isNaturalCompletion: false)?.item.id, 5)
        XCTAssertEqual(queue.upcomingCount, 0)
        XCTAssertEqual(queue.next(isNaturalCompletion: false)?.item.id, 3)
    }

    func testDirectPlayRebasesPendingEntriesAfterNewCurrent() {
        var queue = PlaybackQueue()
        _ = queue.replaceSource([track(1), track(2), track(3), track(4)], startIndex: 2)
        _ = queue.enqueueNext([track(4)])
        let second = queue.source.first { $0.item.id == 2 }!

        XCTAssertEqual(queue.playEntry(id: second.id)?.item.id, 2)
        XCTAssertEqual(queue.source.map(\.item.id), [1, 2, 4, 3])
        XCTAssertEqual(queue.next(isNaturalCompletion: false)?.item.id, 4)
        XCTAssertEqual(queue.next(isNaturalCompletion: false)?.item.id, 3)
    }

    func testDuplicateSongsKeepDistinctQueueEntryIdentity() {
        var queue = PlaybackQueue()
        _ = queue.replaceSource([track(7), track(7)])

        let first = try! XCTUnwrap(queue.current)
        let second = try! XCTUnwrap(queue.next(isNaturalCompletion: false))

        XCTAssertEqual(first.item.id, second.item.id)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(queue.history.map(\.id), [first.id])
    }

    func testShuffleDoesNotImmediatelyRepeatWithMultipleSourceEntries() {
        var queue = PlaybackQueue()
        _ = queue.replaceSource([track(1), track(2), track(3)], mode: .shuffle)

        for _ in 0..<30 {
            let previous = queue.current?.id
            let next = queue.next(isNaturalCompletion: true)?.id
            XCTAssertNotNil(next)
            XCTAssertNotEqual(next, previous)
        }
    }

    func testShuffleResumesAfterExplicitNextWithoutRepeatingIt() {
        var queue = PlaybackQueue()
        _ = queue.replaceSource([track(1), track(2), track(3), track(4), track(5)], startIndex: 2, mode: .shuffle)
        let source = queue.source
        let current = source[2]
        let queued = source[4]
        queue = PlaybackQueue(snapshot: PlaybackQueueSnapshot(
            source: source,
            current: current,
            upNext: [queued],
            history: [],
            mode: .shuffle,
            shuffleOrder: source.map(\.id),
            shuffleCursor: 2
        ))

        XCTAssertEqual(queue.previous()?.item.id, 2)
        let snapshot = queue.snapshot
        let currentIndex = try! XCTUnwrap(snapshot.shuffleOrder.firstIndex(of: queue.current!.id))
        let expectedAfterQueued = snapshot.shuffleOrder[currentIndex + 2]

        XCTAssertEqual(queue.next(isNaturalCompletion: false)?.id, queued.id)
        let resumed = try! XCTUnwrap(queue.next(isNaturalCompletion: false))
        XCTAssertEqual(resumed.id, expectedAfterQueued)
        XCTAssertNotEqual(resumed.id, queued.id)
    }

    func testRemovingCurrentPrefersExplicitNextThenFollowingSourceItem() {
        var queue = PlaybackQueue()
        _ = queue.replaceSource([track(1), track(2), track(3)], startIndex: 1)
        _ = queue.enqueueNext([track(9)])
        let current = try! XCTUnwrap(queue.current)

        XCTAssertEqual(queue.removeEntry(id: current.id)?.item.id, 9)

        var sequential = PlaybackQueue()
        _ = sequential.replaceSource([track(1), track(2), track(3)], startIndex: 1)
        let sequentialCurrent = try! XCTUnwrap(sequential.current)

        XCTAssertEqual(sequential.removeEntry(id: sequentialCurrent.id)?.item.id, 3)
    }

    func testSnapshotRoundTripPreservesQueueIdentityAndRandomOrder() throws {
        var queue = PlaybackQueue()
        _ = queue.replaceSource([track(1), track(2), track(3)], startIndex: 1, mode: .shuffle)
        _ = queue.enqueueNext([track(4), track(5)])
        _ = queue.next(isNaturalCompletion: false)
        let snapshot = queue.snapshot

        let data = try JSONEncoder().encode(snapshot)
        let restoredSnapshot = try JSONDecoder().decode(PlaybackQueueSnapshot.self, from: data)
        let restoredQueue = PlaybackQueue(snapshot: restoredSnapshot)

        XCTAssertEqual(restoredQueue.snapshot, snapshot)
    }

    func testLegacySnapshotNormalizesStandaloneExplicitNextEntry() throws {
        let first = PlaybackQueueEntry(item: track(1))
        let second = PlaybackQueueEntry(item: track(2))
        let queued = PlaybackQueueEntry(item: track(3))
        let legacySnapshot = PlaybackQueueSnapshot(
            source: [first, second],
            current: first,
            upNext: [queued],
            history: [],
            mode: .repeatAll,
            shuffleOrder: [first.id, second.id],
            shuffleCursor: 0
        )

        let restoredSnapshot = try JSONDecoder().decode(
            PlaybackQueueSnapshot.self,
            from: JSONEncoder().encode(legacySnapshot)
        )
        var queue = PlaybackQueue(snapshot: restoredSnapshot)

        XCTAssertEqual(queue.source.map(\.item.id), [1, 3, 2])
        XCTAssertEqual(queue.upNext.map(\.id), [queued.id])
        XCTAssertEqual(Set(queue.visibleEntries.map(\.id)).count, 3)
        XCTAssertEqual(queue.next(isNaturalCompletion: false)?.id, queued.id)
        XCTAssertEqual(queue.next(isNaturalCompletion: false)?.id, second.id)
    }

    func testLegacySnapshotReusesMatchingSourceEntryForExplicitNext() {
        let first = PlaybackQueueEntry(item: track(1))
        let second = PlaybackQueueEntry(item: track(2))
        let third = PlaybackQueueEntry(item: track(3))
        let legacyQueuedCopy = PlaybackQueueEntry(item: track(3))
        let legacySnapshot = PlaybackQueueSnapshot(
            source: [first, second, third],
            current: first,
            upNext: [legacyQueuedCopy],
            history: [],
            mode: .repeatAll,
            shuffleOrder: [first.id, second.id, third.id],
            shuffleCursor: 0
        )

        let queue = PlaybackQueue(snapshot: legacySnapshot)

        XCTAssertEqual(queue.source.map(\.item.id), [1, 3, 2])
        XCTAssertEqual(queue.upNext.map(\.id), [third.id])
        XCTAssertEqual(Set(queue.visibleEntries.map(\.id)).count, 3)
    }

    private func track(_ id: UInt64) -> PlaylistItem {
        PlaylistItem(
            id: id,
            url: URL(string: "https://example.invalid/\(id).mp3"),
            title: "Track \(id)",
            artist: "Artist",
            albumId: 1,
            ext: "mp3",
            duration: CMTime(seconds: 180, preferredTimescale: 1_000),
            artworkUrl: nil,
            nsSong: nil
        )
    }
}
