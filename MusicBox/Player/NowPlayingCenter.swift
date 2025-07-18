/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Class `NowPlaying` interacts with MPNowPlayingInfoCenter.
*/

import AppKit
import MediaPlayer

class NowPlayingCenter {

    /// Updates the information in the MPNowPlayingInfoCenter when the current item changes.
    static func handleItemChange(item: PlaylistItem?, index: Int, count: Int) async {

        let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
        var nowPlayingInfo = [String: Any]()

        // Reinitialize the information, unless there is a current item.
        if let currentItem = item {

            nowPlayingInfo = nowPlayingInfoCenter.nowPlayingInfo ?? [String: Any]()

            // Update information about the item.
            nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] =
                MPNowPlayingInfoMediaType.audio.rawValue
            nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = false
            nowPlayingInfo[MPMediaItemPropertyTitle] = currentItem.title
            nowPlayingInfo[MPMediaItemPropertyArtist] = currentItem.artist
            if let nsSong = currentItem.nsSong {
                nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = nsSong.al.name
            }

            if let artworkUrl = await currentItem.getArtworkUrl(),
               let (imageData, _) = try? await URLSession.shared.data(from: artworkUrl),
               let image = NSImage(data: imageData)
            {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in
                    return image
                }
                nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
            }

            nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackQueueIndex] = index
            nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackQueueCount] = count

            // Reinitialize information about the playback position.
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = nil
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = nil
            nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = nil
            nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = nil
        }

        nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo
    }

    /// Updates the information in the MPNowPlayingInfoCenter when the playback rate or position changes.
    static func handlePlaybackChange(playing: Bool, rate: Float, position: Double, duration: Double)
    {

        let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
        var nowPlayingInfo = nowPlayingInfoCenter.nowPlayingInfo ?? [String: Any]()

        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = Float(duration)
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Float(position)
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = rate
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0

        nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo
    }

    static func handleSetPlaybackState(playing: Bool) {
        let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
        var nowPlayingInfo = nowPlayingInfoCenter.nowPlayingInfo ?? [String: Any]()
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
        nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo
        nowPlayingInfoCenter.playbackState = playing ? .playing : .paused
    }
}
