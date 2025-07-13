//
//  AppSettings.swift
//  MusicBox
//
//  Created by Elsa on 2024/12/13.
//

import Foundation
import IOKit.pwr_mgt

class AppSettings: ObservableObject {
    @Published var preventSleepWhenPlaying: Bool = false {
        didSet {
            UserDefaults.standard.set(preventSleepWhenPlaying, forKey: "preventSleepWhenPlaying")
            updateSleepAssertion()
        }
    }
    
    private var sleepAssertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var isPlayingMusic: Bool = false
    
    static let shared = AppSettings()
    
    private init() {
        preventSleepWhenPlaying = UserDefaults.standard.bool(forKey: "preventSleepWhenPlaying")
        setupPlaybackObserver()
    }
    
    private func setupPlaybackObserver() {
        NotificationCenter.default.addObserver(
            forName: .playbackStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let isPlaying = notification.userInfo?["isPlaying"] as? Bool {
                self?.isPlayingMusic = isPlaying
                self?.updateSleepAssertion()
            }
        }
    }
    
    private func updateSleepAssertion() {
        if preventSleepWhenPlaying && isPlayingMusic {
            enableSleepAssertion()
        } else {
            disableSleepAssertion()
        }
    }
    
    private func enableSleepAssertion() {
        guard sleepAssertionID == IOPMAssertionID(0) else { return }
        
        let assertionName = "MusicBox Playing" as CFString
        let reason = "Preventing sleep while music is playing" as CFString
        
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &sleepAssertionID
        )
        
        if result != kIOReturnSuccess {
            print("Failed to create sleep assertion: \(result)")
        } else {
            print("Sleep assertion enabled")
        }
    }
    
    private func disableSleepAssertion() {
        guard sleepAssertionID != IOPMAssertionID(0) else { return }
        
        let result = IOPMAssertionRelease(sleepAssertionID)
        if result != kIOReturnSuccess {
            print("Failed to release sleep assertion: \(result)")
        } else {
            print("Sleep assertion disabled")
        }
        sleepAssertionID = IOPMAssertionID(0)
    }
    
    deinit {
        disableSleepAssertion()
        NotificationCenter.default.removeObserver(self)
    }
}

extension Notification.Name {
    static let playbackStateChanged = Notification.Name("playbackStateChanged")
}
