//
//  Home.swift
//  MusicBox
//
//  Created by Elsa on 2024/4/19.
//

import AppKit
import AVFoundation
import Combine
import CoreImage.CIFilterBuiltins
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@MainActor
func initUserData(userInfo: UserInfo) async {
    if let profile = loadDecodableState(
        forKey: "profile", type: CloudMusicApi.Profile.self)
    {
        userInfo.profile = profile
    } else {
        userInfo.profile = nil
    }

    if let playlists = loadDecodableState(
        forKey: "playlists", type: [CloudMusicApi.PlayListItem].self)
    {
        userInfo.playlists = playlists
    } else {
        userInfo.playlists = []
    }

    if let likelist = loadDecodableState(
        forKey: "likelist", type: Set<UInt64>.self)
    {
        userInfo.likelist = likelist
    } else {
        userInfo.likelist = []
    }

    if let profile = await CloudMusicApi().login_status() {
        userInfo.profile = profile
        saveEncodableState(forKey: "profile", data: profile)

        if let playlists = try? await CloudMusicApi().user_playlist(uid: profile.userId) {
            userInfo.playlists = playlists
            saveEncodableState(forKey: "playlists", data: playlists)
        }

        if let likelist = await CloudMusicApi().likelist(userId: profile.userId) {
            userInfo.likelist = Set(likelist)
            saveEncodableState(forKey: "likelist", data: userInfo.likelist)
        }
    }
}


class WebViewLoginViewModel: ObservableObject {
    @Published var isLoggedIn = false
    @Published var isLoading = true
    @Published var hasError = false
    @Published var errorMessage = ""
    @Published var debugInfo = "Initializing..."
    
    func checkLogin(from cookies: [HTTPCookie]) -> Bool {
        for cookie in cookies {
            if cookie.name == "MUSIC_U" && !cookie.value.isEmpty {
                return true
            }
        }
        return false
    }
    
    func getCookieString(from cookies: [HTTPCookie]) -> String {
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
    
    func setError(_ message: String) {
        DispatchQueue.main.async {
            self.hasError = true
            self.errorMessage = message
            self.isLoading = false
            self.debugInfo = "Error: \(message)"
        }
    }
    
    func updateDebugInfo(_ info: String) {
        DispatchQueue.main.async {
            self.debugInfo = info
        }
    }
}

struct WebViewLogin: NSViewRepresentable {
    @ObservedObject var viewModel: WebViewLoginViewModel
    let onLoginSuccess: () -> Void
    @Binding var refreshTrigger: Bool

    static let loginUrl = URL(string: "https://music.163.com/login")!

    func makeNSView(context: Context) -> WKWebView {
        viewModel.updateDebugInfo("Creating WebView...")
        
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        
        // 直接加载网易云音乐登录页面
        let request = URLRequest(url: WebViewLogin.loginUrl)
        
        viewModel.updateDebugInfo("Loading: \(WebViewLogin.loginUrl.absoluteString)")
        webView.load(request)
        
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Handle refresh action
        if refreshTrigger {
            DispatchQueue.main.async {
                self.refreshTrigger = false
            }
            let request = URLRequest(url: WebViewLogin.loginUrl)
            viewModel.updateDebugInfo("🔄 Refreshing page...")
            nsView.load(request)
        }
    }
    
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        // 清理WebView，减少RBS assertion错误
        nsView.navigationDelegate = nil
        nsView.stopLoading()
        
        // 延迟清理，避免RBS assertion错误
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            nsView.configuration.websiteDataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: Date.distantPast,
                completionHandler: {}
            )
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        let parent: WebViewLogin
        
        init(_ parent: WebViewLogin) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let url = webView.url?.absoluteString ?? "unknown"
            self.parent.viewModel.updateDebugInfo("✅ Loaded: \(url)")
            
            DispatchQueue.main.async {
                self.parent.viewModel.isLoading = false
            }
            
            // 检查cookie
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                self.parent.viewModel.updateDebugInfo("🍪 Found \(cookies.count) cookies")
                
                DispatchQueue.main.async {
                    if self.parent.viewModel.checkLogin(from: cookies) {
                        self.parent.viewModel.updateDebugInfo("🎉 Login successful!")
                        let cookieString = self.parent.viewModel.getCookieString(from: cookies)
                        CloudMusicApi().setCookie(cookieString)
                        self.parent.viewModel.isLoggedIn = true
                        self.parent.onLoginSuccess()
                    }
                }
            }
        }
        
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            self.parent.viewModel.updateDebugInfo("🔄 Starting navigation...")
            DispatchQueue.main.async {
                self.parent.viewModel.isLoading = true
            }
        }
        
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            self.parent.viewModel.setError("Failed to load: \(error.localizedDescription)")
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            self.parent.viewModel.setError("Navigation failed: \(error.localizedDescription)")
        }
        
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            self.parent.viewModel.updateDebugInfo("📝 Navigation committed")
        }
        
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url {
                print("Navigating to: \(url.absoluteString)")
                
                // 检查是否离开了登录页面
                if url.host == "music.163.com" && !url.absoluteString.contains("/login") {
                    
                    webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                        DispatchQueue.main.async {
                            if self.parent.viewModel.checkLogin(from: cookies) {
                                let cookieString = self.parent.viewModel.getCookieString(from: cookies)
                                CloudMusicApi().setCookie(cookieString)
                                self.parent.viewModel.isLoggedIn = true
                                self.parent.onLoginSuccess()
                            }
                        }
                    }
                }
            }
            decisionHandler(.allow)
        }
    }
}

private enum LoginMethod: String, CaseIterable, Identifiable {
    case web
    case qr
    case phone

    var id: Self { self }

    var title: String {
        switch self {
        case .web: return "网页"
        case .qr: return "二维码"
        case .phone: return "手机号"
        }
    }
}

struct LoginSheet: View {
    @EnvironmentObject private var userInfo: UserInfo
    @Binding var isPresented: Bool
    @State private var method: LoginMethod = .web

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("登录网易云音乐")
                    .font(.title2)
                    .fontWeight(.semibold)

                Picker("登录方式", selection: $method) {
                    ForEach(LoginMethod.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 310)

                Spacer()

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("关闭")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            Group {
                switch method {
                case .web:
                    WebLoginPane(onLoginSuccess: completeLogin)
                case .qr:
                    QRLoginPane(onLoginSuccess: completeLogin)
                case .phone:
                    PhoneLoginPane(onLoginSuccess: completeLogin)
                }
            }
        }
        .frame(width: method == .web ? 1100 : 460, height: method == .web ? 800 : 560)
        .background(Color(NSColor.windowBackgroundColor))
    }

    @MainActor
    private func completeLogin() async {
        await initUserData(userInfo: userInfo)
        isPresented = false
    }
}

private struct WebLoginPane: View {
    @StateObject private var webViewLoginVM = WebViewLoginViewModel()
    let onLoginSuccess: () async -> Void
    @State private var refreshTrigger = false

    var body: some View {
        VStack {
            HStack {
                Text(webViewLoginVM.debugInfo)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button {
                    refreshTrigger = true
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("刷新页面")
            }
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 4)
            
            if webViewLoginVM.hasError {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)
                    
                    Text("Loading Error")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text(webViewLoginVM.errorMessage)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    
                    Button("Retry") {
                        webViewLoginVM.hasError = false
                        webViewLoginVM.isLoading = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ZStack {
                    if webViewLoginVM.isLoading {
                        VStack(spacing: 16) {
                            ProgressView()
                                .scaleEffect(1.5)
                            Text("Loading NetEase Music login page...")
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.clear)
                    }
                    
                    WebViewLogin(
                        viewModel: webViewLoginVM,
                        onLoginSuccess: {
                            Task {
                                await onLoginSuccess()
                            }
                        },
                        refreshTrigger: $refreshTrigger
                    )
                    .opacity(webViewLoginVM.isLoading ? 0 : 1)
                }
            }
        }
    }
}

private struct QRLoginPane: View {
    let onLoginSuccess: () async -> Void

    @State private var qrURL = ""
    @State private var status = "正在生成二维码"
    @State private var isLoading = true
    @State private var isExpired = false
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            if let image = qrImage(for: qrURL) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 250, height: 250)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(width: 250, height: 250)
            }

            Text(status)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if isExpired {
                Button("刷新二维码") {
                    Task { await refreshQRCode() }
                }
                .buttonStyle(.borderedProminent)
            } else if isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()
        }
        .padding(24)
        .task {
            await refreshQRCode()
        }
        .onDisappear {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    @MainActor
    private func refreshQRCode() async {
        pollTask?.cancel()
        qrURL = ""
        status = "正在生成二维码"
        isLoading = true
        isExpired = false

        do {
            let api = CloudMusicApi()
            let key = try await api.login_qr_key()
            let url = try await api.login_qr_create(key: key)
            guard !Task.isCancelled else { return }
            qrURL = url
            status = "请使用网易云音乐扫描二维码"
            isLoading = false
            pollTask = Task { await poll(for: key) }
        } catch {
            status = error.localizedDescription
            isLoading = false
            isExpired = true
        }
    }

    @MainActor
    private func poll(for key: String) async {
        while !Task.isCancelled {
            do {
                let result = try await CloudMusicApi().login_qr_check(key: key)
                guard !Task.isCancelled else { return }

                switch result.code {
                case 800:
                    status = "二维码已过期"
                    isExpired = true
                    return
                case 801:
                    status = "请使用网易云音乐扫描二维码"
                case 802:
                    status = "已扫描，请在手机上确认登录"
                case 803:
                    guard CloudMusicApi().getCookie()?.contains("MUSIC_U=") == true else {
                        status = "登录成功，但未收到会话信息，请刷新二维码后重试"
                        isExpired = true
                        return
                    }
                    status = "登录成功"
                    isLoading = false
                    await onLoginSuccess()
                    return
                default:
                    status = result.message
                    isExpired = true
                    return
                }
            } catch {
                status = error.localizedDescription
                isExpired = true
                return
            }

            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func qrImage(for value: String) -> NSImage? {
        guard !value.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

private struct PhoneLoginPane: View {
    let onLoginSuccess: () async -> Void

    @State private var countryCode = "+86"
    @State private var phone = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("手机号密码登录")
                .font(.title3)
                .fontWeight(.semibold)

            TextField("国家/地区区号（如 +86）", text: $countryCode)
                .textFieldStyle(.roundedBorder)

            TextField("手机号", text: $phone)
                .textFieldStyle(.roundedBorder)

            SecureField("密码", text: $password)
                .textFieldStyle(.roundedBorder)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("登录") {
                    Task { await submit() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting || phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            if isSubmitting {
                ProgressView()
                    .padding(.bottom, 42)
            }
        }
    }

    @MainActor
    private func submit() async {
        let normalizedCode = countryCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "+"))
        guard let code = Int(normalizedCode), code > 0 else {
            errorMessage = "请输入有效的国家/地区区号"
            return
        }

        isSubmitting = true
        errorMessage = nil
        let result = await CloudMusicApi().login_cellphone(
            phone: phone.trimmingCharacters(in: .whitespacesAndNewlines),
            countrycode: code,
            password: password
        )
        isSubmitting = false

        if let result {
            errorMessage = result
        } else {
            await onLoginSuccess()
        }
    }
}

struct LoginView: View {
    @State private var showLoginSheet = false
    @EnvironmentObject private var userInfo: UserInfo

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "music.note")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)
            
            Text("Welcome to MusicBox")
                .font(.title)
                .fontWeight(.bold)
            
            Text("Please login to NetEase Music to continue")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button(action: {
                showLoginSheet = true
            }) {
                HStack {
                    Image(systemName: "person.circle")
                    Text("Login to NetEase Music")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.accentColor)
                .cornerRadius(8)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showLoginSheet) {
            LoginSheet(isPresented: $showLoginSheet)
                .environmentObject(userInfo)
        }
    }
}

struct AccountView: View {
    @EnvironmentObject private var userInfo: UserInfo
    @EnvironmentObject private var playlistStatus: PlaylistStatus
    @EnvironmentObject private var playStatus: PlayStatus
    @EnvironmentObject private var playbackReporter: PlaybackReportingCoordinator
    @StateObject private var appSettings = AppSettings.shared

    var body: some View {
        if userInfo.profile != nil {
            SettingsView()
                .environmentObject(userInfo)
                .environmentObject(appSettings)
                .environmentObject(playlistStatus)
                .environmentObject(playStatus)
                .environmentObject(playbackReporter)
        } else {
            LoginView()
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var userInfo: UserInfo
    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var playlistStatus: PlaylistStatus
    @EnvironmentObject private var playStatus: PlayStatus
    @EnvironmentObject private var playbackReporter: PlaybackReportingCoordinator

    var body: some View {
        ScrollView {
            HStack {
                Spacer()

                VStack(spacing: 24) {
                    // Profile Section
                    ProfileSection()
                        .environmentObject(userInfo)

                    Divider()

                    // General Settings Section
                    GeneralSettingsSection()
                        .environmentObject(appSettings)

                    Divider()

                    // Playlist Settings Section
                    PlaylistSettingsSection()
                        .environmentObject(appSettings)

                    Divider()

                    // Storage & Cache Section
                    StorageCacheSection()

                    Divider()

                    RelaySettingsSection()
                        .environmentObject(playbackReporter)

                    Divider()

                    // Account Actions Section
                    AccountActionsSection()
                        .environmentObject(userInfo)
                        .environmentObject(playlistStatus)
                        .environmentObject(playStatus)

                    Divider()

                    // About Section
                    AboutSection()

                    // Extra space for floating player control
                    Color.clear.frame(height: 64)
                }
                .frame(maxWidth: 500)
                .padding(.horizontal, 24)
                .padding(.top, 20)

                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct RelaySettingsSection: View {
    @EnvironmentObject private var playbackReporter: PlaybackReportingCoordinator

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "rectangle.2.swap")
                    .foregroundColor(.accentColor)
                    .font(.title2)
                Text("跨设备接力")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }

            VStack(spacing: 12) {
                SettingRow(
                    icon: "arrow.triangle.2.circlepath",
                    title: "跨设备接力",
                    description: "",
                    control: AnyView(
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { playbackReporter.relayEnabled },
                                set: { enabled in
                                    Task {
                                        await playbackReporter.updateRelayEnabled(enabled)
                                    }
                                }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle())
                        .disabled(
                            !playbackReporter.relayAvailable
                                || playbackReporter.isUpdatingRelaySetting
                        )
                    )
                )
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
        }
    }
}

struct ProfileSection: View {
    @EnvironmentObject private var userInfo: UserInfo

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "person.circle.fill")
                    .foregroundColor(.accentColor)
                    .font(.title2)
                Text("Profile")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }

            HStack(spacing: 16) {
                AsyncImageWithCache(url: URL(string: userInfo.profile?.avatarUrl.https ?? "")) {
                    image in
                    image.resizable()
                        .interpolation(.high)
                } placeholder: {
                    Circle()
                        .fill(Color.gray.opacity(0.3))
                        .overlay(
                            Image(systemName: "person.fill")
                                .foregroundColor(.white)
                                .font(.title)
                        )
                }
                .scaledToFit()
                .clipShape(Circle())
                .frame(width: 80, height: 80)
                .shadow(radius: 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text(userInfo.profile?.nickname ?? "Unknown")
                        .font(.title3)
                        .fontWeight(.medium)

                    Text("User ID: \(userInfo.profile?.userId ?? 0)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("\(userInfo.playlists.count) playlists")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
        }
    }
}

struct GeneralSettingsSection: View {
    @EnvironmentObject private var appSettings: AppSettings

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "gearshape.fill")
                    .foregroundColor(.accentColor)
                    .font(.title2)
                Text("General Settings")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }

            VStack(spacing: 12) {
                SettingRow(
                    icon: "moon.fill",
                    title: "Prevent Sleep When Playing",
                    description: "Keeps your Mac awake while music is playing",
                    control: AnyView(
                        Toggle("", isOn: $appSettings.preventSleepWhenPlaying)
                            .toggleStyle(SwitchToggleStyle())
                    )
                )

                SettingRow(
                    icon: "clock",
                    title: "Show Lyric Timestamps",
                    description: "Display timestamps for each lyric line",
                    control: AnyView(
                        Toggle("", isOn: $appSettings.showTimestamp)
                            .toggleStyle(SwitchToggleStyle())
                    )
                )

                SettingRow(
                    icon: "quote.bubble",
                    title: "Show Romanized Lyrics",
                    description: "Display romanized lyrics when available",
                    control: AnyView(
                        Toggle("", isOn: $appSettings.showRoma)
                            .toggleStyle(SwitchToggleStyle())
                    )
                )

            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
        }
    }
}

struct PlaylistSettingsSection: View {
    @EnvironmentObject private var appSettings: AppSettings

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "music.note.list")
                    .foregroundColor(.accentColor)
                    .font(.title2)
                Text("播放列表")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Picker(selection: $appSettings.doubleClickPlayAction, label: EmptyView()) {
                    Text("双击播放单曲时，用当前单曲所在的歌曲列表替换播放列表")
                        .fixedSize(horizontal: false, vertical: true)
                        .tag(DoubleClickPlayAction.replacePlaylistWithSongList)
                    Text("双击播放单曲时，仅把当前单曲添加到播放列表")
                        .fixedSize(horizontal: false, vertical: true)
                        .tag(DoubleClickPlayAction.appendSongToPlaylist)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
        }
    }
}

struct StorageCacheSection: View {
    @State private var showingCleanAlert = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "internaldrive.fill")
                    .foregroundColor(.accentColor)
                    .font(.title2)
                Text("Storage & Cache")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }

            VStack(spacing: 12) {
                SettingRow(
                    icon: "trash.fill",
                    title: "Clear Cache",
                    description: "Remove cached music files to free up space",
                    control: AnyView(
                        Button(action: {
                            cleanCache()
                        }) {
                            Text("Clean")
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .background(Color.red)
                                .cornerRadius(8)
                        }
                        .buttonStyle(PlainButtonStyle())
                    )
                )
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
        }
    }

    private func cleanCache() {
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "me.elsanna.MusicBox")
        {
            let tmpFolderPath = containerURL.appendingPathComponent("tmp")
            if FileManager.default.fileExists(atPath: tmpFolderPath.path) {
                do {
                    try FileManager.default.removeItem(at: tmpFolderPath)
                    AlertModal.showAlert("Success", "Cache cleaned successfully")
                } catch {
                    print("Error when deleting \(tmpFolderPath): \(error)")
                    AlertModal.showAlert("Error", "Clean failed: \(error.localizedDescription)")
                }
            } else {
                AlertModal.showAlert("Info", "No cache to clean")
            }
        }
    }
}

struct AccountActionsSection: View {
    @EnvironmentObject private var userInfo: UserInfo
    @EnvironmentObject private var playlistStatus: PlaylistStatus
    @EnvironmentObject private var playStatus: PlayStatus

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "person.badge.key.fill")
                    .foregroundColor(.accentColor)
                    .font(.title2)
                Text("Account")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }

            VStack(spacing: 12) {
                SettingRow(
                    icon: "arrow.right.square.fill",
                    title: "Sign Out",
                    description: "Sign out of your NetEase Cloud Music account",
                    control: AnyView(
                        Button(action: {
                            Task {
                                await signOut()
                            }
                        }) {
                            Text("Sign Out")
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .background(Color.orange)
                                .cornerRadius(8)
                        }
                        .buttonStyle(PlainButtonStyle())
                    )
                )
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
        }
    }

    private func signOut() async {
        await playStatus.finishPlaybackReporting(reason: .stopped)
        await CloudMusicApi().logout()
        userInfo.profile = nil
        userInfo.likelist = []
        userInfo.playlists = []

        UserDefaults.standard.removeObject(forKey: "profile")
        UserDefaults.standard.removeObject(forKey: "playlists")
        UserDefaults.standard.removeObject(forKey: "likelist")
        SharedCacheManager.shared.clear()
        
        // Clear playlist and pause current playback
        playlistStatus.pausePlay()
        await playlistStatus.clearPlaylist()
    }
}

struct SettingRow: View {
    let icon: String
    let title: String
    let description: String
    let control: AnyView

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .font(.title3)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .fontWeight(.medium)

                if !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            control
        }
        .padding(.vertical, 4)
    }
}

struct AboutSection: View {
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(.accentColor)
                    .font(.title2)
                Text("About MusicBox")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }

            VStack(spacing: 12) {
                SettingRow(
                    icon: "app.badge",
                    title: "Version",
                    description: BuildInfo.versionString,
                    control: AnyView(
                        Button(action: {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(BuildInfo.versionString, forType: .string)
                        }) {
                            Text("Copy")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(PlainButtonStyle())
                    )
                )

                if BuildInfo.gitCommit != "Development" && BuildInfo.gitCommit != "Unknown" {
                    SettingRow(
                        icon: "doc.text.fill",
                        title: "Build Information",
                        description:
                            "Branch: \(BuildInfo.gitBranch) • Commit: \(String(BuildInfo.gitCommit.prefix(8)))",
                        control: AnyView(
                            Button(action: {
                                let pasteboard = NSPasteboard.general
                                pasteboard.clearContents()
                                pasteboard.setString(BuildInfo.gitCommit, forType: .string)
                            }) {
                                Text("Copy Commit")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(PlainButtonStyle())
                        )
                    )
                }
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
        }
    }
}

struct AccountHeaderView: View {
    @EnvironmentObject private var userInfo: UserInfo

    var body: some View {
        HStack {
            if let profile = userInfo.profile {
                AsyncImageWithCache(url: URL(string: profile.avatarUrl.https)) { image in
                    image.resizable()
                        .interpolation(.high)
                } placeholder: {
                    Color.white
                }
                .scaledToFit()
                .clipShape(Circle())
                .frame(width: 40, height: 40)

                Text(profile.nickname)
                    .font(.system(size: 16))
            } else {
                Color.white
                    .scaledToFit()
                    .clipShape(Circle())
                    .frame(width: 40, height: 40)

                Text("Not login yet")
                    .font(.system(size: 16))
            }
        }
    }
}

//#Preview {
//    HomeContentView()
//}
