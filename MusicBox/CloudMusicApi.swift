//
//  CloudMusicApi.swift
//  MusicBox
//
//  Created by Elsa on 2024/4/20.
//

import Foundation

class CloudMusicApi {

    static func doRequest(memberName: String, data: [String: Any]) {
//        if let jsonData = try? JSONSerialization.data(withJSONObject: data) {
//            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
//
//            memberName.withCString { memberName in
//                let memberName = UnsafeMutablePointer(mutating: memberName)
//
//                jsonString.withCString { jsonString in
//                    let jsonString = UnsafeMutablePointer(mutating: jsonString)
//                    let jsonResultCString = invoke(memberName, jsonString)
//                    if let cString = jsonResultCString {
//                        let jsonResult = String(cString: cString)
//                        if let jsonData = jsonResult.data(using: .utf8) {
//                            if let dict = try? JSONSerialization.jsonObject(
//                                with: jsonData, options: []) as? [String: Any]
//                            {
//                                print(dict)
//                            }
//                        }
//                    }
//                }
//            }
//        }
    }

    static func login_qr_key() {
        doRequest(memberName: "login_qr_key", data: [:])
    }
}
