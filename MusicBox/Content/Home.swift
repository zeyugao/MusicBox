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

    private func updateLoginMessage(message: String) {
        DispatchQueue.main.async {
            self.loginMessage = message
        }
    }

    func fetchQRCode() async {
        do {
            let keyResponse = try await CloudMusicApi.login_qr_key()
            let url = try await CloudMusicApi.login_qr_create(key: keyResponse)
            DispatchQueue.main.async {
                self.qrCodeImageURL = URL(string: url)
            }
            try await checkQRCodeStatus(key: keyResponse)
        } catch {
            updateLoginMessage(message: error.localizedDescription)
        }
    }

    private func checkQRCodeStatus(key: String) async throws {
        for i in 1...100 {
            try await Task.sleep(nanoseconds: 1 * 1_000_000_000)
            let checkRes = try await CloudMusicApi.login_qr_check(key: key)
            switch checkRes.code {
            case 803:
                updateLoginMessage(message: "Login Successful")
                return
            default:
                updateLoginMessage(message: checkRes.message + " (Trial \(i))")
            }
        }
    }
}

extension URL {
    func fixSecure() -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return components?.url ?? self
    }
}


struct HomeContentView: View {
    @EnvironmentObject var playController: PlayController
    @StateObject private var loginVM = LoginViewModel()
    @EnvironmentObject private var userInfo: UserInfo

    var body: some View {
        VStack {
            if let profile = userInfo.profile {
                AsyncImage(url: URL(string: profile.avatarUrl.https)) { image in
                    image.resizable()
                } placeholder: {
                    Text("Loading Avatar")
                }
                .scaledToFit()
                .frame(width: 200, height: 200)
                Text(profile.nickname)
            } else {
                if let qrCodeImageURL = loginVM.qrCodeImageURL {
                    Image(
                        nsImage: generateQRCode(
                            str: qrCodeImageURL.absoluteString, width: 160, height: 160))
                }

                if let message = loginVM.loginMessage {
                    Text(message)
                }
            }
        }.onAppear {
            Task {
                if userInfo.profile == nil {
                    if let profile = await CloudMusicApi.login_status() {
                        userInfo.profile = profile
                    } else {
                        await loginVM.fetchQRCode()
                    }
                }
            }
        }
    }
}

#Preview {
    HomeContentView()
}
