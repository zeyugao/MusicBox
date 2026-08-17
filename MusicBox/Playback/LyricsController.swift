import Foundation
import Observation

struct LyricsState {
    var songID: UInt64?
    var lines: [CloudMusicApi.LyricLine] = []
    var currentIndex: Int?
    var isLoading = false
    var errorMessage: String?
    var scrollResetToken = UUID()

    var currentLine: CloudMusicApi.LyricLine? {
        guard let currentIndex, lines.indices.contains(currentIndex) else { return nil }
        return lines[currentIndex]
    }
}

@MainActor
@Observable
final class LyricsController {
    private let repository: (any PlaybackResourceServing)?
    private let loader: ((UInt64) async -> CloudMusicApi.LyricNew?)?
    private let sleep: @Sendable (Duration) async -> Void
    private var loadTask: Task<Void, Never>?
    private var scheduleTask: Task<Void, Never>?
    private var positionProvider: (() -> Double)?
    private var isPlaying = false
    private var loadGeneration: UInt64 = 0
    private var scheduleGeneration: UInt64 = 0

    private(set) var state = LyricsState()

    init(
        repository: any PlaybackResourceServing,
        sleep: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        }
    ) {
        self.repository = repository
        loader = nil
        self.sleep = sleep
    }

    init(
        load: @escaping (UInt64) async -> CloudMusicApi.LyricNew?,
        sleep: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        }
    ) {
        repository = nil
        loader = load
        self.sleep = sleep
    }

    func configurePositionProvider(_ provider: @escaping () -> Double) {
        positionProvider = provider
        resynchronizeAndSchedule()
    }

    func load(for songID: UInt64) {
        loadTask?.cancel()
        cancelScheduledUpdate()
        loadGeneration &+= 1
        let generation = loadGeneration
        state = LyricsState(songID: songID, isLoading: true)

        loadTask = Task { [weak self] in
            guard let self else { return }
            let response: CloudMusicApi.LyricNew?
            if let loader = self.loader {
                response = await loader(songID)
            } else {
                response = await self.repository?.lyrics(for: songID)
            }
            guard !Task.isCancelled,
                self.loadGeneration == generation,
                self.state.songID == songID
            else { return }
            var nextState = self.state
            nextState.isLoading = false
            guard let response else {
                nextState.errorMessage = String(localized: "lyrics.load.failed")
                self.state = nextState
                return
            }
            let lines = response.merge()
            let position = self.positionProvider?()
            nextState.lines = lines
            nextState.currentIndex = position.flatMap { self.lyricIndex(at: $0, in: lines) }
            nextState.errorMessage = nil
            nextState.scrollResetToken = UUID()
            self.state = nextState
            if let position {
                self.resynchronizeAndSchedule(at: position)
            }
        }
    }

    func clear() {
        loadTask?.cancel()
        loadGeneration &+= 1
        cancelScheduledUpdate()
        isPlaying = false
        state = LyricsState()
    }

    func synchronize(at position: Double) {
        let index = lyricIndex(at: position)
        guard state.currentIndex != index else { return }
        state.currentIndex = index
    }

    func playbackStateDidChange(isPlaying: Bool) {
        self.isPlaying = isPlaying
        resynchronizeAndSchedule()
    }

    func seeked() {
        resynchronizeAndSchedule()
    }

    func reconcile(afterTimelineCorrection correction: Double, at position: Double) {
        guard abs(correction) >= 0.01 else { return }
        resynchronizeAndSchedule(at: position)
    }

    func lyricIndex(at position: Double) -> Int? {
        lyricIndex(at: position, in: state.lines)
    }

    private func lyricIndex(at position: Double, in lines: [CloudMusicApi.LyricLine]) -> Int? {
        guard !lines.isEmpty else { return nil }
        var lower = 0
        var upper = lines.count - 1
        var result: Int?
        while lower <= upper {
            let midpoint = (lower + upper) / 2
            if lines[midpoint].time <= position {
                result = midpoint
                lower = midpoint + 1
            } else {
                upper = midpoint - 1
            }
        }
        return result
    }

    private func resynchronizeAndSchedule(at suppliedPosition: Double? = nil) {
        cancelScheduledUpdate()
        let position: Double
        if let suppliedPosition {
            position = suppliedPosition
        } else {
            guard let positionProvider else { return }
            position = positionProvider()
        }
        synchronize(at: position)
        guard isPlaying, let nextTime = nextTimestamp(after: position) else { return }

        let delayMilliseconds = max(1, Int(((nextTime - position) * 1_000).rounded(.up)))
        let generation = scheduleGeneration
        let sleep = self.sleep
        scheduleTask = Task { [weak self, sleep] in
            await sleep(.milliseconds(delayMilliseconds))
            guard !Task.isCancelled,
                let self,
                self.scheduleGeneration == generation
            else { return }
            self.scheduleTask = nil
            self.resynchronizeAndSchedule()
        }
    }

    private func nextTimestamp(after _: Double) -> Double? {
        if let currentIndex = state.currentIndex, state.lines.indices.contains(currentIndex + 1) {
            return state.lines[currentIndex + 1].time
        } else if let first = state.lines.first, state.currentIndex == nil {
            return first.time
        } else {
            return nil
        }
    }

    private func cancelScheduledUpdate() {
        scheduleGeneration &+= 1
        scheduleTask?.cancel()
        scheduleTask = nil
    }

}
