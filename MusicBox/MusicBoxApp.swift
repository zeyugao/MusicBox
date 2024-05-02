//
//  MusicBoxApp.swift
//  MusicBox
//
//  Created by Elsa on 2024/4/16.
//

import SwiftUI

@main
struct MusicBoxApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            SidebarCommands()
        }
    }
}
