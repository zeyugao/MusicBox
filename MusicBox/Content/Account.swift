//
//  Home.swift
//  MusicBox
//
//  Created by Elsa on 2024/4/19.
//

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

func generateQRCode(str: String, width: CGFloat = 300, height: CGFloat = 300) -> NSImage {
    guard let data = str.data(using: .utf8, allowLossyConversion: false) else {
        return NSImage()
    }
    let filter = CIFilter(name: "CIQRCodeGenerator")
    filter?.setValue(data, forKey: "inputMessage")
    guard let image = filter?.outputImage else { return NSImage() }

    let scaleX = width / image.extent.size.width
    let scaleY = height / image.extent.size.height
    let transformedImage = image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

    let rep = NSCIImageRep(ciImage: transformedImage)
    let nsImage = NSImage(size: NSSize(width: width, height: height))
    nsImage.addRepresentation(rep)
    nsImage.backgroundColor = .clear
    nsImage.cacheMode = .always
    return nsImage
}

class LoginViewModel: ObservableObject {
    @Published var qrCodeImageURL: URL?
    @Published var loginMessage: String?
    @Published var showAlert = false
    @Published var alertMessage = ""
    var isChecking = false
    var closeQRCodeSheet: (() -> Void)?

    private func updateLoginMessage(message: String) {
        Task { @MainActor in
            self.loginMessage = message
        }
    }

    private func showAlertMessage(message: String) {
        Task { @MainActor in
            self.alertMessage = message
            self.showAlert = true
        }
    }

    func fetchQRCode() async {
        do {
            await MainActor.run {
                self.qrCodeImageURL = nil
                self.loginMessage = nil
            }
            let keyResponse = try await CloudMusicApi().login_qr_key()
            let url = try await CloudMusicApi().login_qr_create(key: keyResponse)
            await MainActor.run {
                self.qrCodeImageURL = URL(string: url)
                self.loginMessage = "等待扫码"
            }
            isChecking = true
            try await checkQRCodeStatus(key: keyResponse)
        } catch {
            updateLoginMessage(message: error.localizedDescription)
        }
    }

    func cancelCheck() {
        isChecking = false
    }

    private func checkQRCodeStatus(key: String) async throws {
        for i in 1...100 {
            if !isChecking {
                return
            }
            try await Task.sleep(nanoseconds: 1 * 1_000_000_000)
            let checkRes = try await CloudMusicApi().login_qr_check(key: key)
            switch checkRes.code {
            case 803:
                updateLoginMessage(message: "Login Successful")
                isChecking = false
                return
            case 8821:
                // Show alert instead of captcha
                isChecking = false
                await MainActor.run {
                    if let closeSheet = self.closeQRCodeSheet {
                        closeSheet()
                    }
                }
                showAlertMessage(message: "需要验证码验证，请使用 Cookie 登录")
                return
            default:
                //                print("Result: \(checkRes.)")
                updateLoginMessage(message: checkRes.message + " (Trial \(i))")
            }
        }
    }
}

struct LoginView: View {
    @State private var username = ""
    @State private var password = ""
    @State private var showQrCode = false
    @State private var showCookieLogin = false
    @State private var cookieText = ""

    @StateObject private var loginVM = LoginViewModel()
    @EnvironmentObject private var userInfo: UserInfo

    var body: some View {
        VStack(spacing: 16) {
            TextField("Phone or Email", text: $username)
                .textFieldStyle(RoundedBorderTextFieldStyle())
            SecureField("Password", text: $password)
                .textFieldStyle(RoundedBorderTextFieldStyle())

            VStack(spacing: 8) {
                HStack {
                    Spacer()
                    Button(action: {
                        Task {
                            let res = await CloudMusicApi().login_cellphone(
                                phone: username, password: password)
                            if let error = res {
                                AlertModal.showAlert("Login failed. Please use QR Login.", error)
                            } else {
                                await initUserData(userInfo: userInfo)
                            }
                        }
                    }) {
                        Text("Login")
                    }
                    Spacer()
                    Button(action: {
                        showQrCode = true
                        Task {
                            await loginVM.fetchQRCode()
                            showQrCode = false
                            await initUserData(userInfo: userInfo)
                        }
                    }) {
                        Text("QR Login")
                    }
                    Spacer()
                }

                // Cookie Login Button
                Button(action: {
                    showCookieLogin = true
                }) {
                    Text("Cookie Login")
                        .font(.caption)
                }
            }
        }
        .frame(width: 220)
        .sheet(isPresented: $showQrCode) {
            VStack {
                if let qrCodeImageURL = loginVM.qrCodeImageURL {
                    Image(
                        nsImage: generateQRCode(
                            str: qrCodeImageURL.absoluteString, width: 160, height: 160
                        )
                    )
                } else {
                    Text("")
                        .frame(width: 160, height: 160)
                }
                if let message = loginVM.loginMessage {
                    Text(message)
                } else {
                    Text("Loading QR Code")
                }
                Button(action: {
                    showQrCode = false
                    loginVM.cancelCheck()
                }) {
                    Text("Cancel")
                }
            }
            .padding()
            .onAppear {
                // Set the callback to close this sheet
                loginVM.closeQRCodeSheet = {
                    showQrCode = false
                }
            }
        }
        .sheet(isPresented: $showCookieLogin) {
            VStack(spacing: 16) {
                Text("Cookie Login")
                    .font(.headline)

                Text("请粘贴从浏览器获取的 Cookie")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextEditor(text: $cookieText)
                    .frame(minHeight: 100)
                    .border(Color.gray, width: 1)
                    .padding(.horizontal)

                HStack {
                    Button("Cancel") {
                        showCookieLogin = false
                        cookieText = ""
                    }

                    Spacer()

                    Button("Login") {
                        if !cookieText.isEmpty {
                            CloudMusicApi().setCookie(cookieText)
                            showCookieLogin = false
                            cookieText = ""
                            Task {
                                await initUserData(userInfo: userInfo)
                            }
                        }
                    }
                    .disabled(cookieText.isEmpty)
                }
                .padding(.horizontal)
            }
            .padding()
            .frame(width: 400, height: 250)
        }
        .alert("验证提示", isPresented: $loginVM.showAlert) {
            Button("OK") {
                loginVM.showAlert = false
            }
        } message: {
            Text(loginVM.alertMessage)
        }
    }
}

struct AccountView: View {
    @EnvironmentObject private var userInfo: UserInfo
    @StateObject private var appSettings = AppSettings.shared

    var body: some View {
        if userInfo.profile != nil {
            SettingsView()
                .environmentObject(userInfo)
                .environmentObject(appSettings)
        } else {
            LoginView()
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var userInfo: UserInfo
    @EnvironmentObject private var appSettings: AppSettings

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
                        description: "Branch: \(BuildInfo.gitBranch) • Commit: \(String(BuildInfo.gitCommit.prefix(8)))",
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
