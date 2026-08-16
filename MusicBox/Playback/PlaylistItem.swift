/*
 See LICENSE folder for this sample's licensing information.

 Abstract:
 A serializable description of a playable track. Resource resolution belongs to
 AudioSourceResolver so queue and UI code never start I/O as a side effect.
 */

import CoreMedia
import Foundation

struct PlaybackSourcePlaylist: Codable, Hashable {
    let id: UInt64
    let name: String
}

struct PlaylistItem: Identifiable, Codable, Equatable, Hashable {
    let id: UInt64
    var url: URL?
    let title: String
    let artist: String
    var ext: String?
    let duration: CMTime
    let albumId: UInt64
    var artworkUrl: URL?
    let nsSong: CloudMusicApi.Song?
    var sourcePlaylist: PlaybackSourcePlaylist?

    init(
        id: UInt64,
        url: URL?,
        title: String,
        artist: String,
        albumId: UInt64,
        ext: String?,
        duration: CMTime,
        artworkUrl: URL?,
        nsSong: CloudMusicApi.Song?,
        sourcePlaylist: PlaybackSourcePlaylist? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.artist = artist
        self.ext = ext
        self.duration = duration
        self.albumId = albumId
        self.artworkUrl = artworkUrl
        self.nsSong = nsSong
        self.sourcePlaylist = sourcePlaylist
    }

    enum CodingKeys: String, CodingKey {
        case id, url, title, artist, ext, duration, albumId, artworkUrl, nsSong, sourcePlaylist
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UInt64.self, forKey: .id)
        url = try container.decodeIfPresent(URL.self, forKey: .url)
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decode(String.self, forKey: .artist)
        ext = try container.decodeIfPresent(String.self, forKey: .ext)
        duration = CMTime(
            seconds: try container.decode(Double.self, forKey: .duration),
            preferredTimescale: 1_000
        )
        albumId = try container.decode(UInt64.self, forKey: .albumId)
        artworkUrl = try container.decodeIfPresent(URL.self, forKey: .artworkUrl)
        nsSong = try container.decodeIfPresent(CloudMusicApi.Song.self, forKey: .nsSong)
        sourcePlaylist = try container.decodeIfPresent(PlaybackSourcePlaylist.self, forKey: .sourcePlaylist)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encodeIfPresent(ext, forKey: .ext)
        try container.encode(duration.seconds, forKey: .duration)
        try container.encode(albumId, forKey: .albumId)
        try container.encodeIfPresent(artworkUrl, forKey: .artworkUrl)
        try container.encodeIfPresent(nsSong, forKey: .nsSong)
        try container.encodeIfPresent(sourcePlaylist, forKey: .sourcePlaylist)
    }

    static func == (lhs: PlaylistItem, rhs: PlaylistItem) -> Bool {
        lhs.id == rhs.id && lhs.sourcePlaylist == rhs.sourcePlaylist && lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(sourcePlaylist)
        hasher.combine(url)
    }
}
