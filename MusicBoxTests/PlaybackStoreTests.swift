import CoreMedia
import Foundation
import XCTest

@testable import MusicBox

final class PlaybackStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "PlaybackStoreTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    @MainActor
    func testSessionRestoresQueuePositionAndVolume() async throws {
        var queue = PlaybackQueue()
        _ = queue.replaceSource([track(1), track(2), track(3)], startIndex: 1, mode: .shuffle)
        _ = queue.enqueueNext([track(4), track(5)])
        let snapshot = PlaybackSessionSnapshot(queue: queue.snapshot, position: 42.5, volume: 0.35)
        defaults.set(try JSONEncoder().encode(snapshot), forKey: PlaybackStore.sessionKey)

        let engine = FakePlaybackEngine()
        let store = makeStore(engine: engine)
        store.restore()
        await settle()

        XCTAssertEqual(store.queue.snapshot, snapshot.queue)
        XCTAssertEqual(store.state.position, 42.5, accuracy: 0.001)
        XCTAssertEqual(store.state.volume, 0.35, accuracy: 0.001)
        XCTAssertEqual(engine.volume, 0.35, accuracy: 0.001)
        XCTAssertEqual(engine.loads.count, 1)
        XCTAssertEqual(engine.loads[0].position, 42.5, accuracy: 0.001)
        XCTAssertFalse(engine.loads[0].autoplay)
    }

    @MainActor
    func testLegacySessionMigratesExplicitNextAndMode() async throws {
        let legacyQueue = LegacyQueueFixture(
            playlist: [track(1), track(2), track(3), track(4)],
            currentItemIndex: 1,
            loopMode: .shuffle,
            playNextItemsCount: 2
        )
        let legacyProgress = LegacyProgressFixture(playedSecond: 21.25, volume: 0.6)
        defaults.set(try JSONEncoder().encode(legacyQueue), forKey: "PlaylistStatus")
        defaults.set(try JSONEncoder().encode(legacyProgress), forKey: "PlayStatus")

        let engine = FakePlaybackEngine()
        let store = makeStore(engine: engine)
        store.restore()
        await settle()

        XCTAssertEqual(store.queue.source.map(\.item.id), [1, 2, 3, 4])
        XCTAssertEqual(store.queue.current?.item.id, 2)
        XCTAssertEqual(store.queue.upNext.map(\.item.id), [3, 4])
        XCTAssertEqual(store.queue.mode, .shuffle)
        XCTAssertEqual(store.state.position, 21.25, accuracy: 0.001)
        XCTAssertEqual(store.state.volume, 0.6, accuracy: 0.001)
        XCTAssertNotNil(defaults.data(forKey: PlaybackStore.sessionKey))
    }

    @MainActor
    func testDelayedResolutionHonorsPlayAndDropsStaleEngineEvents() async throws {
        let engine = FakePlaybackEngine()
        let resolver = AudioSourceResolver { item in
            if item.id == 1 {
                try? await Task.sleep(for: .milliseconds(80))
            }
            return .local(URL(fileURLWithPath: "/tmp/\(item.id).mp3"))
        }
        let store = PlaybackStore(
            resolver: resolver,
            lyrics: LyricsController(load: { _ in nil }),
            engine: engine,
            defaults: defaults
        )

        store.replaceSource([track(1)], autoplay: false)
        store.play()
        store.replaceSource([track(2)], autoplay: false)
        store.play()
        await settle(milliseconds: 120)

        XCTAssertEqual(store.currentItem?.id, 2)
        XCTAssertEqual(engine.loads.map(\.generation), [2])
        XCTAssertTrue(engine.loads[0].autoplay)

        engine.send(.ready(duration: 999), generation: 1)
        XCTAssertEqual(store.state.duration, 180, accuracy: 0.001)

        engine.send(.ready(duration: 200), generation: 2)
        XCTAssertEqual(store.state.duration, 200, accuracy: 0.001)
    }

    @MainActor
    func testSavingPersistsPlaybackPositionAndQueueIdentity() async throws {
        let engine = FakePlaybackEngine()
        let store = makeStore(engine: engine)
        store.replaceSource([track(1), track(1), track(2)], startIndex: 1)
        await settle()
        engine.send(.position(position: 73.25, duration: 180), generation: 1)
        store.setVolume(0.2)
        store.saveSession()

        let data = try XCTUnwrap(defaults.data(forKey: PlaybackStore.sessionKey))
        let snapshot = try JSONDecoder().decode(PlaybackSessionSnapshot.self, from: data)
        XCTAssertEqual(snapshot.queue, store.queue.snapshot)
        XCTAssertEqual(snapshot.position, 73.25, accuracy: 0.001)
        XCTAssertEqual(snapshot.volume, 0.2, accuracy: 0.001)
        XCTAssertNotEqual(snapshot.queue.source[0].id, snapshot.queue.source[1].id)
    }

    @MainActor
    func testLyricsFindsBoundaryAndClearsOnItemChange() async throws {
        let lyricsData = Data(#"""
        {"lrc":{"lyric":"[00:01.00]first\n[00:03.50]second","version":1}}
        """#.utf8)
        let response = try JSONDecoder().decode(CloudMusicApi.LyricNew.self, from: lyricsData)
        let lyrics = LyricsController(load: { _ in response })

        lyrics.load(for: 1)
        await settle()
        XCTAssertNil(lyrics.lyricIndex(at: 0.99))
        XCTAssertEqual(lyrics.lyricIndex(at: 1), 0)
        XCTAssertEqual(lyrics.lyricIndex(at: 3.49), 0)
        XCTAssertEqual(lyrics.lyricIndex(at: 3.5), 1)

        lyrics.clear()
        XCTAssertNil(lyrics.state.songID)
        XCTAssertTrue(lyrics.state.lines.isEmpty)
    }

    @MainActor
    private func makeStore(engine: FakePlaybackEngine) -> PlaybackStore {
        PlaybackStore(
            resolver: AudioSourceResolver { item in .local(URL(fileURLWithPath: "/tmp/\(item.id).mp3")) },
            lyrics: LyricsController(load: { _ in nil }),
            engine: engine,
            defaults: defaults
        )
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

    private func settle(milliseconds: Int = 0) async {
        if milliseconds > 0 {
            try? await Task.sleep(for: .milliseconds(milliseconds))
        }
        await Task.yield()
        await Task.yield()
    }
}

@MainActor
private final class FakePlaybackEngine: PlaybackEngineControlling {
    struct Load {
        let generation: Int
        let position: Double
        let autoplay: Bool
    }

    var volume: Float = 1
    var onEvent: ((PlaybackEngineEvent, Int) -> Void)?
    private(set) var loads: [Load] = []
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var stopCount = 0

    func load(source _: ResolvedAudioSource, generation: Int, position: Double, autoplay: Bool) {
        loads.append(Load(generation: generation, position: position, autoplay: autoplay))
    }

    func play() {
        playCount += 1
    }

    func pause() {
        pauseCount += 1
    }

    func seek(to _: Double, completion: @escaping () -> Void) {
        completion()
    }

    func stop() {
        stopCount += 1
    }

    func send(_ event: PlaybackEngineEvent, generation: Int) {
        onEvent?(event, generation)
    }
}

private struct LegacyQueueFixture: Codable {
    let playlist: [PlaylistItem]
    let currentItemIndex: Int?
    let loopMode: LegacyLoopModeFixture
    let playNextItemsCount: Int?
}

private struct LegacyProgressFixture: Codable {
    let playedSecond: Double
    let volume: Float
}

private enum LegacyLoopModeFixture: Codable {
    case once
    case shuffle
    case sequence
}
