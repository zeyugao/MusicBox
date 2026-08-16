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
    private var loadTask: Task<Void, Never>?
    private var precisionTimer: Timer?
    private var positionProvider: (() -> Double)?

    private(set) var state = LyricsState()

    init(repository: any PlaybackResourceServing) {
        self.repository = repository
        loader = nil
    }

    init(load: @escaping (UInt64) async -> CloudMusicApi.LyricNew?) {
        repository = nil
        loader = load
    }

    func load(for songID: UInt64) {
        loadTask?.cancel()
        stopSynchronizing()
        state = LyricsState(songID: songID, isLoading: true)

        loadTask = Task { [weak self] in
            guard let self else { return }
            let response: CloudMusicApi.LyricNew?
            if let loader = self.loader {
                response = await loader(songID)
            } else {
                response = await self.repository?.lyrics(for: songID)
            }
            guard !Task.isCancelled, self.state.songID == songID else { return }
            self.state.isLoading = false
            guard let response else {
                self.state.errorMessage = String(localized: "lyrics.load.failed")
                return
            }
            self.state.lines = response.merge()
            self.state.currentIndex = nil
            self.state.scrollResetToken = UUID()
        }
    }

    func clear() {
        loadTask?.cancel()
        stopSynchronizing()
        state = LyricsState()
    }

    func synchronize(at position: Double) {
        state.currentIndex = lyricIndex(at: position)
    }

    func startSynchronizing(positionProvider: @escaping () -> Double) {
        self.positionProvider = positionProvider
        scheduleNextUpdate()
    }

    func stopSynchronizing() {
        precisionTimer?.invalidate()
        precisionTimer = nil
        positionProvider = nil
    }

    func lyricIndex(at position: Double) -> Int? {
        guard !state.lines.isEmpty else { return nil }
        var lower = 0
        var upper = state.lines.count - 1
        var result: Int?
        while lower <= upper {
            let midpoint = (lower + upper) / 2
            if state.lines[midpoint].time <= position {
                result = midpoint
                lower = midpoint + 1
            } else {
                upper = midpoint - 1
            }
        }
        return result
    }

    private func scheduleNextUpdate() {
        precisionTimer?.invalidate()
        guard let positionProvider else { return }
        let position = positionProvider()
        synchronize(at: position)

        let nextTime: Double
        if let currentIndex = state.currentIndex, state.lines.indices.contains(currentIndex + 1) {
            nextTime = state.lines[currentIndex + 1].time
        } else if let first = state.lines.first, state.currentIndex == nil {
            nextTime = first.time
        } else {
            nextTime = position + 1
        }

        let interval = max(0.01, min(nextTime - position, 5))
        precisionTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleNextUpdate()
            }
        }
    }

}
