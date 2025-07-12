# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MusicBox is a native macOS application built with SwiftUI that provides access to NetEase Music. The app features audio caching, spatial audio support, and automatic updates via Sparkle framework.

## Development Commands

**Build & Run:**
- Open `MusicBox.xcodeproj` in Xcode
- Build with ⌘+B or run with ⌘+R
- The project requires QCloudMusicApi C++ library (automatically handled by GitHub Actions)

**No traditional package manager:** This is a Swift project using Xcode, not npm/yarn.

## Architecture

**Tech Stack:**
- SwiftUI for UI (macOS 14+ target)
- AVPlayer/AVKit for audio playback
- QCloudMusicApi (C++ library) for NetEase Music API
- Sparkle framework for auto-updates

**Key Structure:**
```
MusicBox/
├── Api/                     # NetEase Music API integration
├── Player/                  # Audio playback engine with caching
├── Component/               # Reusable UI components  
├── Content/                 # Main app views (NowPlaying, Explore, etc.)
├── CachingPlayerItem/       # Progressive audio download implementation
└── General/                 # Shared utilities and extensions
```

**Navigation:** Uses NavigationSplitView with sidebar + NavigationStack pattern. Navigation state managed through NavigationScreen enum.

**State Management:** ObservableObject + @Published pattern with UserDefaults persistence for app state.

**Audio Architecture:** Custom CachingPlayerItem wraps AVPlayer for progressive download and caching. Integrates with macOS Now Playing Center and Remote Command Center.

## Important Implementation Details

**C++ Bridge:** Swift interfaces with QCloudMusicApi through bridging header (`QCloudMusicApi.h`). API calls wrapped in `CloudMusicApi.swift`.

**Security:** App runs in sandbox with specific entitlements for network access and music library permissions.

**Build Process:** GitHub Actions handles dependency fetching and multi-architecture builds. Manual builds require QCloudMusicApi library setup.

**Update System:** Sparkle framework with feed at `https://musicbox.elsanna.me/appcast.xml`.
