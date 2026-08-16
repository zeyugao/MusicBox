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
                        SidebarLabel(String(localized: "sidebar.explore"), image: "music.house")
                            .tag(AppRoute.explore)
                    }
                    SidebarLabel(String(localized: "sidebar.settings"), image: "gearshape.fill")
                        .tag(AppRoute.account)
                    if app.account.profile != nil {
                        SidebarLabel("My Cloud Files", image: "icloud")
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

                PlayerCapsuleView()
                    .padding(.horizontal, PlayerOverlayMetrics.horizontalInset)
                    .padding(.bottom, PlayerOverlayMetrics.bottomInset)
            }
        }
        .inspector(isPresented: $router.isLyricsPresented) {
            LyricsInspectorView()
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
            AccountFeatureScreen()
                .navigationTitle("Settings")
        case .explore:
            ExploreFeatureScreen(repository: app.repository)
                .navigationTitle("Explore")
        case .cloudFiles:
            CloudFilesFeatureScreen(repository: app.repository)
                .navigationTitle("My Cloud Files")
        case .playlist(let destination):
            PlaylistFeatureScreen(destination: destination, repository: app.repository)
                .id(destination.id)
                .navigationTitle(destination.name)
        }
    }
}

private struct SidebarLabel: View {
    let text: String
    let image: String

    init(_ text: String, image: String) {
        self.text = text
        self.image = image
    }

    var body: some View {
        HStack {
            Image(systemName: image)
                .foregroundStyle(Color.accentColor)
                .frame(width: 16)
            Text(text)
        }
    }
}

private struct PlaylistSidebarRow: View {
    let playlist: CloudMusicApi.PlayListItem

    var body: some View {
        HStack {
            AsyncImage(url: URL(string: playlist.coverImgUrl.https)) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(Color.gray.opacity(0.3))
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if playlist.privacy != 0 {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                            .font(.body)
                    }
                    Text(playlist.name)
                        .font(.body)
                        .lineLimit(1)
                }
                Text("\((playlist.trackCount ?? 0) + (playlist.cloudTrackCount ?? 0))首 • \(playlist.creator.nickname)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button {
                CommentsWindowManager.shared.show(
                    target: CommentsTarget(
                        kind: .playlist,
                        resourceID: playlist.id,
                        name: playlist.name,
                        subtitle: nil
                    )
                )
            } label: {
                Label("查看评论", systemImage: "text.bubble")
            }
        }
    }
}
