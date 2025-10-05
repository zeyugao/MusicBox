# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MusicBox is a native macOS application built with SwiftUI that provides access to NetEase Music. The app features progressive audio caching, smart lyric synchronization, system integration, and automatic updates via Sparkle framework.

## Development Commands

**Build & Run:**
- Open `MusicBox.xcodeproj` in Xcode
- Build with ⌘+B or run with ⌘+R
- The project requires QCloudMusicApi C++ library (automatically handled by GitHub Actions)

**No traditional package manager:** This is a Swift project using Xcode, not npm/yarn.

## Architecture Overview

**Tech Stack:**
- SwiftUI for UI (macOS 14+ target)
- AVPlayer/AVKit for audio playback
- QCloudMusicApi (C++ library) for NetEase Music API
- Sparkle framework for auto-updates
- IOKit for system sleep prevention
- CryptoKit for MD5 hashing and caching

**Key Directory Structure:**
```
MusicBox/
├── Api/                     # NetEase Music API integration
│   ├── CloudMusicApi.swift  # Swift wrapper for C++ API
│   ├── QCloudMusicApi.h     # C++ library header
│   └── MusicBox-Bridging-Header.h
├── Player/                  # Audio playback engine
│   ├── Player.swift         # Core audio player with smart lyric sync
│   ├── PlaylistItem.swift   # Song metadata model
│   ├── NowPlayingCenter.swift    # macOS media control integration
│   └── RemoteCommandCenter.swift # Remote control handling
├── CachingPlayerItem/       # Progressive download implementation
│   ├── CachingPlayerItem.swift      # AVPlayerItem subclass
│   ├── ResourceLoaderDelegate.swift # HTTP streaming delegate
│   ├── MediaFileHandle.swift        # File I/O management
│   └── CachingPlayerItemConfiguration.swift
├── Component/               # Reusable UI components
│   ├── PlayerControlView.swift     # Bottom player controls
│   ├── PlayingDetailView.swift     # Full-screen player view
│   └── Utils.swift                 # UI utilities
├── Content/                 # Main application views
│   ├── Account.swift        # Login and settings
│   ├── Explore.swift        # Music discovery
│   ├── PlayList.swift       # Playlist management
│   └── CloudFilesView.swift # User's cloud music files
├── Models/                  # Data models
│   ├── AppSettings.swift    # App configuration
│   └── BuildInfo.swift      # Version information
└── General/                 # Shared utilities
    └── Extensions.swift     # Swift extensions
```

## Core Architecture Patterns

**Navigation System:**
- Uses NavigationSplitView with sidebar + NavigationStack pattern
- Navigation state managed through `NavigationScreen` enum (account, explore, playlist, cloudFiles)
- PlayingDetailView overlays via NavigationPath manipulation
- Persistent navigation state with JSON encoding

**State Management:**
- ObservableObject + @Published pattern throughout
- UserDefaults persistence for PlaylistStatus, PlayStatus, and AppSettings
- Notification-based communication between components
- Shared state via environment objects in SwiftUI views

**Audio Playback Architecture:**
- `PlayStatus` class manages AVPlayer and playback state
- `PlaylistStatus` handles queue management and loop modes
- `CachingPlayerItem` enables progressive download while streaming
- Smart lyric synchronization with precise timing
- Integration with macOS Now Playing Center and Remote Command Center

## Key Implementation Details

### Audio System

**Progressive Caching:**
- `CachingPlayerItem` downloads audio files while streaming
- Files cached to system cache directory with UUID naming
- Supports resuming from cached data on subsequent plays
- Local file playback preferred over streaming when available

**Smart Lyric Synchronization:**
- `SmartLyricSynchronizer` class provides precise lyric timing
- Only runs when PlayingDetailView is visible (performance optimization)
- Uses binary search for efficient lyric index lookup
- Dynamic timer scheduling based on next lyric change time

**Playlist Management:**
- Support for sequential, shuffle, and single-track loop modes
- "Play Next" queue functionality with intelligent insertion
- Persistent playlist state across app launches
- Track deletion with smart current item handling

### API Integration

**NetEase Music API:**
- C++ library `QCloudMusicApi` bridged to Swift via `CloudMusicApi.swift`
- Comprehensive caching system with MD5-based keys and TTL expiration
- Support for login (QR code, phone), playlist management, song streaming, cloud files
- Automatic cookie management and session persistence
- Rate limiting and error handling

**Key API Operations:**
- Authentication: QR code login, phone login, session refresh
- Music Discovery: Daily recommendations, search, playlist browsing
- Playback: Song URL resolution, progressive quality selection
- User Data: Playlists, liked songs, cloud files, scrobbling

### System Integration

**macOS Integration:**
- Now Playing Center integration with metadata and playback controls
- Remote Command Center for media key handling
- Global space bar shortcut for play/pause (when not in text fields)
- Sleep prevention during playback (configurable)
- Window management: hide instead of close, dock icon restoration
- Sparkle framework for automatic updates

**App Lifecycle:**
- Custom AppDelegate prevents termination on window close
- Window delegate hides instead of closing main window
- Persistent state saving on app termination
- Background task management for long operations

### UI Architecture

**SwiftUI Patterns:**
- Extensive use of `@StateObject`, `@Published`, and `@EnvironmentObject`
- Custom view modifiers and reusable components
- AsyncImage with caching for album artwork
- Alert system using NotificationCenter for cross-component communication

**Key Views:**
- `ContentView`: Main split view container with sidebar navigation
- `PlayerControlView`: Bottom-anchored playback controls
- `PlayingDetailView`: Full-screen player with lyrics and controls
- Content views: Account, Explore, PlayList, CloudFilesView

## Development Guidelines

### Adding New Features

**Audio Features:**
- Extend `PlayStatus` for playback-related functionality
- Use `PlaylistStatus` for queue management features
- Follow the notification-based architecture for cross-component communication
- Consider caching implications for performance

**UI Features:**
- Follow existing SwiftUI patterns with ObservableObject state management
- Use environment objects for shared state
- Implement proper navigation integration with existing NavigationScreen enum
- Consider accessibility and keyboard navigation

**API Features:**
- Add new endpoints to `CloudMusicApi.swift`
- Follow existing caching patterns for performance
- Handle errors gracefully with user-friendly messages
- Test with various network conditions

### Important Considerations

**Performance:**
- Smart lyric synchronization only runs when detail view is visible
- API responses are cached with configurable TTL
- Image loading uses AsyncImage with built-in caching
- Large playlist operations use background queues

**Memory Management:**
- Proper cleanup in deinit methods
- Weak references to prevent retain cycles
- Cancel long-running tasks on component deallocation
- Clear delegates when replacing player items

**Error Handling:**
- User-friendly error messages via AlertModal system
- Graceful degradation when API calls fail
- Network error recovery and retry logic
- Fallback behaviors for missing data

**Security:**
- Sandboxed execution with specific entitlements
- No hardcoded credentials or API keys
- Cookie-based session management
- Secure file handling for cached content

### Testing Guidelines

**Audio Playback:**
- Test with various audio formats and qualities
- Verify caching behavior with network interruptions
- Check proper cleanup when switching tracks
- Validate lyric synchronization accuracy

**API Integration:**
- Test authentication flows (QR code, phone login)
- Verify proper error handling for API failures
- Check caching behavior and expiration
- Test with various network conditions

**UI Behavior:**
- Verify navigation state persistence
- Test window management (hide/show, dock integration)
- Check accessibility and keyboard shortcuts
- Validate responsive behavior with different window sizes

## Common Patterns and Utilities

**State Persistence:**
- Use JSONUtils for complex state objects with saveEncodableState and loadDecodableState methods
- UserDefaults integration for automatic persistence across app launches

**Notification-Based Communication:**
- Define notification names as extensions to Notification.Name
- Use NotificationCenter for cross-component communication with userInfo dictionaries

**Async API Calls:**
- Follow established CloudMusicApi pattern with configurable cache TTL
- Proper error handling and timeout management

**UI State Management:**
- Use @StateObject for owning state, @ObservedObject for passed state
- Environment objects for shared state across view hierarchy

This documentation should be updated as the codebase evolves to reflect new patterns and architectural decisions.
