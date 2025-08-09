/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Class `RemoteCommandCenter` interacts with MPRemoteCommandCenter.
*/

import MediaPlayer

/// Types of remote commands.
enum RemoteCommand {
    case pause, play, nextTrack, previousTrack, togglePlayPause
    case skipForward(TimeInterval)
    case skipBackward(TimeInterval)
    case changePlaybackPosition(TimeInterval)
}

/// Behavior of an object that handles remote commands.
protocol RemoteCommandHandler: AnyObject {
    func performRemoteCommand(_: RemoteCommand)
}

class RemoteCommandCenter {
    private static var currentHandler: RemoteCommandHandler?
    
    /// Registers callbacks for various remote commands.
    /// This method clears any existing targets before registering new ones.
    static func handleRemoteCommands(using handler: RemoteCommandHandler) {
        
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // Clear existing targets before registering new ones
        clearRemoteCommands()
        
        // Store the current handler
        currentHandler = handler
        
        commandCenter.pauseCommand.addTarget { _ in
            guard let handler = currentHandler else { return .noActionableNowPlayingItem }
            handler.performRemoteCommand(.pause)
            return .success
        }
        
        commandCenter.playCommand.addTarget { _ in
            guard let handler = currentHandler else { return .noActionableNowPlayingItem }
            handler.performRemoteCommand(.play)
            return .success
        }
        
        commandCenter.togglePlayPauseCommand.addTarget { _ in
            guard let handler = currentHandler else { return .noActionableNowPlayingItem }
            handler.performRemoteCommand(.togglePlayPause)
            return .success
        }
        
        commandCenter.nextTrackCommand.addTarget { _ in
            guard let handler = currentHandler else { return .noActionableNowPlayingItem }
            handler.performRemoteCommand(.nextTrack)
            return .success
        }
        
        commandCenter.previousTrackCommand.addTarget { _ in
            guard let handler = currentHandler else { return .noActionableNowPlayingItem }
            handler.performRemoteCommand(.previousTrack)
            return .success
        }
        
        // commandCenter.skipForwardCommand.preferredIntervals = [15.0]
        // commandCenter.skipForwardCommand.addTarget { [weak handler] event in
        //     guard let handler = handler,
        //         let event = event as? MPSkipIntervalCommandEvent
        //         else { return .noActionableNowPlayingItem }
            
        //     handler.performRemoteCommand(.skipForward(event.interval))
        //     return .success
        // }
        
        // commandCenter.skipBackwardCommand.preferredIntervals = [15.0]
        // commandCenter.skipBackwardCommand.addTarget { [weak handler] event in
        //     guard let handler = handler,
        //         let event = event as? MPSkipIntervalCommandEvent
        //         else { return .noActionableNowPlayingItem }
            
        //     handler.performRemoteCommand(.skipBackward(event.interval))
        //     return .success
        // }
        
        commandCenter.changePlaybackPositionCommand.addTarget { event in
            guard let handler = currentHandler,
                let event = event as? MPChangePlaybackPositionCommandEvent
                else { return .noActionableNowPlayingItem }
            
            handler.performRemoteCommand(.changePlaybackPosition(event.positionTime))
            return .success
        }
    }
    
    /// Clears all remote command targets to prevent duplicate registrations
    private static func clearRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
    }
    
    /// Call this when the app is about to be terminated or when changing handlers
    static func cleanup() {
        clearRemoteCommands()
        currentHandler = nil
    }
}
