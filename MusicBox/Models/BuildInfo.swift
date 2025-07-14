//
//  BuildInfo.swift
//  MusicBox
//
//  Created by Elsa on 2025/1/14.
//

import Foundation

struct BuildInfo {
    static var appVersion: String {
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
    
    static var buildVersion: String {
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }
    
    static var buildId: String {
        // Extract build ID from build version (format: "buildNumber.gitCommit")
        let components = buildVersion.components(separatedBy: "-")
        return components.first ?? "Unknown"
    }
    
    static var gitCommit: String {
        // Extract git commit from build version (format: "buildNumber.gitCommit")
        let components = buildVersion.components(separatedBy: "-")
        if components.count >= 2 {
            return components[1]
        }
        
        #if DEBUG
        return "Development"
        #else
        return "Unknown"
        #endif
    }
    
    static var gitBranch: String {
        #if DEBUG
        return "main"
        #else
        // For release builds, we assume it's from main branch unless specified otherwise
        return "main"
        #endif
    }
    
    static var versionString: String {
        let version = appVersion
        let build = buildVersion
        
        #if DEBUG
        return "\(version) (\(build)) - Debug"
        #else
        let components = build.components(separatedBy: ".")
        if components.count >= 2 {
            let buildNumber = components[0]
            let commit = components[1]
            return "\(version) - Build #\(buildNumber) (\(commit))"
        } else {
            return "\(version) (\(build))"
        }
        #endif
    }
}
