import Foundation
import IOKit.pwr_mgt
import Observation

enum DoubleClickPlayAction: Int, CaseIterable, Identifiable {
    case replaceSource = 0
    case appendSource = 1

    var id: Int { rawValue }
}

@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults
    var preventSleepWhenPlaying: Bool {
        didSet {
            defaults.set(preventSleepWhenPlaying, forKey: "preventSleepWhenPlaying")
            updateSleepAssertion()
        }
    }
    var showTimestamp: Bool {
        didSet { defaults.set(showTimestamp, forKey: "showTimestamp") }
    }
    var showRoma: Bool {
        didSet { defaults.set(showRoma, forKey: "showRoma") }
    }
    var doubleClickPlayAction: DoubleClickPlayAction {
        didSet { defaults.set(doubleClickPlayAction.rawValue, forKey: "doubleClickPlayAction") }
    }

    private var isPlaying = false
    private var sleepAssertionID = IOPMAssertionID(0)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preventSleepWhenPlaying = defaults.bool(forKey: "preventSleepWhenPlaying")
        showTimestamp = defaults.bool(forKey: "showTimestamp")
        showRoma = defaults.bool(forKey: "showRoma")
        let rawValue = defaults.object(forKey: "doubleClickPlayAction") as? Int
        doubleClickPlayAction = DoubleClickPlayAction(rawValue: rawValue ?? DoubleClickPlayAction.appendSource.rawValue) ?? .appendSource
    }

    func applyPlaybackState(isPlaying: Bool) {
        self.isPlaying = isPlaying
        updateSleepAssertion()
    }

    private func updateSleepAssertion() {
        if preventSleepWhenPlaying && isPlaying {
            enableSleepAssertion()
        } else {
            disableSleepAssertion()
        }
    }

    private func enableSleepAssertion() {
        guard sleepAssertionID == IOPMAssertionID(0) else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "MusicBox playback" as CFString,
            &sleepAssertionID
        )
        if result != kIOReturnSuccess {
            sleepAssertionID = IOPMAssertionID(0)
        }
    }

    private func disableSleepAssertion() {
        guard sleepAssertionID != IOPMAssertionID(0) else { return }
        IOPMAssertionRelease(sleepAssertionID)
        sleepAssertionID = IOPMAssertionID(0)
    }

}
