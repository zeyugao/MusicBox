import AppKit
import MediaPlayer

struct PlaybackPositionPublicationGate {
    private var lastPublishedUptime: TimeInterval?

    mutating func shouldPublish(at uptime: TimeInterval, force: Bool = false) -> Bool {
        guard force || (lastPublishedUptime.map { uptime - $0 >= 1 } ?? true) else { return false }
        lastPublishedUptime = uptime
        return true
    }
}

@MainActor
final class SystemPlaybackBridge {
    private weak var playback: PlaybackStore?
    private var listenerToken: UUID?
    private var artworkTask: Task<Void, Never>?
    private var positionPublicationGate = PlaybackPositionPublicationGate()

    init(playback: PlaybackStore) {
        self.playback = playback
        listenerToken = playback.addEventListener { [weak self] event in
            self?.handle(event)
        }
        configureRemoteCommands()
    }

    private func configureRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playback?.pause() }
            return .success
        }
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playback?.play() }
            return .success
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playback?.toggle() }
            return .success
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playback?.next() }
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playback?.previous() }
            return .success
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in self?.playback?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func handle(_ event: PlaybackEvent) {
        switch event {
        case .itemChanged(let item):
            updateItem(item)
            updatePlaybackState(playback?.state.isPlaying == true)
            publishPosition(force: true)
        case .playbackChanged(let isPlaying):
            updatePlaybackState(isPlaying)
            publishPosition(force: true)
        case .positionChanged:
            publishPosition(force: playback?.state.isSeeking == true)
        case .didEnd(let item, _, .stopped):
            if item != nil { updateItem(nil) }
        case .queueChanged, .modeChanged, .didStart, .didEnd, .failed:
            break
        }
    }

    private func updateItem(_ item: PlaylistItem?) {
        artworkTask?.cancel()
        guard let item else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.artist,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: playback?.queue.sourceIndex ?? 0,
            MPNowPlayingInfoPropertyPlaybackQueueCount: playback?.queue.source.count ?? 0,
        ]
        if let albumName = item.nsSong?.albumName, !albumName.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = albumName
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        guard let artworkURL = item.artworkUrl else { return }
        artworkTask = Task { [weak self] in
            guard let self else { return }
            let image: NSImage?
            if artworkURL.isFileURL {
                image = NSImage(contentsOf: artworkURL)
            } else {
                image = try? await Self.loadImage(from: artworkURL)
            }
            guard !Task.isCancelled,
                self.playback?.currentItem?.id == item.id,
                let image
            else { return }
            var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? info
            updated[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
        }
    }

    private static func loadImage(from url: URL) async throws -> NSImage? {
        let (data, _) = try await URLSession.shared.data(from: url)
        return NSImage(data: data)
    }

    private func updatePlaybackState(_ isPlaying: Bool) {
        let center = MPNowPlayingInfoCenter.default()
        var info = center.nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }

    private func updatePosition(position: Double, duration: Double) {
        let center = MPNowPlayingInfoCenter.default()
        var info = center.nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        center.nowPlayingInfo = info
    }

    private func publishPosition(force: Bool = false) {
        guard let playback else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard positionPublicationGate.shouldPublish(at: now, force: force) else { return }
        updatePosition(position: playback.currentPosition, duration: playback.state.duration)
    }

}
