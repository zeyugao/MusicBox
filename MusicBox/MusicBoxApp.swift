//
//  MusicBoxApp.swift
//  MusicBox
//
//  Created by Elsa on 2024/4/16.
//

import SwiftUI

@main
struct MusicBoxApp: App {
    class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
        var mainWindow: NSWindow?
        func applicationDidFinishLaunching(_ notification: Notification) {
            mainWindow = NSApp.windows[0]
            mainWindow?.delegate = self
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            mainWindow?.orderOut(nil)

            return false
        }

        func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
            -> Bool
        {
            if !flag {
                mainWindow?.makeKeyAndOrderFront(nil)
            }
            return true
        }
    }
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            SidebarCommands()
        }
    }
}
