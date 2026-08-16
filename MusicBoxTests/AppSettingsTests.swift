import XCTest

@testable import MusicBox

final class AppSettingsTests: XCTestCase {
    @MainActor
    func testSettingsPersistToTheInjectedDefaultsSuite() throws {
        let suiteName = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.showTimestamp = true
        settings.showRoma = true
        settings.doubleClickPlayAction = .replaceSource

        XCTAssertTrue(defaults.bool(forKey: "showTimestamp"))
        XCTAssertTrue(defaults.bool(forKey: "showRoma"))
        XCTAssertEqual(defaults.integer(forKey: "doubleClickPlayAction"), DoubleClickPlayAction.replaceSource.rawValue)
    }
}
