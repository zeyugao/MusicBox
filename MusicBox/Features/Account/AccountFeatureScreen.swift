import AppKit
import Observation
import SwiftUI
import WebKit

struct AccountFeatureScreen: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.account.profile == nil {
            LoginLandingScreen(repository: app.repository)
        } else {
            SettingsScreen()
        }
    }
}

private struct LoginLandingScreen: View {
    @State private var isLoginSheetPresented = false
    let repository: any MusicRepository

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "music.note")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)
            Text(String(localized: "login.welcome"))
                .font(.title)
                .fontWeight(.bold)
            Text(String(localized: "login.message"))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                isLoginSheetPresented = true
            } label: {
                HStack {
                    Image(systemName: "person.circle")
                    Text(String(localized: "login.submit"))
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $isLoginSheetPresented) {
            LoginSheetScreen(repository: repository, isPresented: $isLoginSheetPresented)
        }
    }
}

private struct LoginSheetScreen: View {
    @Environment(AppModel.self) private var app
    @Binding var isPresented: Bool
    private let repository: any MusicRepository

    init(repository: any MusicRepository, isPresented: Binding<Bool>) {
        self.repository = repository
        _isPresented = isPresented
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "login.title"))
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(String(localized: "login.close"))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            WebLoginPane(repository: repository, onLoginSuccess: completeLogin)
        }
        .frame(width: 1_100, height: 800)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func completeLogin() async {
        await app.refreshAccount()
        isPresented = false
    }
}

@MainActor
@Observable
final class WebLoginFeatureModel {
    private let repository: any AccountRepository

    private(set) var isLoading = true
    private(set) var isLoggedIn = false
    private(set) var errorMessage: String?
    private(set) var statusText = "Initializing..."

    init(repository: any AccountRepository) {
        self.repository = repository
    }

    func beganLoading() {
        isLoading = true
        errorMessage = nil
        statusText = "Loading NetEase Music login page..."
    }

    func finishedLoading(url: URL?) {
        isLoading = false
        statusText = "Loaded: \(url?.absoluteString ?? "unknown")"
    }

    func failed(_ error: Error) {
        isLoading = false
        errorMessage = error.localizedDescription
        statusText = "Error: \(error.localizedDescription)"
    }

    func prepareForRetry() {
        isLoading = true
        errorMessage = nil
        statusText = "Reloading login page..."
    }

    func acceptLoginCookies(_ cookies: [HTTPCookie]) -> Bool {
        guard !isLoggedIn,
              cookies.contains(where: { ($0.name == "MUSIC_U" || $0.name == "MUSIC_A") && !$0.value.isEmpty })
        else { return false }
        repository.setCookie(cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "))
        isLoggedIn = true
        isLoading = false
        statusText = "Login successful"
        return true
    }
}

private struct WebLoginPane: View {
    @State private var model: WebLoginFeatureModel
    @State private var refreshToken = UUID()
    let onLoginSuccess: () async -> Void

    init(repository: any MusicRepository, onLoginSuccess: @escaping () async -> Void) {
        _model = State(initialValue: WebLoginFeatureModel(repository: repository))
        self.onLoginSuccess = onLoginSuccess
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    model.prepareForRetry()
                    refreshToken = UUID()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(String(localized: "login.refresh"))
            }
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 4)

            if let error = model.errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text("Loading Error")
                        .font(.title2.weight(.semibold))
                    Text(error)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        model.prepareForRetry()
                        refreshToken = UUID()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ZStack {
                    if model.isLoading {
                        VStack(spacing: 16) {
                            ProgressView().controlSize(.large)
                            Text(String(localized: "login.web.loading"))
                                .foregroundStyle(.secondary)
                        }
                    }
                    NetEaseLoginWebView(
                        model: model,
                        refreshToken: refreshToken,
                        onLoginSuccess: {
                            Task { await onLoginSuccess() }
                        }
                    )
                    .opacity(model.isLoading ? 0 : 1)
                }
            }
        }
    }
}

private struct NetEaseLoginWebView: NSViewRepresentable {
    let model: WebLoginFeatureModel
    let refreshToken: UUID
    let onLoginSuccess: @MainActor () -> Void

    private static let loginURL = URL(string: "https://music.163.com/login")!

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.lastRefreshToken = refreshToken
        model.beganLoading()
        webView.load(URLRequest(url: Self.loginURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastRefreshToken != refreshToken else { return }
        context.coordinator.lastRefreshToken = refreshToken
        webView.load(URLRequest(url: Self.loginURL))
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator _: Coordinator) {
        webView.navigationDelegate = nil
        webView.stopLoading()
        let dataStore = webView.configuration.websiteDataStore
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            dataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) {}
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: NetEaseLoginWebView
        var lastRefreshToken: UUID?

        init(parent: NetEaseLoginWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
            parent.model.beganLoading()
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            parent.model.finishedLoading(url: webView.url)
            inspectCookies(from: webView)
        }

        func webView(
            _: WKWebView,
            didFailProvisionalNavigation _: WKNavigation!,
            withError error: Error
        ) {
            parent.model.failed(error)
        }

        func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError error: Error) {
            parent.model.failed(error)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            inspectCookies(from: webView)
            decisionHandler(.allow)
        }

        private func inspectCookies(from webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.parent.model.acceptLoginCookies(cookies) {
                        self.parent.onLoginSuccess()
                    }
                }
            }
        }
    }
}

private struct SettingsScreen: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            HStack {
                Spacer()
                VStack(spacing: 24) {
                    ProfileSettingsSection()
                    Divider()
                    GeneralSettingsSection()
                    Divider()
                    PlaylistSettingsSection()
                    Divider()
                    StorageSettingsSection()
                    Divider()
                    RelaySettingsSection()
                    Divider()
                    AccountActionsSettingsSection()
                    Divider()
                    AboutSettingsSection()
                }
                .frame(maxWidth: 500)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                Spacer()
            }
        }
        .contentMargins(.bottom, PlayerOverlayMetrics.contentClearance, for: .scrollContent)
        .frame(maxWidth: .infinity)
    }
}

private struct ProfileSettingsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        SettingsSection(title: "Profile", icon: "person.circle.fill") {
            HStack(spacing: 16) {
                AsyncImage(url: URL(string: app.account.profile?.avatarUrl.https ?? "")) { image in
                    image.resizable().interpolation(.high)
                } placeholder: {
                    Circle()
                        .fill(Color.gray.opacity(0.3))
                        .overlay(Image(systemName: "person.fill").foregroundStyle(.white).font(.title))
                }
                .scaledToFit()
                .clipShape(Circle())
                .frame(width: 80, height: 80)
                .shadow(radius: 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text(app.account.profile?.nickname ?? "Unknown")
                        .font(.title3.weight(.medium))
                    Text("User ID: \(app.account.profile?.userId ?? 0)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(app.account.playlists.count) playlists")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }
}

private struct GeneralSettingsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        SettingsSection(title: "General Settings", icon: "gearshape.fill") {
            VStack(spacing: 12) {
                SettingsRow(
                    icon: "moon.fill",
                    title: "Prevent Sleep When Playing",
                    description: "Keeps your Mac awake while music is playing"
                ) {
                    Toggle("", isOn: $settings.preventSleepWhenPlaying)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                SettingsRow(
                    icon: "clock",
                    title: "Show Lyric Timestamps",
                    description: "Display timestamps for each lyric line"
                ) {
                    Toggle("", isOn: $settings.showTimestamp)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                SettingsRow(
                    icon: "quote.bubble",
                    title: "Show Romanized Lyrics",
                    description: "Display romanized lyrics when available"
                ) {
                    Toggle("", isOn: $settings.showRoma)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
        }
    }
}

private struct PlaylistSettingsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        SettingsSection(title: "播放列表", icon: "music.note.list") {
            Picker(selection: $settings.doubleClickPlayAction, label: EmptyView()) {
                Text("双击播放单曲时，用当前单曲所在的歌曲列表替换播放列表")
                    .fixedSize(horizontal: false, vertical: true)
                    .tag(DoubleClickPlayAction.replaceSource)
                Text("双击播放单曲时，仅把当前单曲添加到播放列表")
                    .fixedSize(horizontal: false, vertical: true)
                    .tag(DoubleClickPlayAction.appendSource)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }
}

private struct StorageSettingsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        SettingsSection(title: "Storage & Cache", icon: "internaldrive.fill") {
            SettingsRow(
                icon: "trash.fill",
                title: "Clear Cache",
                description: "Remove cached music files to free up space"
            ) {
                Button("Clean") {
                    do {
                        try MusicLibraryCache.clear()
                        app.alerts.show("Cache cleaned successfully", title: "Success")
                    } catch {
                        app.alerts.show("Clean failed: \(error.localizedDescription)", title: "Error")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
    }
}

private struct RelaySettingsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        SettingsSection(title: "跨设备接力", icon: "rectangle.2.swap") {
            SettingsRow(icon: "arrow.triangle.2.circlepath", title: "跨设备接力", description: "") {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { app.reporting.relayEnabled },
                        set: { enabled in Task { await app.reporting.updateRelayEnabled(enabled) } }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!app.reporting.relayAvailable || app.reporting.isUpdatingRelaySetting)
            }
        }
    }
}

private struct AccountActionsSettingsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        SettingsSection(title: "Account", icon: "person.badge.key.fill") {
            SettingsRow(
                icon: "arrow.right.square.fill",
                title: "Sign Out",
                description: "Sign out of your NetEase Cloud Music account"
            ) {
                Button("Sign Out") {
                    Task { await app.signOut() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
    }
}

private struct AboutSettingsSection: View {
    private var version: String {
        let bundle = Bundle.main
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(shortVersion) (\(build))"
    }

    var body: some View {
        SettingsSection(title: "About MusicBox", icon: "info.circle.fill") {
            SettingsRow(icon: "app.badge", title: "Version", description: version) {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(version, forType: .string)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.blue)
            }
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(Color.accentColor)
                    .font(.title2)
                Text(title)
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            VStack(spacing: 12) {
                content
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct SettingsRow<Control: View>: View {
    let icon: String
    let title: String
    let description: String
    let control: Control

    init(
        icon: String,
        title: String,
        description: String,
        @ViewBuilder control: () -> Control
    ) {
        self.icon = icon
        self.title = title
        self.description = description
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .font(.title3)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                if !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            control
        }
        .padding(.vertical, 4)
    }
}
