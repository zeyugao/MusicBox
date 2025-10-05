//
//  MusicBoxApp.swift
//  MusicBox
//
//  Created by Elsa on 2024/4/16.
//

import AppKit
import Sparkle
import SwiftUI

extension Notification.Name {
    static let spaceKeyPressed = Notification.Name("spaceKeyPressed")
}

// This view model class publishes when new updates can be checked by the user
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

// This is the view for the Check for Updates menu item
// Note this intermediate view is necessary for the disabled state on the menu item to work properly before Monterey.
// See https://stackoverflow.com/questions/68553092/menu-not-updating-swiftui-bug for more info
struct CheckForUpdatesView: View {
    @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater

        // Create our view model for our CheckForUpdatesView
        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
    }
}

// Application delegate to handle app lifecycle
class AppDelegate: NSObject, NSApplicationDelegate {
    static var mainWindow: NSWindow?
    private var keyDownMonitor: Any?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Prevent the app from terminating when the last window is closed
        return false
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupGlobalKeyMonitor()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = keyDownMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
    
    private func setupGlobalKeyMonitor() {
        // Use local monitor for events within the app
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Only handle space key (keyCode 49) when no modifiers are pressed
            if event.keyCode == 49 && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                // Check if there's a text field or search field in focus
                if let window = NSApplication.shared.keyWindow,
                   let firstResponder = window.firstResponder {
                    // Don't handle space if a text input is active
                    if firstResponder is NSTextView || 
                       firstResponder is NSTextField ||
                       firstResponder.className.contains("TextField") ||
                       firstResponder.className.contains("SearchField") {
                        return event // Let the text field handle the space
                    }
                }
                
                // Post notification for space key press
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .spaceKeyPressed, object: nil)
                }
                return nil // Consume the event to prevent default handling
            }
            return event
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
        -> Bool
    {
        // Show the main window when user clicks on the dock icon
        if !flag {
            // Show the hidden main window if it exists
            if let mainWindow = AppDelegate.mainWindow, !mainWindow.isVisible {
                mainWindow.makeKeyAndOrderFront(nil)
                return false  // Prevent creating a new window
            }
        }
        return true
    }
}

// Window delegate to handle window closing behavior
class WindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Hide the window instead of closing it
        sender.orderOut(nil)
        return false
    }
}

@main
struct MusicBoxApp: App {
    private let updaterController: SPUStandardUpdaterController
    @State private var windowDelegate = WindowDelegate()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    let windowWidth: CGFloat = 980
    let windowHeight: CGFloat = 600

    init() {
        // If you want to start the updater manually, pass false to startingUpdater and call .startUpdater() later
        // This is where you can also pass an updater delegate if you need one
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .onAppear {
                    // Set up window delegate when the view appears
                    DispatchQueue.main.async {
                        if let window = NSApplication.shared.windows.last {
                            AppDelegate.mainWindow = window
                            window.delegate = windowDelegate
                            // Set the window size manually since defaultSize might not work with our setup
                            window.setContentSize(NSSize(width: windowWidth + 20, height: windowHeight))
                            // Ensure the app doesn't terminate when the last window is closed
                            NSApplication.shared.setActivationPolicy(.regular)
                        }
                    }
                }
                .frame(minWidth: windowWidth, minHeight: windowHeight)
        }
        .handlesExternalEvents(matching: Set(arrayLiteral: "main"))
        .defaultSize(width: windowWidth + 20, height: windowHeight)
        .commands {
            SidebarCommands()
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            CommandGroup(replacing: .newItem) {
                // Empty command group effectively removes the New command
            }
            CommandGroup(after: .windowArrangement) {
                Button("Show MusicBox") {
                    // Show the main window if it's hidden
                    if let mainWindow = AppDelegate.mainWindow {
                        mainWindow.makeKeyAndOrderFront(nil)
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    }
                }
                .keyboardShortcut("m", modifiers: [.command])
            }
        }
    }
}
