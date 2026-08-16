import AppKit
import Combine
import Sparkle
import SwiftUI

final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var model: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        _model = ObservedObject(wrappedValue: CheckForUpdatesViewModel(updater: updater))
    }

    var body: some View {
        Button(String(localized: "menu.check_for_updates"), action: updater.checkForUpdates)
            .disabled(!model.canCheckForUpdates)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var mainWindow: NSWindow?
    var togglePlayback: (() -> Void)?
    private var keyDownMonitor: Any?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 49,
                event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            else { return event }
            if let responder = NSApplication.shared.keyWindow?.firstResponder,
                responder is NSTextView || responder is NSTextField
                    || responder.className.contains("TextField") || responder.className.contains("SearchField")
            {
                return event
            }
            self?.togglePlayback?()
            return nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
        }
        keyDownMonitor = nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag, let window = Self.mainWindow, !window.isVisible else { return true }
        window.makeKeyAndOrderFront(nil)
        return false
    }
}

final class WindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

@main
@MainActor
struct MusicBoxApp: App {
    private let updaterController: SPUStandardUpdaterController
    @State private var appModel: AppModel
    @State private var windowDelegate = WindowDelegate()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let windowWidth: CGFloat = 980
    private let windowHeight: CGFloat = 600

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        _appModel = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(appModel)
                .onAppear {
                    appDelegate.togglePlayback = { appModel.playback.toggle() }
                    configureMainWindow()
                }
                .frame(minWidth: windowWidth, minHeight: windowHeight)
        }
        .handlesExternalEvents(matching: ["main"])
        .defaultSize(width: windowWidth + 60, height: windowHeight)
        .commands {
            SidebarCommands()
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .windowArrangement) {
                Button(String(localized: "menu.show_musicbox")) {
                    guard let window = AppDelegate.mainWindow else { return }
                    window.makeKeyAndOrderFront(nil)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut("m", modifiers: [.command])
            }
        }
    }

    private func configureMainWindow() {
        DispatchQueue.main.async {
            guard let window = NSApplication.shared.windows.last else { return }
            AppDelegate.mainWindow = window
            window.delegate = windowDelegate
            window.setContentSize(NSSize(width: windowWidth + 60, height: windowHeight))
            NSApplication.shared.setActivationPolicy(.regular)
        }
    }
}
