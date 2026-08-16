import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app

    private var routeBinding: Binding<AppRoute> {
        Binding(
            get: {
                app.account.profile == nil ? .account : app.router.selectedRoute
            },
            set: { route in
                if app.account.profile != nil || route == .account {
                    app.router.selectedRoute = route
                }
            }
        )
    }

    var body: some View {
        @Bindable var router = app.router
        NavigationSplitView {
            List(selection: routeBinding) {
                Section(String(localized: "sidebar.general")) {
                    if app.account.profile != nil {
                        Label(String(localized: "sidebar.explore"), systemImage: "music.house")
                            .tag(AppRoute.explore)
                    }
                    Label(String(localized: "sidebar.settings"), systemImage: "gearshape.fill")
                        .tag(AppRoute.account)
                    if app.account.profile != nil {
                        Label(String(localized: "sidebar.cloud_files"), systemImage: "icloud")
                            .tag(AppRoute.cloudFiles)
                    }
                }

                if app.account.profile != nil {
                    Section(String(localized: "sidebar.created_playlists")) {
                        ForEach(app.account.playlists.filter { !$0.subscribed }) { playlist in
                            PlaylistSidebarRow(playlist: playlist)
                                .tag(AppRoute.playlist(PlaylistDestination(id: playlist.id, name: playlist.name)))
                        }
                    }
                    Section(String(localized: "sidebar.favored_playlists")) {
                        ForEach(app.account.playlists.filter(\.subscribed)) { playlist in
                            PlaylistSidebarRow(playlist: playlist)
                                .tag(AppRoute.playlist(PlaylistDestination(id: playlist.id, name: playlist.name)))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 200, idealWidth: 250)
        } detail: {
            ZStack(alignment: .bottom) {
                routeContent
                    .padding(.bottom, PlayerOverlayMetrics.contentClearance)

                PlayerCapsuleView()
                    .padding(.horizontal, PlayerOverlayMetrics.horizontalInset)
                    .padding(.bottom, PlayerOverlayMetrics.bottomInset)
            }
        }
        .inspector(isPresented: $router.isLyricsPresented) {
            LyricsInspectorView()
                .inspectorColumnWidth(min: 300, ideal: 380, max: 520)
        }
        .task {
            await app.start()
        }
        .alert(
            app.alerts.current?.title ?? String(localized: "alert.title"),
            isPresented: Binding(
                get: { app.alerts.current != nil },
                set: { presented in if !presented { app.alerts.dismiss() } }
            ),
            presenting: app.alerts.current
        ) { alert in
            if let actionTitle = alert.actionTitle, let action = alert.action {
                Button(actionTitle) { action(); app.alerts.dismiss() }
            }
            Button(String(localized: "action.ok"), role: .cancel) { app.alerts.dismiss() }
        } message: { alert in
            Text(alert.message)
        }
        .alert(
            String(localized: "handoff.title"),
            isPresented: Binding(
                get: { app.reporting.handoffOffer != nil },
                set: { presented in if !presented { app.reporting.dismissHandoffOffer() } }
            )
        ) {
            Button(String(localized: "handoff.continue")) {
                Task { await app.acceptHandoff() }
            }
            Button(String(localized: "action.cancel"), role: .cancel) {
                app.reporting.dismissHandoffOffer()
            }
        } message: {
            Text(app.reporting.handoffOffer?.title ?? String(localized: "handoff.message"))
        }
    }

    @ViewBuilder
    private var routeContent: some View {
        let route = app.account.profile == nil ? AppRoute.account : app.router.selectedRoute
        switch route {
        case .account:
            AccountFeatureView()
                .navigationTitle(String(localized: "sidebar.settings"))
        case .explore:
            ExploreFeatureView(repository: app.repository)
                .navigationTitle(String(localized: "sidebar.explore"))
        case .cloudFiles:
            CloudFilesFeatureView(repository: app.repository)
                .navigationTitle(String(localized: "sidebar.cloud_files"))
        case .playlist(let destination):
            PlaylistFeatureView(destination: destination, repository: app.repository)
                .navigationTitle(destination.name)
        }
    }
}

private struct PlaylistSidebarRow: View {
    let playlist: CloudMusicApi.PlayListItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: playlist.privacy == 0 ? "music.note.list" : "lock.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(playlist.name)
                    .lineLimit(1)
                Text((playlist.trackCount ?? 0) + (playlist.cloudTrackCount ?? 0), format: .number)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
