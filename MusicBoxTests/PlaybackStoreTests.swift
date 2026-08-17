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
    func testPositionSamplesDoNotEmitQueueOrPlaybackLifecycleEvents() async {
        let engine = FakePlaybackEngine()
        let store = makeStore(engine: engine)
        var emittedKinds: [String] = []
        let token = store.addEventListener { event in
            switch event {
            case .queueChanged: emittedKinds.append("queue")
            case .modeChanged: emittedKinds.append("mode")
            case .itemChanged: emittedKinds.append("item")
            case .playbackChanged: emittedKinds.append("playback")
            case .positionChanged: emittedKinds.append("position")
            case .didStart: emittedKinds.append("start")
            case .didEnd: emittedKinds.append("end")
            case .failed: emittedKinds.append("failed")
            }
        }
        defer { store.removeEventListener(token) }

        store.replaceSource([track(1)], autoplay: false)
        await settle()
        engine.send(.ready(duration: 180), generation: 1)
        engine.send(.playbackChanged(true), generation: 1)
        emittedKinds.removeAll()

        engine.send(.position(position: 12.5, duration: 180), generation: 1)

        XCTAssertEqual(emittedKinds, ["position"])
    }

    @MainActor
    func testPeriodicPersistenceIsNotResetByPositionSamples() async throws {
        var now = 100.0
        let engine = FakePlaybackEngine()
        let store = PlaybackStore(
            resolver: AudioSourceResolver { item in .local(URL(fileURLWithPath: "/tmp/\(item.id).mp3")) },
            lyrics: LyricsController(load: { _ in nil }),
            engine: engine,
            defaults: defaults,
            currentUptime: { now },
            persistenceInterval: .milliseconds(20)
        )

        store.replaceSource([track(1)], autoplay: false)
        await settle()
        engine.send(.ready(duration: 180), generation: 1)
        engine.send(.playbackChanged(true), generation: 1)
        engine.send(.position(position: 10, duration: 180), generation: 1)
        now = 100.1
        engine.send(.position(position: 10.1, duration: 180), generation: 1)
        now = 100.2
        engine.send(.position(position: 10.2, duration: 180), generation: 1)

        await settle(milliseconds: 40)

        let data = try XCTUnwrap(defaults.data(forKey: PlaybackStore.sessionKey))
        let snapshot = try JSONDecoder().decode(PlaybackSessionSnapshot.self, from: data)
        XCTAssertEqual(snapshot.position, 10.2, accuracy: 0.001)
    }

    @MainActor
    func testSeekAndPausePersistTheTimelineImmediately() async throws {
        var now = 100.0
        let engine = FakePlaybackEngine()
        let store = PlaybackStore(
            resolver: AudioSourceResolver { item in .local(URL(fileURLWithPath: "/tmp/\(item.id).mp3")) },
            lyrics: LyricsController(load: { _ in nil }),
            engine: engine,
            defaults: defaults,
            currentUptime: { now }
        )

        store.replaceSource([track(1)], autoplay: false)
        await settle()
        engine.send(.ready(duration: 180), generation: 1)
        engine.send(.position(position: 20, duration: 180), generation: 1)

        store.seek(to: 75)
        XCTAssertEqual(try sessionSnapshot().position, 75, accuracy: 0.001)

        engine.send(.playbackChanged(true), generation: 1)
        now = 100.5
        store.pause()
        XCTAssertEqual(try sessionSnapshot().position, 75.5, accuracy: 0.001)
        engine.send(.playbackChanged(false), generation: 1)
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

    @MainActor
    private func sessionSnapshot() throws -> PlaybackSessionSnapshot {
        let data = try XCTUnwrap(defaults.data(forKey: PlaybackStore.sessionKey))
        return try JSONDecoder().decode(PlaybackSessionSnapshot.self, from: data)
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

final class PlaybackTimelineTests: XCTestCase {
    func testGraduallyAbsorbsSmallLowFrequencySampleErrors() {
        var timeline = PlaybackTimeline()
        timeline.reset(position: 10, duration: 180, isAdvancing: true, at: 100)

        XCTAssertEqual(timeline.position(at: 100.1), 10.1, accuracy: 0.001)

        let correction = timeline.applySample(position: 10.4, duration: 180, at: 100.25)
        XCTAssertEqual(correction, 0.15, accuracy: 0.001)
        XCTAssertEqual(timeline.position(at: 100.25), 10.25, accuracy: 0.001)

        let midpoint = 100.25 + PlaybackTimeline.sampleCorrectionDuration / 2
        XCTAssertEqual(timeline.position(at: midpoint), 10.575, accuracy: 0.001)
        XCTAssertEqual(
            timeline.position(at: 100.25 + PlaybackTimeline.sampleCorrectionDuration),
            10.9,
            accuracy: 0.001
        )
    }

    func testHardSampleErrorsStillSnapToTheAuthoritativePosition() {
        var timeline = PlaybackTimeline()
        timeline.reset(position: 10, duration: 180, isAdvancing: true, at: 100)

        let correction = timeline.applySample(position: 11.5, duration: 180, at: 100.5)

        XCTAssertEqual(correction, 1, accuracy: 0.001)
        XCTAssertEqual(timeline.position(at: 100.5), 11.5, accuracy: 0.001)
        XCTAssertEqual(timeline.position(at: 100.6), 11.6, accuracy: 0.001)
    }

    func testFreezesAndResumesWithoutLosingTheAnchor() {
        var timeline = PlaybackTimeline()
        timeline.reset(position: 10, duration: 180, isAdvancing: true, at: 100)

        timeline.setAdvancing(false, at: 100.1)
        XCTAssertEqual(timeline.position(at: 100.5), 10.1, accuracy: 0.001)

        timeline.setAdvancing(true, at: 100.5)
        XCTAssertEqual(timeline.position(at: 100.75), 10.35, accuracy: 0.001)
    }

    func testSeekItemChangesAndTrackBoundsResetTheTimeline() {
        var timeline = PlaybackTimeline()
        timeline.reset(position: 75, duration: 180, isAdvancing: false, at: 101)
        XCTAssertEqual(timeline.position(at: 101.1), 75, accuracy: 0.001)

        timeline.reset(position: 0, duration: 240, isAdvancing: true, at: 102)
        XCTAssertEqual(timeline.position(at: 102.1), 0.1, accuracy: 0.001)

        timeline.reset(position: 999, duration: 180, isAdvancing: true, at: 103)
        XCTAssertEqual(timeline.position(at: 104), 180, accuracy: 0.001)
    }
}

final class PlaybackProgressMotionTests: XCTestCase {
    func testAdvancesAtPlaybackRateWhenTheCoreTimelineMatches() {
        var motion = PlaybackProgressMotion()
        motion.reset(position: 10, duration: 180, isAdvancing: true, at: 100)

        XCTAssertEqual(
            motion.advance(toward: 10.1, duration: 180, isAdvancing: true, at: 100.1),
            10.1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            motion.advance(toward: 10.6, duration: 180, isAdvancing: true, at: 100.6),
            10.6,
            accuracy: 0.001
        )
    }

    func testAbsorbsSmallCorrectionsWithAContinuousLimitedVelocity() {
        var motion = PlaybackProgressMotion()
        motion.reset(position: 10, duration: 180, isAdvancing: true, at: 100)

        XCTAssertEqual(
            motion.advance(toward: 10.35, duration: 180, isAdvancing: true, at: 100.1),
            10.1075,
            accuracy: 0.001
        )
        XCTAssertEqual(
            motion.advance(toward: 10.45, duration: 180, isAdvancing: true, at: 100.2),
            10.2275,
            accuracy: 0.001
        )
    }

    func testHardResetsForLargeTimelineDrift() {
        var motion = PlaybackProgressMotion()
        motion.reset(position: 10, duration: 180, isAdvancing: true, at: 100)

        XCTAssertEqual(
            motion.advance(toward: 12, duration: 180, isAdvancing: true, at: 100.1),
            12,
            accuracy: 0.001
        )
    }

    func testFreezesAndDurationChangesResetTheVisualPosition() {
        var motion = PlaybackProgressMotion()
        motion.reset(position: 10, duration: 180, isAdvancing: false, at: 100)

        XCTAssertEqual(
            motion.advance(toward: 10, duration: 180, isAdvancing: false, at: 100.5),
            10,
            accuracy: 0.001
        )
        XCTAssertEqual(
            motion.advance(toward: 40, duration: 40, isAdvancing: true, at: 101),
            40,
            accuracy: 0.001
        )
    }
}

final class PlaybackProgressInteractionTests: XCTestCase {
    func testMapsPointerLocationsIntoTheTrackBounds() {
        XCTAssertEqual(PlaybackProgressInteraction.position(for: -10, width: 100, duration: 240), 0)
        XCTAssertEqual(PlaybackProgressInteraction.position(for: 25, width: 100, duration: 240), 60)
        XCTAssertEqual(PlaybackProgressInteraction.position(for: 120, width: 100, duration: 240), 240)
        XCTAssertEqual(PlaybackProgressInteraction.position(for: 25, width: 0, duration: 240), 0)
    }

    func testDragPreviewsUntilMouseReleaseProducesOneCommitValue() {
        var interaction = PlaybackProgressInteraction()

        XCTAssertEqual(interaction.begin(location: 20, width: 100, duration: 200), 40)
        XCTAssertTrue(interaction.isTracking)
        XCTAssertEqual(interaction.update(location: 45, width: 100, duration: 200), 90)
        XCTAssertEqual(interaction.update(location: 70, width: 100, duration: 200), 140)
        XCTAssertEqual(interaction.end(location: 80, width: 100, duration: 200), 160)
        XCTAssertFalse(interaction.isTracking)
        XCTAssertNil(interaction.end(location: 90, width: 100, duration: 200))
    }

    func testCancelledDragDoesNotProduceACommitValue() {
        var interaction = PlaybackProgressInteraction()

        _ = interaction.begin(location: 50, width: 100, duration: 200)
        XCTAssertTrue(interaction.cancel())
        XCTAssertFalse(interaction.isTracking)
        XCTAssertNil(interaction.update(location: 75, width: 100, duration: 200))
    }
}

final class PlaybackProgressThumbVisibilityTests: XCTestCase {
    func testKeepsTheThumbVisibleForPointThreeSecondsAfterPointerExit() {
        var visibility = PlaybackProgressThumbVisibility()
        visibility.pointerEntered()

        XCTAssertTrue(visibility.isVisible)
        XCTAssertEqual(visibility.pointerExited(at: 10), 10.3)
        XCTAssertFalse(visibility.hideIfDue(at: 10.299))
        XCTAssertTrue(visibility.isVisible)
        XCTAssertTrue(visibility.hideIfDue(at: 10.3))
        XCTAssertFalse(visibility.isVisible)
    }

    func testDraggingOutsideDefersTheCountdownUntilRelease() {
        var visibility = PlaybackProgressThumbVisibility()
        visibility.pointerEntered()

        XCTAssertNil(visibility.setTracking(true, at: 10))
        XCTAssertNil(visibility.pointerExited(at: 11))
        XCTAssertTrue(visibility.isVisible)
        XCTAssertEqual(visibility.setTracking(false, at: 12), 12.3)
        XCTAssertFalse(visibility.hideIfDue(at: 12.299))
        XCTAssertTrue(visibility.hideIfDue(at: 12.3))
    }

    func testPointerReentryCancelsAPendingHide() {
        var visibility = PlaybackProgressThumbVisibility()
        visibility.pointerEntered()
        XCTAssertEqual(visibility.pointerExited(at: 10), 10.3)

        visibility.pointerEntered()
        XCTAssertFalse(visibility.hideIfDue(at: 20))
        XCTAssertTrue(visibility.isVisible)
    }
}

@MainActor
final class LyricsControllerTests: XCTestCase {
    func testLyricsLoadedAfterPlaybackStartsUseTheCurrentTimelinePosition() async throws {
        var position = 3.5
        let expectedResponse = try response("[00:01.00]first\n[00:03.50]second")
        let lyrics = LyricsController(load: { _ in
            try? await Task.sleep(for: .milliseconds(20))
            return expectedResponse
        })
        lyrics.configurePositionProvider { position }
        lyrics.playbackStateDidChange(isPlaying: true)
        lyrics.load(for: 1)

        try? await Task.sleep(for: .milliseconds(40))
        await settle()

        XCTAssertEqual(lyrics.state.currentIndex, 1)
        lyrics.playbackStateDidChange(isPlaying: false)
        position = 0
    }

    func testClearRetainsTimelineProviderForTheNextTrack() async throws {
        var position = 2.5
        let response = try response("[00:01.00]first\n[00:02.00]second")
        let lyrics = LyricsController(load: { _ in response })
        lyrics.configurePositionProvider { position }
        lyrics.clear()
        lyrics.load(for: 2)
        await settle()
        lyrics.playbackStateDidChange(isPlaying: true)

        XCTAssertEqual(lyrics.state.currentIndex, 1)
        lyrics.playbackStateDidChange(isPlaying: false)
        position = 0
    }

    func testSampleReconcileUsesTheAuthoritativePositionDuringVisualCorrection() async throws {
        var displayedPosition = 2.9
        let response = try response("[00:01.00]first\n[00:03.00]second")
        let lyrics = LyricsController(load: { _ in response })
        lyrics.configurePositionProvider { displayedPosition }
        lyrics.load(for: 1)
        await settle()
        lyrics.playbackStateDidChange(isPlaying: true)

        lyrics.reconcile(afterTimelineCorrection: 0.1, at: 3.05)

        XCTAssertEqual(lyrics.state.currentIndex, 1)
        lyrics.playbackStateDidChange(isPlaying: false)
        displayedPosition = 0
    }

    func testSeekInvalidatesAnOlderLyricSchedule() async throws {
        let sleeper = ManualLyricsSleeper()
        var position = 0.0
        let response = try response("[00:01.00]first\n[00:03.00]second\n[00:05.00]third")
        let lyrics = LyricsController(
            load: { _ in response },
            sleep: { duration in await sleeper.sleep(for: duration) }
        )
        lyrics.configurePositionProvider { position }
        lyrics.load(for: 1)
        await settle()
        lyrics.playbackStateDidChange(isPlaying: true)
        await waitForPendingSleeps(1, sleeper: sleeper)

        position = 3
        lyrics.seeked()
        XCTAssertEqual(lyrics.state.currentIndex, 1)
        await waitForPendingSleeps(2, sleeper: sleeper)

        await sleeper.resumeNext()
        await settle()
        XCTAssertEqual(lyrics.state.currentIndex, 1)

        position = 5
        await sleeper.resumeNext()
        await settle()
        XCTAssertEqual(lyrics.state.currentIndex, 2)

        lyrics.playbackStateDidChange(isPlaying: false)
        await sleeper.resumeAll()
    }

    func testParserSupportsMetadataMultipleTagsMillisecondsAndMergedTranslations() throws {
        let data = Data(#"""
        {
          "lrc": {"lyric":"[ar:Artist]\n[ti:Song]\n[offset:100]\n[00:01.000][00:02.500]main\n[00:02.500]same time", "version":1},
          "tlyric": {"lyric":"[offset:100]\n[00:01.000]translated\n[00:02.500]translated same", "version":1},
          "romalrc": {"lyric":"[offset:100]\n[00:01.000]roma\n[00:02.500]roma same", "version":1}
        }
        """#.utf8)
        let response = try JSONDecoder().decode(CloudMusicApi.LyricNew.self, from: data)

        let lines = response.merge()

        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].time, 1.1, accuracy: 0.0001)
        XCTAssertEqual(lines[0].lyric, "main")
        XCTAssertEqual(lines[0].tlyric, "translated")
        XCTAssertEqual(lines[0].romalrc, "roma")
        XCTAssertEqual(lines[1].time, 2.6, accuracy: 0.0001)
        XCTAssertEqual(lines[1].lyric, "main\nsame time")
        XCTAssertEqual(lines[1].tlyric, "translated same")
        XCTAssertEqual(lines[1].romalrc, "roma same")
    }

    private func response(_ lyric: String) throws -> CloudMusicApi.LyricNew {
        let data = try JSONSerialization.data(
            withJSONObject: ["lrc": ["lyric": lyric, "version": 1]]
        )
        return try JSONDecoder().decode(CloudMusicApi.LyricNew.self, from: data)
    }

    private func waitForPendingSleeps(_ count: Int, sleeper: ManualLyricsSleeper) async {
        for _ in 0..<100 {
            if await sleeper.pendingCount() >= count { return }
            await Task.yield()
        }
        XCTFail("Lyrics scheduler did not create \(count) pending sleeps")
    }

    private func settle() async {
        await Task.yield()
        await Task.yield()
        await Task.yield()
    }
}

final class PlaybackPositionPublicationGateTests: XCTestCase {
    func testPublishesTransitionsImmediatelyAndPositionAtMostOncePerSecond() {
        var gate = PlaybackPositionPublicationGate()

        XCTAssertTrue(gate.shouldPublish(at: 100))
        XCTAssertFalse(gate.shouldPublish(at: 100.99))
        XCTAssertTrue(gate.shouldPublish(at: 101))
        XCTAssertTrue(gate.shouldPublish(at: 101.1, force: true))
        XCTAssertFalse(gate.shouldPublish(at: 102.0))
        XCTAssertTrue(gate.shouldPublish(at: 102.1))
    }
}

@MainActor
final class PlaybackPresentationModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "PlaybackPresentationModelTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    func testPresentationUsesCoreTimelineAndFreezesForRateInterruptions() async {
        var now = 100.0
        let engine = FakePlaybackEngine()
        let store = PlaybackStore(
            resolver: AudioSourceResolver { item in .local(URL(fileURLWithPath: "/tmp/\(item.id).mp3")) },
            lyrics: LyricsController(load: { _ in nil }),
            engine: engine,
            defaults: defaults,
            currentUptime: { now }
        )
        let presentation = PlaybackPresentationModel(playback: store)

        store.replaceSource([track(1)], autoplay: false)
        await settle()
        engine.send(.ready(duration: 180), generation: 1)
        engine.send(.playbackChanged(true), generation: 1)
        engine.send(.position(position: 10, duration: 180), generation: 1)
        let queueEntries = presentation.queueEntries

        now = 100.1
        XCTAssertEqual(presentation.displayedPosition, 10.1, accuracy: 0.001)
        now = 100.4
        XCTAssertEqual(presentation.displayedPosition, 10.4, accuracy: 0.001)
        XCTAssertEqual(presentation.queueEntries, queueEntries)

        engine.send(.playbackChanged(false), generation: 1)
        now = 100.6
        XCTAssertEqual(presentation.displayedPosition, 10.4, accuracy: 0.001)

        engine.send(.playbackChanged(true), generation: 1)
        now = 100.7
        XCTAssertEqual(presentation.displayedPosition, 10.5, accuracy: 0.001)

        engine.send(.playbackChanged(false), generation: 1)
        now = 101
        XCTAssertEqual(presentation.displayedPosition, 10.5, accuracy: 0.001)

        presentation.seek(to: 75)
        XCTAssertEqual(presentation.displayedPosition, 75, accuracy: 0.001)
        XCTAssertFalse(presentation.shouldAnimateDisplayedPosition)

        presentation.clearQueue()
        XCTAssertNil(presentation.currentItem)
        XCTAssertTrue(presentation.queueEntries.isEmpty)
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

    private func settle() async {
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

private actor ManualLyricsSleeper {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func sleep(for _: Duration) async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func pendingCount() -> Int {
        continuations.count
    }

    func resumeNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func resumeAll() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
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
