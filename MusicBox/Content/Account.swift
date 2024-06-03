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
    var isChecking = false

    private func updateLoginMessage(message: String) {
        DispatchQueue.main.async {
            self.loginMessage = message
        }
    }

    func fetchQRCode() async {
        do {
            DispatchQueue.main.async {
                self.qrCodeImageURL = nil
                self.loginMessage = nil
            }
            let keyResponse = try await CloudMusicApi().login_qr_key()
            let url = try await CloudMusicApi().login_qr_create(key: keyResponse)
            DispatchQueue.main.async {
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
            default:
                updateLoginMessage(message: checkRes.message + " (Trial \(i))")
            }
        }
    }
}

struct LoginView: View {
    @State private var username = ""
    @State private var password = ""
    @State private var showQrCode = false

    @StateObject private var loginVM = LoginViewModel()
    @EnvironmentObject private var userInfo: UserInfo

    var body: some View {
        VStack(spacing: 16) {
            TextField("Phone or Email", text: $username)
                .textFieldStyle(RoundedBorderTextFieldStyle())
            SecureField("Password", text: $password)
                .textFieldStyle(RoundedBorderTextFieldStyle())

            HStack {
                Spacer()
                Button(action: {
                    Task {
                        let res = await CloudMusicApi().login_cellphone(
                            phone: username, password: password)
                        if let error = res {
                            AlertModel.showAlert("Login failed. Please use QR Login.", error)
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
                }
                Spacer()
            }
        }.frame(width: 200)
    }
}

struct AccountView: View {
    @EnvironmentObject private var userInfo: UserInfo

    var body: some View {
        if let profile = userInfo.profile {
            VStack {
                VStack(spacing: 8) {
                    AsyncImageWithCache(url: URL(string: profile.avatarUrl.https)!) { image in
                        image.resizable()
                            .interpolation(.high)
                    } placeholder: {
                        Color.white
                    }
                    .scaledToFit()
                    .clipShape(Circle())
                    .frame(width: 64, height: 64)

                    Text(profile.nickname)
                        .font(.system(size: 16))
                }

                HStack {
                    Button(action: {
                        Task {
                            await CloudMusicApi().logout()
                            userInfo.profile = nil
                            userInfo.likelist = []
                            userInfo.playlists = []

                            saveEncodableState(forKey: "profile", data: userInfo.profile)
                        }
                    }) {
                        Text("Logout")
                    }
                }

                HStack {
                    Button(action: {
                        if let containerURL = FileManager.default.containerURL(
                            forSecurityApplicationGroupIdentifier: "me.elsanna.MusicBox")
                        {
                            let tmpFolderPath = containerURL.appendingPathComponent("tmp")
                            if FileManager.default.fileExists(atPath: tmpFolderPath.path) {
                                do {
                                    try FileManager.default.removeItem(at: tmpFolderPath)
                                } catch {
                                    print("Error when deleting \(tmpFolderPath): \(error)")

                                    AlertModel.showAlert("Error", "Clean failed: \(error)")

                                    return
                                }
                            }
                            AlertModel.showAlert("Info", "Clean successful")
                        }
                    }) {
                        Text("Clean cache")
                    }
                }
            }

        } else {
            LoginView()
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
