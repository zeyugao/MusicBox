//
//  ContentView.swift
//  MusicBox
//
//  Created by Elsa on 2024/4/16.
//

import Combine
import Foundation
import SwiftUI

struct Sidebar: View {
    @State private var selection: String = "Home"
    @EnvironmentObject var playController: PlayController

    var body: some View {
        List(selection: $selection) {
            Section(header: Text("Apple Music")) {
                NavigationLink(
                    destination: HomeContentView()
                        .environmentObject(playController)
                        .navigationTitle("Home")
                ) {
                    Label("Home", systemImage: "house.fill")
                }.tag("Home")

                NavigationLink(destination: AccountView().navigationTitle("Account")) {
                    Label("Account", systemImage: "dot.radiowaves.left.and.right")
                }.tag("Account")
            }

            Section(header: Text("Library")) {
                NavigationLink(destination: Text("Recently Added View")) {
                    Label("Recently Added", systemImage: "clock.fill")
                }.tag("Recently Added")

                NavigationLink(destination: Text("Artists View")) {
                    Label("Artists", systemImage: "music.mic")
                }.tag("Artists")

                NavigationLink(destination: Text("Albums View")) {
                    Label("Albums", systemImage: "rectangle.stack.fill")
                }.tag("Albums")

                NavigationLink(destination: Text("Songs View")) {
                    Label("Songs", systemImage: "music.note.list")
                }.tag("Songs")
            }

            Section(header: Text("Store")) {
                NavigationLink(destination: Text("iTunes Store View")) {
                    Label("iTunes Store", systemImage: "cart.fill")
                }.tag("iTunes Store")
            }

            Section(header: Text("Devices")) {
                NavigationLink(destination: Text("Elsa's iPhone View")) {
                    Label("Elsa's iPhone", systemImage: "iphone")
                }.tag("Elsa's iPhone")
            }
        }
        .listStyle(SidebarListStyle())
        .frame(minWidth: 200, idealWidth: 250)
    }
}

struct ContentView: View {
    @StateObject var playController = PlayController()

    var body: some View {
        ZStack(
            alignment: Alignment(horizontal: .trailing, vertical: .bottom),
            content: {
                NavigationSplitView {
                    Sidebar()
                        .environmentObject(playController)
                } detail: {
                    Text("Hello")
                }
                .navigationTitle("Home")
                .toolbar {
                }
                .searchable(text: .constant(""), prompt: "Search")
                .padding(.bottom, 80)

                PlayerControlView()
                    .environmentObject(playController)
                    .frame(height: 80)
                    .overlay(
                        Rectangle()
                            .frame(height: 1)
                            .foregroundStyle(
                                Color(red: 0.925, green: 0.925, blue: 0.925)
                            ),
                        alignment: .top
                    )
                    .background(Color.white)
            })
    }
}

#Preview {
    ContentView()
}
