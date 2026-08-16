# AGENTS.md

This guide describes the current MusicBox architecture and the boundaries that
must be preserved when changing the application.

## Project Overview

- MusicBox is a macOS 26+ SwiftUI application for NetEase Cloud Music.
- `MusicBox/MusicBoxApp.swift` starts Sparkle, owns the main-window lifecycle,
  and injects one `AppModel` into the application shell.
- The app uses SwiftUI, Observation, and Swift Concurrency. Do not introduce a
  second state-management framework without a concrete integration need.
- `CloudMusicApi`, `NeteaseHTTPClient`, `NeteasePlaybackClient`, and
  `CachingPlayerItem` retain their native protocol behavior behind the new
  service and playback boundaries.

## Development Workflow

- Open `MusicBox.xcodeproj` in Xcode 17 or newer, then build with `Cmd-B` or
  run with `Cmd-R`.
- Keep `SPUStandardUpdaterController` initialized in `MusicBoxApp` when
  touching startup code.
- Run the complete test suite with:

  ```sh
  xcodebuild -project MusicBox.xcodeproj -scheme MusicBox -configuration Debug test CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM=""
  ```

- The project has no sibling-repository or external C++ build dependency.

## Directory Map

```
MusicBox/
├── App/                     # Composition root, navigation, account, settings, alerts
├── Features/                # Explore, playlist, cloud, login, settings, comments models/views
├── Playback/                # Queue state machine, store, engine, lyrics, player UI
├── Services/                # Repository facade and playback reporting/relay coordinator
├── Shared/                  # Cross-cutting view and Foundation helpers
├── Api/                     # Concrete NetEase HTTP, EAPI, Dawn and relay transports
├── CachingPlayerItem/       # Progressive AVAssetResourceLoader cache implementation
└── Localizable.xcstrings    # English and Simplified Chinese UI strings
```

## Application Architecture

- `AppModel` is the sole composition root. It owns `AccountStore`, `AppRouter`,
  `AlertCenter`, `TransferCenter`, `AppSettings`, `PlaybackStore`,
  `PlaybackReportingCoordinator`, and `SystemPlaybackBridge`.
- `ContentView` lives in `App/AppShellView.swift`. It only renders the
  navigation shell, one floating player capsule, the lyrics inspector, and
  application alerts.
- `AppRouter`, `AlertCenter`, and `TransferCenter` replace app-internal
  `NotificationCenter` communication. Keep `NotificationCenter` only for
  system lifecycle and AVFoundation item notifications.
- Features use `@MainActor @Observable` models. Views call model commands and
  render state; they do not call `CloudMusicApi`, `AVPlayer`, or global
  notifications directly.
- `MusicRepository` is a composition of capability protocols:
  `AccountRepository`, `CatalogRepository`, `CloudRepository`,
  `CommentsRepository`, and `PlaybackResourceServing`. Add endpoints through
  the narrow capability that owns them, then implement it in
  `NeteaseMusicRepository`.
- `PlayerOverlayMetrics` provides the bottom clearance for all shell content.
  Do not add fake table rows, duplicated players, or ad hoc bottom spacers.

## Playback Architecture

- UI and system integrations depend on `PlaybackStore`, not `AVPlayer`.
  `PlaybackState` is read-only to consumers; command methods include
  `replaceSource`, `playNow`, `enqueueNext`, `next`, `previous`, `seek`,
  `removeEntry`, `clearQueue`, and `cycleMode`.
- `AVPlaybackEngine` exclusively owns `AVPlayer`, KVO, seeks, resource changes,
  and `CachingPlayerItemDelegate`. Engine callbacks carry a generation; the
  store discards callbacks from stale requests.
- `AudioSourceResolver` owns local-cache lookup, remote URL resolution, and
  cache destinations. `PlaylistItem` is only a Codable data value and must not
  perform networking or filesystem operations.
- `PlaybackQueue` is a pure state machine. Each `PlaybackQueueEntry` has an
  independent UUID so repeated songs remain distinct.
- The queue keeps source entries, current entry, explicit next entries, real
  history, and shuffle order separately. Explicit next entries are LIFO; a
  batch retains its internal order and is inserted ahead of older next entries.
- Playback modes cycle `repeatAll -> shuffle -> repeatOne -> repeatAll` and
  map to relay values `list_loop`, `random`, and `single_loop`. Natural end in
  repeat-one replays the current entry; manual next still advances.
- Previous uses true playback history first, then the source-list predecessor.
  Never implement a three-second replay shortcut.
- `LyricsController` owns lyric loading, binary timestamp lookup, and precise
  rescheduling. Lyrics views render `LyricsState` only.
- `SystemPlaybackBridge` consumes `PlaybackEvent` for media keys and Now
  Playing metadata. `AppSettings` and `PlaybackReportingCoordinator` also
  subscribe to playback events; they must not inject commands through static
  notifications.

## Persistence and Reporting

- `PlaybackSessionSnapshot` persists the full queue snapshot, playback
  position, and volume under `PlaybackSession.v2`.
- On first run without that key, `PlaybackStore` migrates the old
  `PlaylistStatus` and `PlayStatus` payloads, separating legacy explicit-next
  items and mapping legacy loop modes. Keep the old keys readable for this
  migration only; do not write them.
- `PlaybackReportingCoordinator` owns Dawn outbox delivery, account isolation,
  relay state, handoff offers, retries, and progress restoration. Playback must
  remain responsive if reporting fails.
- Replacing the source, clearing the queue, signing out, or accepting a relay
  handoff clears obsolete queue context before loading the new source.

## API and Cache Boundaries

- `CloudMusicApi` remains the Swift-facing facade for raw NetEase `/api`
  endpoints. `NeteaseHTTPClient` owns form encoding, cookies, caching, retry
  behavior, and concrete paths.
- Desktop EAPI, relay, and Dawn protocols belong to `NeteasePlaybackClient`.
  Add explicit methods, never dynamic endpoint dispatch.
- `CachingPlayerItem` rewrites stream URLs into its resource-loader scheme;
  `ResourceLoaderDelegate` streams and verifies cached ranges. Always clear a
  discarded caching item's delegate.

## Localization and UI

- Add visible UI text, AppKit window/table labels, menu items, tooltips,
  alerts, errors, and count formatting to `Localizable.xcstrings` in both
  English and Simplified Chinese.
- Use system colors, compact spacing, icons for familiar controls, and corner
  radii of 8 pt or less. Preserve the floating player capsule as one shell-level
  instance.
- Test narrow windows at 980 x 600 as well as a wide layout. Check English and
  Simplified Chinese for clipped labels, overlay clearance, and inspector or
  popover overlap.

## Testing Checklist

- Keep `PlaybackQueueTests` deterministic: modes, natural/manual progression,
  explicit-next ordering, history, duplicate tracks, removal, and shuffle.
- Keep `PlaybackStoreTests` independent of network and AVFoundation using the
  injectable resolver, lyrics loader, engine, and `UserDefaults` suite.
  Cover snapshots, legacy migration, stale callbacks, delayed resolution, and
  lyric boundaries.
- Keep feature-model tests focused on loading, retry/error state, pagination,
  debounce, and cancellation with lightweight protocol fakes.
- Keep raw HTTP, Dawn, relay, and handoff tests in
  `NeteaseHTTPClientTests`; verify no pause or same-track seek creates an
  incorrect playback-end record.
- Manually smoke test login, remote/local cache playback, rapid skips, media
  keys, sleep prevention, queue restore, relay handoff, and window hide/restore
  on a macOS 26 host.
