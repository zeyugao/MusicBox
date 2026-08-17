import AppKit
import AVKit
import Observation
import QuartzCore
import SwiftUI

struct PlayerCapsuleView: View {
    @Environment(AppModel.self) private var app
    @State private var isQueuePresented = false
    @State private var isVolumePresented = false
    @State private var isSeeking = false
    @State private var seekTarget = 0.0

    var body: some View {
        @Bindable var router = app.router
        let playback = app.playbackPresentation
        HStack(spacing: 24) {
            HStack(spacing: 16) {
                playerButton("backward.fill", size: 14, help: "Previous") { playback.previous() }
                playerButton(playback.isPlaying ? "pause.fill" : "play.fill", size: 16, help: playback.isPlaying ? "Pause" : "Play") {
                    playback.toggle()
                }
                .disabled(!playback.hasCurrentItem || playback.isLoading)
                .keyboardShortcut(.space, modifiers: [])
                .frame(width: 20, height: 20)
                playerButton("forward.fill", size: 14, help: "Next") { playback.next() }
                playerButton(modeIcon(playback.mode), size: 16, help: "Repeat 1") { playback.cycleMode() }
            }

            NowPlayingTrackPresentation(
                playback: playback,
                isSeeking: $isSeeking,
                seekTarget: $seekTarget
            )

            HStack(spacing: 16) {
                Button {
                    isQueuePresented.toggle()
                } label: {
                    ZStack {
                        Image(systemName: "list.bullet")
                            .resizable()
                            .frame(width: 16, height: 14)
                        if playback.explicitNextCount > 0 {
                            Text("\(playback.explicitNextCount)")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(minWidth: 12, minHeight: 12)
                                .background(Circle().fill(Color.primary))
                                .offset(x: 10, y: -10)
                        }
                    }
                }
                .buttonStyle(PlayerControlButtonStyle())
                .help("Now Playing")
                .popover(isPresented: $isQueuePresented) {
                    QueuePopoverView(isPresented: $isQueuePresented)
                }

                Button {
                    isVolumePresented.toggle()
                } label: {
                    Image(systemName: volumeIcon(playback.volume))
                        .resizable()
                        .frame(width: 16, height: 14)
                }
                .buttonStyle(PlayerControlButtonStyle())
                .help("Volume")
                .popover(isPresented: $isVolumePresented) {
                    VolumePopoverView(isPresented: $isVolumePresented)
                }

                AudioOutputDeviceButton()

                Button {
                    router.isLyricsPresented.toggle()
                } label: {
                    Image(systemName: "quote.bubble")
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(PlayerControlButtonStyle(color: router.isLyricsPresented ? .accentColor : .primary))
                .help(router.isLyricsPresented ? "Hide Lyrics" : "Show Lyrics")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: PlayerOverlayMetrics.height)
        .background(Color.gray.opacity(0.005))
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .frame(minWidth: 100, maxWidth: 600)
        .glassEffect()
    }

    private func playerButton(_ icon: String, size: CGFloat, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .resizable()
                .frame(width: size, height: size)
        }
        .buttonStyle(PlayerControlButtonStyle())
        .help(help)
    }

    private func modeIcon(_ mode: PlaybackMode) -> String {
        switch mode {
        case .repeatAll: return "repeat"
        case .shuffle: return "shuffle"
        case .repeatOne: return "repeat.1"
        }
    }

    private func volumeIcon(_ volume: Float) -> String {
        switch volume {
        case 0: return "speaker.slash.fill"
        case ..<0.33: return "speaker.wave.1.fill"
        case ..<0.66: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

}

private struct NowPlayingTrackPresentation: View {
    @Environment(AppModel.self) private var app
    let playback: PlaybackPresentationModel
    @Binding var isSeeking: Bool
    @Binding var seekTarget: Double

    var body: some View {
        trackContent
    }

    @ViewBuilder
    private var trackContent: some View {
        VStack(alignment: .leading, spacing: PlayerOverlayMetrics.trackLayoutPadding) {
            HStack(spacing: 8) {
                artwork
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(playback.currentItem?.title ?? "Title")
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        if playback.isLoading {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Spacer()
                        if let item = playback.currentItem {
                            Button {
                                Task {
                                    let liked = app.account.likedSongIDs.contains(item.id)
                                    do {
                                        try await app.account.setLiked(item.id, liked: !liked)
                                    } catch {
                                        app.alerts.show(error.localizedDescription)
                                    }
                                }
                            } label: {
                                Image(systemName: app.account.likedSongIDs.contains(item.id) ? "heart.fill" : "heart")
                                    .resizable()
                                    .frame(width: 10, height: 9)
                            }
                            .buttonStyle(PlayerControlButtonStyle(color: app.account.likedSongIDs.contains(item.id) ? .accentColor : .secondary))
                            .help(app.account.likedSongIDs.contains(item.id) ? "Unfavor" : "Favor")

                            Menu {
                                Button("查看评论") {
                                    CommentsWindowManager.shared.show(
                                        target: CommentsTarget(
                                            kind: .song,
                                            resourceID: item.id,
                                            name: item.title,
                                            subtitle: item.artist
                                        )
                                    )
                                }
                                if let source = item.sourcePlaylist {
                                    Divider()
                                    Button("定位到歌单") {
                                        app.router.showPlaylist(
                                            PlaylistDestination(id: source.id, name: source.name),
                                            songID: item.id
                                        )
                                    }
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 14, height: 12)
                            }
                            .menuIndicator(.hidden)
                            .menuStyle(.borderlessButton)
                            .buttonStyle(PlayerControlButtonStyle(color: .secondary))
                            .help("更多")
                        }
                    }
                    HStack(spacing: 6) {
                        Text(playback.currentItem?.artist ?? "Artists")
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .foregroundStyle(Color(nsColor: .placeholderTextColor))
                        Spacer(minLength: 4)
                        PlaybackElapsedTimeView(
                            playback: playback,
                            isSeeking: isSeeking,
                            seekTarget: seekTarget
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: PlayerOverlayMetrics.trackInfoHeight)

            PlaybackProgressSlider(
                playback: playback,
                isSeeking: $isSeeking,
                seekTarget: $seekTarget
            )
            .frame(height: PlayerOverlayMetrics.trackSliderHeight)
        }
        .padding(.top, PlayerOverlayMetrics.trackVisualPadding)
        .padding(.bottom, PlayerOverlayMetrics.trackLayoutPadding)
        .frame(height: PlayerOverlayMetrics.height)
    }

    @ViewBuilder
    private var artwork: some View {
        if let url = playback.currentItem?.artworkUrl {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                artworkPlaceholder
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            artworkPlaceholder
        }
    }

    private var artworkPlaceholder: some View {
        ZStack {
            Color.gray.opacity(0.2)
            Image(systemName: "music.note")
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(.secondary)
        }
        .frame(width: 32, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct PlaybackElapsedTimeView: View {
    let playback: PlaybackPresentationModel
    let isSeeking: Bool
    let seekTarget: Double

    var body: some View {
        if playback.shouldAnimateDisplayedPosition && !isSeeking {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                timeText(position: playback.displayedPosition)
            }
        } else {
            timeText(position: isSeeking ? seekTarget : playback.displayedPosition)
        }
    }

    private func timeText(position: Double) -> some View {
        Text("\(clock(position)) / \(clock(playback.duration))")
            .font(.system(size: 12))
            .lineLimit(1)
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
    }

    private func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

struct PlaybackProgressMotion {
    static let hardResetThreshold: Double = 1
    static let maximumCorrectionRate: Double = 0.25
    static let maximumCorrectionAcceleration: Double = 1.5
    static let correctionResponseTime: TimeInterval = 0.35

    private(set) var position = 0.0
    private var duration = 0.0
    private var isAdvancing = false
    private var lastTimestamp: TimeInterval?
    private var correctionRate = 0.0

    mutating func reset(
        position: Double,
        duration: Double,
        isAdvancing: Bool,
        at timestamp: TimeInterval
    ) {
        self.duration = normalizedDuration(duration)
        self.position = boundedPosition(position, duration: self.duration)
        self.isAdvancing = isAdvancing
        lastTimestamp = timestamp.isFinite ? timestamp : nil
        correctionRate = 0
    }

    @discardableResult
    mutating func advance(
        toward target: Double,
        duration: Double,
        isAdvancing: Bool,
        at timestamp: TimeInterval
    ) -> Double {
        let normalizedDuration = normalizedDuration(duration)
        let boundedTarget = boundedPosition(target, duration: normalizedDuration)
        let validTimestamp = timestamp.isFinite ? timestamp : (lastTimestamp ?? 0)

        guard
            let lastTimestamp,
            normalizedDuration == self.duration,
            isAdvancing,
            self.isAdvancing
        else {
            reset(
                position: boundedTarget,
                duration: normalizedDuration,
                isAdvancing: isAdvancing,
                at: validTimestamp
            )
            return position
        }

        let elapsed = max(0, validTimestamp - lastTimestamp)
        let predictedPosition = boundedPosition(position + elapsed, duration: normalizedDuration)
        let difference = boundedTarget - predictedPosition

        guard abs(difference) < Self.hardResetThreshold else {
            reset(
                position: boundedTarget,
                duration: normalizedDuration,
                isAdvancing: isAdvancing,
                at: validTimestamp
            )
            return position
        }

        let desiredCorrectionRate = min(
            max(difference / Self.correctionResponseTime, -Self.maximumCorrectionRate),
            Self.maximumCorrectionRate
        )
        let maximumRateChange = Self.maximumCorrectionAcceleration * elapsed
        let nextCorrectionRate = correctionRate + min(
            max(desiredCorrectionRate - correctionRate, -maximumRateChange),
            maximumRateChange
        )
        let correction = (correctionRate + nextCorrectionRate) * elapsed / 2
        position = boundedPosition(predictedPosition + correction, duration: normalizedDuration)
        correctionRate = nextCorrectionRate
        self.lastTimestamp = max(lastTimestamp, validTimestamp)
        return position
    }

    private func normalizedDuration(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 0
    }

    private func boundedPosition(_ value: Double, duration: Double) -> Double {
        let position = value.isFinite ? max(0, value) : 0
        guard duration > 0 else { return position }
        return min(position, duration)
    }
}

struct PlaybackProgressInteraction {
    private(set) var isTracking = false
    private(set) var previewPosition = 0.0

    mutating func begin(location: CGFloat, width: CGFloat, duration: Double) -> Double {
        isTracking = true
        previewPosition = PlaybackProgressInteraction.position(
            for: location,
            width: width,
            duration: duration
        )
        return previewPosition
    }

    mutating func update(location: CGFloat, width: CGFloat, duration: Double) -> Double? {
        guard isTracking else { return nil }
        previewPosition = PlaybackProgressInteraction.position(
            for: location,
            width: width,
            duration: duration
        )
        return previewPosition
    }

    mutating func end(location: CGFloat, width: CGFloat, duration: Double) -> Double? {
        guard isTracking else { return nil }
        let position = update(location: location, width: width, duration: duration)
        isTracking = false
        return position
    }

    mutating func cancel() -> Bool {
        guard isTracking else { return false }
        isTracking = false
        return true
    }

    static func position(for location: CGFloat, width: CGFloat, duration: Double) -> Double {
        guard width.isFinite, width > 0, duration.isFinite, duration > 0 else { return 0 }
        let progress = min(max(location / width, 0), 1)
        return Double(progress) * duration
    }
}

struct PlaybackProgressThumbVisibility {
    static let hideDelay: TimeInterval = 0.3

    private(set) var isVisible = false
    private var isPointerInside = false
    private var isTracking = false
    private var hideDeadline: TimeInterval?

    mutating func pointerEntered() {
        isPointerInside = true
        isVisible = true
        hideDeadline = nil
    }

    @discardableResult
    mutating func pointerExited(at timestamp: TimeInterval) -> TimeInterval? {
        isPointerInside = false
        return scheduleHide(at: timestamp)
    }

    @discardableResult
    mutating func setTracking(_ isTracking: Bool, at timestamp: TimeInterval) -> TimeInterval? {
        self.isTracking = isTracking
        if isTracking {
            isVisible = true
            hideDeadline = nil
            return nil
        }
        return scheduleHide(at: timestamp)
    }

    mutating func hideIfDue(at timestamp: TimeInterval) -> Bool {
        guard
            let hideDeadline,
            timestamp >= hideDeadline,
            !isPointerInside,
            !isTracking
        else { return false }

        isVisible = false
        self.hideDeadline = nil
        return true
    }

    mutating func disable() {
        isVisible = false
        hideDeadline = nil
    }

    private mutating func scheduleHide(at timestamp: TimeInterval) -> TimeInterval? {
        guard !isPointerInside, !isTracking, isVisible else { return nil }
        let validTimestamp = timestamp.isFinite ? timestamp : 0
        let deadline = validTimestamp + Self.hideDelay
        hideDeadline = deadline
        return deadline
    }
}

@MainActor
private struct PlaybackProgressSlider: NSViewRepresentable {
    let playback: PlaybackPresentationModel
    @Binding var isSeeking: Bool
    @Binding var seekTarget: Double

    private var shouldAnimate: Bool {
        !isSeeking && playback.shouldAnimateDisplayedPosition
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PlaybackProgressControl {
        let control = PlaybackProgressControl(frame: .zero)
        control.didMoveToWindow = { [weak coordinator = context.coordinator] control in
            coordinator?.attach(to: control)
        }
        context.coordinator.update(from: self, control: control)
        context.coordinator.attach(to: control)
        return control
    }

    func updateNSView(_ control: PlaybackProgressControl, context: Context) {
        context.coordinator.update(from: self, control: control)
        context.coordinator.attach(to: control)
    }

    static func dismantleNSView(_ control: PlaybackProgressControl, coordinator: Coordinator) {
        control.clearHandlers()
        coordinator.invalidate()
    }

    private func bounded(_ position: Double) -> Double {
        min(max(position.isFinite ? position : 0, 0), max(0, playback.duration))
    }

    @MainActor
    final class Coordinator: NSObject {
        private var displayLink: CADisplayLink?
        private weak var control: PlaybackProgressControl?
        private var parent: PlaybackProgressSlider?
        private var motion = PlaybackProgressMotion()
        private var itemID: UInt64?
        private var wasAnimating = false

        func update(from parent: PlaybackProgressSlider, control: PlaybackProgressControl) {
            let previousItemID = itemID
            let nextItemID = parent.playback.currentItem?.id
            self.parent = parent
            self.control = control
            itemID = nextItemID

            control.onInteractionBegan = { [weak self] position in
                self?.beginInteraction(at: position)
            }
            control.onPreview = { [weak self] position in
                self?.preview(position)
            }
            control.onCommit = { [weak self] position in
                self?.commit(position)
            }
            control.onCancel = { [weak self] in
                self?.cancelInteraction()
            }

            let duration = parent.playback.duration
            let isEnabled = parent.playback.hasCurrentItem && !parent.playback.isLoading && duration > 0
            control.configure(duration: duration, isEnabled: isEnabled)

            let isAnimating = shouldAnimate(parent)
            displayLink?.isPaused = !isAnimating
            let shouldReset = !isAnimating
                || parent.isSeeking
                || previousItemID != nextItemID
                || wasAnimating != isAnimating
            wasAnimating = isAnimating
            guard shouldReset else { return }

            let position = parent.isSeeking ? parent.seekTarget : parent.playback.displayedPosition
            motion.reset(
                position: parent.bounded(position),
                duration: duration,
                isAdvancing: isAnimating,
                at: CACurrentMediaTime()
            )
            control.render(position: parent.bounded(position))
        }

        func attach(to control: PlaybackProgressControl) {
            guard displayLink == nil, control.window != nil else { return }
            let displayLink = control.displayLink(
                target: self,
                selector: #selector(displayLinkDidRefresh(_:))
            )
            displayLink.preferredFrameRateRange = CAFrameRateRange(
                minimum: 30,
                maximum: 60,
                preferred: 60
            )
            displayLink.add(to: .main, forMode: .common)
            displayLink.isPaused = !(parent.map(shouldAnimate) ?? false)
            self.displayLink = displayLink
        }

        @objc private func displayLinkDidRefresh(_ displayLink: CADisplayLink) {
            guard
                let parent,
                let control,
                shouldAnimate(parent),
                !control.isTracking
            else { return }

            let position = motion.advance(
                toward: parent.bounded(parent.playback.displayedPosition),
                duration: parent.playback.duration,
                isAdvancing: true,
                at: displayLink.targetTimestamp
            )
            control.render(position: position)
        }

        private func beginInteraction(at position: Double) {
            guard let parent else { return }
            let target = parent.bounded(position)
            displayLink?.isPaused = true
            motion.reset(
                position: target,
                duration: parent.playback.duration,
                isAdvancing: false,
                at: CACurrentMediaTime()
            )
            parent.seekTarget = target
            parent.isSeeking = true
            self.parent = parent
        }

        private func preview(_ position: Double) {
            guard let parent else { return }
            parent.seekTarget = parent.bounded(position)
            self.parent = parent
        }

        private func commit(_ position: Double) {
            guard let parent else { return }
            let target = parent.bounded(position)
            parent.seekTarget = target
            parent.isSeeking = false
            self.parent = parent
            motion.reset(
                position: target,
                duration: parent.playback.duration,
                isAdvancing: false,
                at: CACurrentMediaTime()
            )
            parent.playback.seek(to: target)
        }

        private func cancelInteraction() {
            guard let parent, let control else { return }
            parent.isSeeking = false
            self.parent = parent

            let position = parent.bounded(parent.playback.displayedPosition)
            let isAnimating = shouldAnimate(parent)
            motion.reset(
                position: position,
                duration: parent.playback.duration,
                isAdvancing: isAnimating,
                at: CACurrentMediaTime()
            )
            control.render(position: position)
            displayLink?.isPaused = !isAnimating
        }

        private func shouldAnimate(_ parent: PlaybackProgressSlider) -> Bool {
            !parent.isSeeking && parent.playback.shouldAnimateDisplayedPosition
        }

        func invalidate() {
            displayLink?.invalidate()
            displayLink = nil
            control = nil
            parent = nil
        }
    }
}

@MainActor
private final class PlaybackProgressControl: NSControl {
    private static let trackHeight = PlayerOverlayMetrics.trackSliderLineHeight
    private static let thumbDiameter: CGFloat = 6
    private static let keyboardStep: Double = 5

    var didMoveToWindow: ((PlaybackProgressControl) -> Void)?
    var onInteractionBegan: ((Double) -> Void)?
    var onPreview: ((Double) -> Void)?
    var onCommit: ((Double) -> Void)?
    var onCancel: (() -> Void)?

    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private let thumbLayer = CALayer()
    private var duration = 0.0
    private var position = 0.0
    private var interaction = PlaybackProgressInteraction()
    private var thumbVisibility = PlaybackProgressThumbVisibility()
    private var thumbHideTask: Task<Void, Never>?
    private var trackingArea: NSTrackingArea?

    var isTracking: Bool { interaction.isTracking }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(fillLayer)
        layer?.addSublayer(thumbLayer)
        toolTip = String(localized: "Seek")
        updateColors()
        updateLayers()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        isEnabled
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.contentsScale = window?.backingScaleFactor ?? 1
        didMoveToWindow?(self)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 1
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
        updateLayers()
    }

    override func layout() {
        super.layout()
        updateLayers()
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        thumbVisibility.pointerEntered()
        updateThumbHideTask(deadline: nil)
        updateLayers(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateThumbHideTask(deadline: thumbVisibility.pointerExited(at: CACurrentMediaTime()))
        updateLayers(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, duration > 0 else {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        thumbVisibility.pointerEntered()
        updateThumbHideTask(deadline: thumbVisibility.setTracking(true, at: CACurrentMediaTime()))
        let position = interaction.begin(
            location: location(for: event),
            width: bounds.width,
            duration: duration
        )
        render(position: position)
        updateLayers(animated: true)
        onInteractionBegan?(position)
        onPreview?(position)
    }

    override func mouseDragged(with event: NSEvent) {
        updateThumbPointerLocation(for: event)
        guard let position = interaction.update(
            location: location(for: event),
            width: bounds.width,
            duration: duration
        ) else { return }
        render(position: position)
        onPreview?(position)
    }

    override func mouseUp(with event: NSEvent) {
        updateThumbPointerLocation(for: event)
        guard let position = interaction.end(
            location: location(for: event),
            width: bounds.width,
            duration: duration
        ) else {
            super.mouseUp(with: event)
            return
        }
        updateThumbHideTask(deadline: thumbVisibility.setTracking(false, at: CACurrentMediaTime()))
        render(position: position)
        updateLayers(animated: true)
        onPreview?(position)
        onCommit?(position)
    }

    override func cancelOperation(_ sender: Any?) {
        guard interaction.cancel() else {
            super.cancelOperation(sender)
            return
        }
        updateThumbHideTask(deadline: thumbVisibility.setTracking(false, at: CACurrentMediaTime()))
        updateLayers(animated: true)
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled, duration > 0 else {
            super.keyDown(with: event)
            return
        }

        let target: Double?
        switch event.keyCode {
        case 123:
            target = max(0, position - Self.keyboardStep)
        case 124:
            target = min(duration, position + Self.keyboardStep)
        case 115:
            target = 0
        case 119:
            target = duration
        default:
            target = nil
        }

        guard let target else {
            super.keyDown(with: event)
            return
        }
        commitKeyboardSeek(to: target)
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .slider
    }

    override func accessibilityLabel() -> String? {
        String(localized: "Seek")
    }

    override func accessibilityValue() -> Any? {
        NSNumber(value: position)
    }

    override func accessibilityMinValue() -> Any? {
        NSNumber(value: 0)
    }

    override func accessibilityMaxValue() -> Any? {
        NSNumber(value: duration)
    }

    override func accessibilityPerformIncrement() -> Bool {
        guard isEnabled, duration > 0 else { return false }
        commitKeyboardSeek(to: min(duration, position + Self.keyboardStep))
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard isEnabled, duration > 0 else { return false }
        commitKeyboardSeek(to: max(0, position - Self.keyboardStep))
        return true
    }

    func configure(duration: Double, isEnabled: Bool) {
        self.duration = duration.isFinite && duration > 0 ? duration : 0
        self.isEnabled = isEnabled
        if !isEnabled {
            thumbVisibility.disable()
            updateThumbHideTask(deadline: nil)
        }
        position = min(max(position, 0), self.duration)
        updateLayers()
    }

    func render(position: Double) {
        let boundedPosition = position.isFinite ? min(max(position, 0), duration) : 0
        self.position = boundedPosition
        updateLayers()
    }

    func clearHandlers() {
        thumbHideTask?.cancel()
        thumbHideTask = nil
        didMoveToWindow = nil
        onInteractionBegan = nil
        onPreview = nil
        onCommit = nil
        onCancel = nil
    }

    private func location(for event: NSEvent) -> CGFloat {
        convert(event.locationInWindow, from: nil).x
    }

    private func updateThumbPointerLocation(for event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if bounds.contains(location) {
            thumbVisibility.pointerEntered()
            updateThumbHideTask(deadline: nil)
        } else {
            updateThumbHideTask(deadline: thumbVisibility.pointerExited(at: CACurrentMediaTime()))
        }
    }

    private func updateThumbHideTask(deadline: TimeInterval?) {
        thumbHideTask?.cancel()
        thumbHideTask = nil
        guard let deadline else { return }

        let delay = max(0, deadline - CACurrentMediaTime())
        thumbHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            if self.thumbVisibility.hideIfDue(at: CACurrentMediaTime()) {
                self.updateLayers(animated: true)
            }
            self.thumbHideTask = nil
        }
    }

    private func commitKeyboardSeek(to position: Double) {
        render(position: position)
        onCommit?(self.position)
    }

    private func updateColors() {
        trackLayer.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.72).cgColor
        fillLayer.backgroundColor = NSColor.secondaryLabelColor.cgColor
        thumbLayer.backgroundColor = NSColor.secondaryLabelColor.cgColor
    }

    private func updateLayers(animated: Bool = false) {
        let trackHeight = Self.trackHeight
        let trackFrame = CGRect(
            x: 0,
            y: (bounds.height - trackHeight) / 2,
            width: max(0, bounds.width),
            height: trackHeight
        )
        let progress = duration > 0 ? min(max(position / duration, 0), 1) : 0
        let fillWidth = trackFrame.width * progress
        let thumbVisible = isEnabled && thumbVisibility.isVisible

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated {
            CATransaction.setAnimationDuration(0.12)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        }
        trackLayer.frame = trackFrame
        trackLayer.cornerRadius = trackHeight / 2
        fillLayer.frame = CGRect(x: trackFrame.minX, y: trackFrame.minY, width: fillWidth, height: trackHeight)
        fillLayer.cornerRadius = trackHeight / 2
        thumbLayer.bounds = CGRect(
            x: 0,
            y: 0,
            width: Self.thumbDiameter,
            height: Self.thumbDiameter
        )
        thumbLayer.position = CGPoint(x: trackFrame.minX + fillWidth, y: trackFrame.midY)
        thumbLayer.cornerRadius = Self.thumbDiameter / 2
        thumbLayer.opacity = thumbVisible ? 1 : 0
        CATransaction.commit()
    }
}

private struct PlayerControlButtonStyle: ButtonStyle {
    var color: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(color ?? (configuration.isPressed ? Color.secondary : Color.primary))
    }
}

private struct VolumePopoverView: View {
    @Environment(AppModel.self) private var app
    @Binding var isPresented: Bool

    var body: some View {
        Slider(
            value: Binding(
                get: { Double(app.playbackPresentation.volume) },
                set: { app.playbackPresentation.setVolume(Float($0)) }
            ),
            in: 0...1,
            label: { EmptyView() },
            minimumValueLabel: { Image(systemName: "speaker.fill") },
            maximumValueLabel: { Image(systemName: "speaker.wave.3.fill") }
        )
        .controlSize(.mini)
        .padding(12)
        .frame(width: 160)
    }
}

private struct QueuePopoverView: View {
    @Environment(AppModel.self) private var app
    @Binding var isPresented: Bool

    var body: some View {
        let playback = app.playbackPresentation
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack {
                    Text("Now Playing")
                        .font(.headline)
                    Spacer()
                    Button {
                        if let current = playback.queueEntries.first(where: \.isCurrent) {
                            proxy.scrollTo(current.id, anchor: .center)
                        }
                    } label: {
                        Image(systemName: "dot.circle")
                            .resizable()
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                    .help("Scroll to Current")
                    Button {
                        playback.clearQueue()
                        isPresented = false
                    } label: {
                        Image(systemName: "trash")
                            .resizable()
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .help("Clear All")
                    .disabled(playback.queueEntries.isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)

                if playback.queueEntries.isEmpty {
                    Text("No songs in playlist")
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 20)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(playback.queueEntries) { entry in
                                QueueRow(entry: entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }
                    .frame(maxHeight: 400)
                    .onAppear {
                        if let current = playback.queueEntries.first(where: \.isCurrent) {
                            proxy.scrollTo(current.id, anchor: .center)
                        }
                    }
                }
            }
            .frame(width: 400)
        }
    }
}

private struct QueueRow: View {
    @Environment(AppModel.self) private var app
    let entry: QueueDisplayEntry
    @State private var isHovering = false
    @State private var showButtons = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(entry.item.title)
                        .font(.body)
                        .lineLimit(1)
                        .foregroundStyle(entry.isCurrent ? Color.accentColor : Color.primary)
                    if let position = entry.explicitNextPosition {
                        Text("Next \(position)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text(entry.item.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if entry.isCurrent {
                Image(systemName: "speaker.3.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
            } else if showButtons {
                if !entry.isExplicitNext {
                    Button {
                        app.playbackPresentation.enqueueNext(entry.item)
                    } label: {
                        Image(systemName: "text.badge.plus")
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.borderless)
                    .help("Play Next")
                }
                Button {
                    app.playbackPresentation.remove(entryID: entry.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(entry.isCurrent ? Color.accentColor.opacity(0.1) : Color.gray.opacity(0.05))
        )
        .contentShape(Rectangle())
        .onTapGesture { app.playbackPresentation.play(entryID: entry.id) }
        .onHover { hovering in
            isHovering = hovering
            hoverTask?.cancel()
            if hovering {
                hoverTask = Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, isHovering else { return }
                    showButtons = true
                }
            } else {
                showButtons = false
            }
        }
        .onDisappear { hoverTask?.cancel() }
    }
}

private struct AudioOutputDeviceButton: View {
    var body: some View {
        AVRoutePickerViewWrapper()
            .frame(width: 16, height: 16)
            .help("Select Audio Output Device")
    }
}

private struct AVRoutePickerViewWrapper: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let routePicker = AVRoutePickerView()
        routePicker.isRoutePickerButtonBordered = false
        routePicker.setRoutePickerButtonColor(.labelColor, for: .normal)
        routePicker.setRoutePickerButtonColor(.labelColor, for: .normalHighlighted)
        return routePicker
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

struct LyricsInspectorView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let lyrics = app.playbackPresentation.lyrics
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading) {
                    if lyrics.lines.isEmpty, !lyrics.isLoading {
                        Text("还没有歌词")
                            .foregroundStyle(.secondary)
                            .padding(16)
                    }
                    ForEach(lyrics.lines.indices, id: \.self) { index in
                        let line = lyrics.lines[index]
                        let isCurrent = lyrics.currentIndex == index
                        VStack(alignment: .leading) {
                            if app.settings.showTimestamp {
                                Text(timestamp(line.time))
                                    .lineLimit(1)
                                    .font(.footnote)
                                    .foregroundStyle(.gray)
                            }
                            if app.settings.showRoma, let roma = line.romalrc, !roma.isEmpty {
                                Text(roma)
                                    .font(.body)
                                    .foregroundStyle(isCurrent ? .primary : Color(nsColor: .placeholderTextColor))
                            }
                            Text(line.lyric)
                                .font(.title3)
                                .foregroundStyle(isCurrent ? .primary : Color(nsColor: .placeholderTextColor))
                                .id(index)
                            if let translation = line.tlyric, !translation.isEmpty {
                                Text(translation)
                                    .font(.title3)
                                    .foregroundStyle(isCurrent ? .primary : Color(nsColor: .placeholderTextColor))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 12)
            }
            .task {
                await observeScrollRequests(proxy: proxy)
            }
        }
        .navigationTitle(app.playbackPresentation.currentItem?.title ?? "Playing")
    }

    private func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00.00" }
        let hundredths = max(0, Int((seconds * 100).rounded()))
        return String(format: "%02d:%02d.%02d", hundredths / 6_000, (hundredths % 6_000) / 100, hundredths % 100)
    }

    @MainActor
    private func observeScrollRequests(proxy: ScrollViewProxy) async {
        var lastRequest: LyricsScrollRequest?
        var pendingScroll: Task<Void, Never>?
        defer { pendingScroll?.cancel() }

        let requests = Observations { @MainActor in
            let lyrics = app.playbackPresentation.lyrics
            return LyricsScrollRequest(
                currentIndex: lyrics.currentIndex,
                resetToken: lyrics.scrollResetToken
            )
        }
        for await request in requests {
            guard !Task.isCancelled else { break }
            guard request != lastRequest else { continue }
            lastRequest = request
            pendingScroll?.cancel()
            pendingScroll = Task { @MainActor in
                await scroll(to: request.currentIndex, proxy: proxy)
            }
        }
    }

    @MainActor
    private func scroll(to currentIndex: Int?, proxy: ScrollViewProxy) async {
        do {
            try await Task.sleep(for: .milliseconds(20))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            if let currentIndex {
                proxy.scrollTo(currentIndex, anchor: .center)
            } else {
                proxy.scrollTo(0, anchor: .top)
            }
        }
    }
}

private struct LyricsScrollRequest: Equatable, Sendable {
    let currentIndex: Int?
    let resetToken: UUID
}
