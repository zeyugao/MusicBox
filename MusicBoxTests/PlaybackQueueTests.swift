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
