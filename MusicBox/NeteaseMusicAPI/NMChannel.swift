//
//  NMChannel.swift
//  NeteaseMusic
//
//  Created by xjbeta on 8/15/21.
//  Copyright © 2021 xjbeta. All rights reserved.
//

import Foundation
import CryptoSwift

class NMChannel: NSObject {
    private let EAPI_AES_KEY = "e82ckenh8dichen8"

    let deviceId: String
    let appver: String
    
    let deviceIdS = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    
    
    init(_ deviceId: String, _ appver: String) {
        self.deviceId = deviceId
        self.appver = appver
    }
    
    
    func serialData(_ params: [String: Any], url: String) throws -> String {
        let key = "36cd479b6b5"
        let u = url.replacingOccurrences(of: "https://music.163.com/eapi", with: "/api")
        
        let json = try eapiParams(params)

        let str = [u,
                   key,
                   json,
                   key,
                   "nobody\(u)use\(json)md5forencrypt".md5()].joined(separator: "-")
        
        let aes = try AES(key: EAPI_AES_KEY.bytes, blockMode: ECB())

        return try str.encrypt(cipher: aes)
    }
    
    func deSerialData(_ params: String, split: Bool = true) throws -> String? {
        let aes = try AES(key: EAPI_AES_KEY.bytes, blockMode: ECB())
        let re = try Data(hex: params).decrypt(cipher: aes)
        let str = String(data: re, encoding: .utf8)

        guard split else {
            return str
        }
        
        guard let l = str?.components(separatedBy: "-36cd479b6b5-"),
              l.count == 3 else {
//                  Log.error("DeSerialData failed.  \(str ?? "")")
                  return nil
              }
        return l[1]
    }
    
    private func eapiParams(_ params: [String: Any]) throws -> String {
        
        let header = NMEapiHeader(
            appver: appver,
            deviceId: deviceId,
            requestId: "\(randomInt(8))")
            .jsonString()
        
        let eParams = NMEapiParams(
            header: header,
            deviceId: deviceIdS)
        
        let data = try JSONEncoder().encode(eParams)
        var json = try JSONSerialization.jsonObject(with: data, options: .allowFragments) as? [String: Any] ?? [:]
        
        json.merge(params) { (_, new) in new }
        let d = try JSONSerialization.data(withJSONObject: json, options: .fragmentsAllowed)
        return String(data: d, encoding: .utf8) ?? ""
    }
    
    private func randomInt(_ digits: Int) -> Int {
        let min = Int(pow(10, Double(digits-1))) - 1
        let max = Int(pow(10, Double(digits))) - 1
        return Int.random(in: (min...max))
    }
    
    
}
