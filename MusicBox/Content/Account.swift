//
//  Home.swift
//  MusicBox
//
//  Created by Elsa on 2024/4/19.
//

import AVFoundation
import Combine
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
    }

    if let likelist = loadDecodableState(
        forKey: "likelist", type: Set<UInt64>.self)
    {
        userInfo.likelist = likelist
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
    
    func makeNSView(context: Context) -> WKWebView {
        viewModel.updateDebugInfo("Creating WebView...")
        
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        
        // 直接加载网易云音乐登录页面
        let loginURL = URL(string: "https://music.163.com/#/login")!
        let request = URLRequest(url: loginURL)
        
        viewModel.updateDebugInfo("Loading: \(loginURL.absoluteString)")
        webView.load(request)
        
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    
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

struct WebViewLoginSheet: View {
    @StateObject private var webViewLoginVM = WebViewLoginViewModel()
    @EnvironmentObject private var userInfo: UserInfo
    @Binding var isPresented: Bool

    var body: some View {
        VStack {
            // Header with close button
            HStack {
                Text("Login to NetEase Music")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Button(action: {
                    isPresented = false
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding()
            
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
                VStack {
                    // Debug info bar
                    Text(webViewLoginVM.debugInfo)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
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
                        
                        WebViewLogin(viewModel: webViewLoginVM) {
                            Task {
                                await initUserData(userInfo: userInfo)
                                isPresented = false // 登录成功后关闭弹窗
                            }
                        }
                        .opacity(webViewLoginVM.isLoading ? 0 : 1)
                    }
                }
            }
        }
        .frame(width: 1000, height: 800)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .shadow(radius: 20)
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
            WebViewLoginSheet(isPresented: $showLoginSheet)
                .environmentObject(userInfo)
        }
    }
}

struct AccountView: View {
    @EnvironmentObject private var userInfo: UserInfo
    @EnvironmentObject private var playlistStatus: PlaylistStatus
    @StateObject private var appSettings = AppSettings.shared

    var body: some View {
        if userInfo.profile != nil {
            SettingsView()
                .environmentObject(userInfo)
                .environmentObject(appSettings)
                .environmentObject(playlistStatus)
        } else {
            LoginView()
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var userInfo: UserInfo
    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var playlistStatus: PlaylistStatus

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

                    // Storage & Cache Section
                    StorageCacheSection()

                    Divider()

                    // Account Actions Section
                    AccountActionsSection()
                        .environmentObject(userInfo)
                        .environmentObject(playlistStatus)

                    Divider()

                    // About Section
                    AboutSection()

                    Spacer(minLength: 20)
                }
                .frame(maxWidth: 500)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)

                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
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
            }
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
        await CloudMusicApi().logout()
        userInfo.profile = nil
        userInfo.likelist = []
        userInfo.playlists = []

        saveEncodableState(forKey: "profile", data: userInfo.profile)
        
        // Clear playlist and pause current playback
        playlistStatus.pausePlay()
        playlistStatus.clearPlaylist()
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

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
