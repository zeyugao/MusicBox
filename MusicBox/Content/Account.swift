//
//  Account.swift
//  MusicBox
//
//  Created by Elsa on 2024/4/19.
//

import Foundation
import SwiftUI

struct UserInfo {
    var username: String
    // 这里可以根据需要添加更多属性，如密码等
}

class LoginViewModel: ObservableObject {
    @Published var currentUser: UserInfo?
    @Published var isUserLoggedIn = false

    // 试图从本地存储加载用户信息
    func loadUserInfo() {
        // 假设使用UserDefaults来保存和读取用户信息
        let username = UserDefaults.standard.string(forKey: "username")
        if let username = username {
            isUserLoggedIn = true
            currentUser = UserInfo(username: username)
        } else {
            isUserLoggedIn = false
        }
    }

    // 保存用户登录信息
    func saveUserInfo(username: String) {
        UserDefaults.standard.set(username, forKey: "username")
        loadUserInfo()  // 保存后重新加载用户信息
    }
}

struct AccountView: View {
    @StateObject var viewModel = LoginViewModel()
    @State var username: String = ""
    @State var password: String = ""  // 密码仅用于示例，实际应用中应加密保存

    var body: some View {
        VStack {
            if viewModel.isUserLoggedIn, let currentUser = viewModel.currentUser {
                Text("欢迎回来, \(currentUser.username)!")
            } else {
                // 如果用户未登录，显示登录表单
                TextField("账户", text: $username)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding()

                SecureField("密码", text: $password)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding()

                Button("登录") {
                    viewModel.saveUserInfo(username: username)
                }
                .padding()
            }
        }
        .onAppear {
            viewModel.loadUserInfo()
        }
    }

}
