# AGENTS.md

This guide explains how automation or coding assistants should work inside the MusicBox repository. It expands on high-level architecture with concrete implementation details so agents can navigate code confidently and make safe changes.

## Project Overview
- MusicBox is a macOS 14+ SwiftUI application that layers native playback, lyrics, and caching on top of the NetEase Cloud Music ecosystem.
- `MusicBoxApp.swift` bootstraps the app, wires Sparkle’s `SPUStandardUpdaterController`, and manages the main window lifecycle.
- The NetEase C++ bridge (`QCloudMusicApi`) is surfaced through `Api/CloudMusicApi.swift`, giving Swift code access to login, playlists, and streaming endpoints.
- Progressive audio caching, smart lyric timing, and remote control integration differentiate the player from web wrappers.

## Development Workflow
- Open `MusicBox.xcodeproj` with Xcode 15 or newer, then build (`⌘B`) or run (`⌘R`) the `MusicBox` target.
- The bridging header (`MusicBox/Api/MusicBox-Bridging-Header.h`) exposes the compiled `QCloudMusicApi` static library; no additional package manager steps are required locally.
- Sparkle update signing is already configured for development; make sure the updater controller remains initialized in `MusicBoxApp` when altering startup code.
- GitHub Actions handle fetching QCloudMusicApi for releases, so avoid removing the API headers or altering their relative paths.

## Architecture Overview
- SwiftUI + Combine form the UI layer, backed by observable models for player, navigation, and user state.
- `Player/Player.swift` encapsulates playback orchestration, queue management, and smart lyric synchronization.
- `Api/CloudMusicApi.swift` wraps C++ entry points via `invoke`, adding caching, cookie persistence, and Swift-friendly models.
- `CachingPlayerItem` applies a custom `AVAssetResourceLoader` delegate to cache streams while playback continues.
- `Models/AppSettings.swift` centralizes persisted preferences and macOS-specific behaviors like sleep prevention.

## Directory Map
```
MusicBox/
├── Api/                     # NetEase Music API integration
├── Player/                  # Audio playback engine and queue logic
├── CachingPlayerItem/       # Progressive download implementation
├── Component/               # Reusable SwiftUI components
├── Content/                 # Major user-facing views
├── Models/                  # Persisted settings and metadata
└── General/                 # Cross-cutting extensions/utilities
```

## Implementation Hotspots

### Application Bootstrap (`MusicBox/MusicBoxApp.swift`)
- `AppDelegate` keeps a static `mainWindow`, overrides `applicationShouldTerminateAfterLastWindowClosed`, and ensures the app stays resident after closing.
- `AppDelegate.setupGlobalKeyMonitor()` intercepts space-bar presses, but bypasses NSText-based responders so typing still works.
- `WindowDelegate.windowShouldClose` hides the primary window instead of tearing down state, mirroring native macOS media apps.
- `CheckForUpdatesViewModel` observes `SPUUpdater.canCheckForUpdates` through Combine and enables the Sparkle “Check for Updates…” menu item.
- `MusicBoxApp` adjusts window dimensions via `setContentSize` on appear and injects custom command groups for Sparkle and a “Show MusicBox” shortcut.

### Navigation & State (`MusicBox/ContentView.swift`, `MusicBox/Content/*`)
- `ContentView` owns a `NavigationSplitView` and serializes `NavigationScreen` selections so the sidebar restores across launches.
- `JSONUtils` wraps encoding/decoding helpers for any state persisted via `UserDefaults`, including navigation stacks and queue snapshots.
- `PlayingDetailModel` exposes `@MainActor` toggles that animate the full-screen player overlay.
- `AlertModal` listens for `AlertModal.showAlertName` notifications and renders global alerts with optional callback hooks.
- `UserInfo` caches `CloudMusicApi.Profile`, playlist metadata, and like sets to avoid redundant network calls when the sidebar refreshes.

### Audio Engine (`MusicBox/Player/Player.swift`)
- `PlayStatus` owns the shared `AVPlayer`, serializes `Storage` into `UserDefaults`, and publishes `.playbackStateChanged` notifications for other components.
- `LyricStatus` keeps lyric timestamps at 0.1-second granularity, using a binary search in `findLyricIndex` for O(log n) lookups.
- `SmartLyricSynchronizer` runs a `Timer` on the main loop, schedules callbacks from `getNextLyricChangeTime`, and restarts cleanly on seek or view changes.
- `PlaylistStatus` implements `RemoteCommandHandler`, managing loop modes, “Play Next” queues, and remote command routing through `RemoteCommandCenter`.
- `PlayStatus.controlPlayerObserver` reacts to commands like `.switchItem`, cancelling stale seek tasks before calling `seekToItem` to guarantee consistent transitions.

### Progressive Cache (`MusicBox/CachingPlayerItem/*`)
- `CachingPlayerItem` rewrites media URLs to a custom `cachingPlayerItemScheme`, letting `AVAssetResourceLoader` redirect requests to a delegate.
- `ResourceLoaderDelegate` streams bytes via `URLSession`, persists chunks with `MediaFileHandle`, and fulfills range requests directly from disk cache.
- `ResourceLoaderDelegate.verifyResponse()` enforces HTTP status, expected size, and minimum file thresholds before marking downloads complete.
- `CachingPlayerItemDelegate` callbacks report download progress and readiness back to the owning player controller.
- `CachingPlayerItemConfiguration` centralizes buffer thresholds, read limits, and verification flags so tweaks stay consistent.

### API Layer (`MusicBox/Api/CloudMusicApi.swift`)
- `CloudMusicApi` marshals Swift dictionaries into JSON, calls the bridged `invoke` function, and decodes responses into strongly typed models.
- `SharedCacheManager` MD5-hashes request payloads, tracks TTL-expiring values, and purges stale entries on a repeating `Timer`.
- `doRequest` reinstates cached payloads when available, else performs the C++ bridge call and caches the fresh response.
- `RequestError` and `ServerError` provide localized messaging including custom handling for NetEase-specific result codes (for example `-462`).
- `IntOrString` gracefully decodes IDs that the API returns inconsistently as numbers or strings.

## State Persistence & Settings
- `Models/AppSettings.swift` loads preferences on init, uses `@Published` setters to write back to `UserDefaults`, and registers for `.playbackStateChanged`.
- `AppSettings` toggles IOKit sleep assertions through `IOPMAssertionCreateWithName`, preventing idle sleep only while music is playing.
- `PlayStatus.loadState()` and `PlaylistStatus` persistence helpers restore the current item, queue, and timing data after relaunch.
- `ContentView` saves sidebar selection and navigation snapshots via `JSONUtils.saveEncodableState`, keeping UI context intact across restarts.

## System Integration
- Sparkle’s updater menu is injected in `MusicBoxApp.commands`, while the controller starts automatically from the app initializer.
- `NowPlayingCenter.handleItemChange` populates `MPNowPlayingInfoCenter` metadata, including async artwork loading through `ImageLoader`.
- `NowPlayingCenter.handlePlaybackChange` and `.handleSetPlaybackState` keep playback positions and rates synchronized with macOS media controls.
- `RemoteCommandCenter.handleRemoteCommands` registers callbacks with `MPRemoteCommandCenter` and delegates execution to the current `PlaylistStatus`.
- `Notification.Name.spaceKeyPressed` and `.playbackStateChanged` serve as the cross-component messaging backbone for shortcuts and sleep control.

## Agent Playbook
- Extend `PlayStatus` for new playback behaviors and invoke `updateCurrentPlaybackInfo()` after mutating state to keep metadata fresh.
- When adding NetEase endpoints, introduce Swift wrappers in `CloudMusicApi`, define deterministic cache keys, and invalidate related entries with `SharedCacheManager`.
- Integrate new UI flows by adding `NavigationScreen` cases and persisting state through `JSONUtils` to preserve navigation on relaunch.
- Reuse `AlertModal` notifications for global messaging instead of new global publishers to keep UX consistent.
- Always nil out `CachingPlayerItem.delegate` before discarding a player item to prevent retain cycles and lingering downloads.

## Testing Checklist
- Exercise login, playlist fetch, lyric sync, and progressive caching flows with and without network connectivity.
- Verify window hide/restore behavior, Sparkle update menu availability, and the global space-bar shortcut on macOS 14 or later.
- Confirm queue persistence by quitting and relaunching after changing loop modes and the “Play Next” stack.
- Profile memory and disk usage while skipping tracks rapidly to ensure `ResourceLoaderDelegate` sessions close and cached files finalize cleanly.

This documentation should be updated as the codebase evolves to capture new patterns and architectural decisions.
