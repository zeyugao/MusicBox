#!/bin/bash

# Script to download, install, and cleanup MusicBox nightly release
# Usage: ./update.sh

set -e # Exit on any error

# --- Version Check ---
APP_PATH="/Applications/MusicBox.app"
LOCAL_COMMIT_SHA=""

if [ -d "$APP_PATH" ]; then
    echo "Found existing MusicBox.app, checking version..."
    # Format is build_number-short_sha, e.g., 123-a1b2c3d4
    VERSION_STRING=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo "")
    if [ -n "$VERSION_STRING" ] && [[ "$VERSION_STRING" == *-* ]]; then
        LOCAL_COMMIT_SHA=$(echo "$VERSION_STRING" | cut -d'-' -f2)
    else
        echo "Could not determine local version from '$VERSION_STRING'. Proceeding with update."
    fi
fi

# Get remote commit SHA from the 'nightly' release notes on GitHub
echo "Fetching remote version information..."
REMOTE_INFO=$(curl -s "https://api.github.com/repos/zeyugao/MusicBox/releases/tags/nightly")
REMOTE_COMMIT_SHA=$(echo "$REMOTE_INFO" | grep 'Nightly build from commit' | sed -E 's/.*Nightly build from commit ([0-9a-f]{40}).*/\1/')

if [ -z "$REMOTE_COMMIT_SHA" ]; then
    echo "Warning: Could not determine remote commit SHA. Proceeding with update."
    echo "Response: $REMOTE_INFO"
else
    # Compare versions if we have both local and remote SHAs
    if [ -n "$LOCAL_COMMIT_SHA" ]; then
        echo "Local short commit:  $LOCAL_COMMIT_SHA"
        echo "Remote full commit: $REMOTE_COMMIT_SHA"
        # Check if the full remote SHA starts with the local short SHA
        if [[ "$REMOTE_COMMIT_SHA" == "$LOCAL_COMMIT_SHA"* ]]; then
            echo "✅ You are already on the latest version."
            exit 0
        else
            echo "A new version is available. Proceeding with update..."
        fi
    fi
fi
# --- End Version Check ---

ORIGINAL_DIR="$(pwd)"
cd "$(dirname "$0")" || exit 1

echo "Starting MusicBox update process..."

# Create temporary directory
TEMP_DIR=$(mktemp -d)
echo "Using temporary directory: $TEMP_DIR"

# Cleanup function
cleanup() {
    echo "Cleaning up temporary files..."
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
        echo "Temporary directory $TEMP_DIR has been cleaned up."
    fi
}

# Set trap to cleanup on exit (including errors)
trap cleanup EXIT

# Define variables
DOWNLOAD_URL="https://github.com/zeyugao/MusicBox/releases/download/nightly/MusicBox.tar.gz"
ARCHIVE_FILE="$TEMP_DIR/MusicBox.tar.gz"
EXTRACT_DIR="$TEMP_DIR/MusicBox_temp"

# Download the archive
echo "Downloading MusicBox.tar.gz..."
curl -L -o "$ARCHIVE_FILE" "$DOWNLOAD_URL"

if [ ! -f "$ARCHIVE_FILE" ]; then
    echo "Error: Failed to download $ARCHIVE_FILE"
    exit 1
fi

echo "Download completed successfully."

# Create temporary directory and extract
echo "Extracting archive..."
mkdir -p "$EXTRACT_DIR"
tar -xzf "$ARCHIVE_FILE" -C "$EXTRACT_DIR"

# Find and execute install.sh
INSTALL_SCRIPT=$(find "$EXTRACT_DIR" -name "install.sh" -type f | head -1)

if [ -z "$INSTALL_SCRIPT" ]; then
    echo "Error: install.sh not found in the extracted files"
    exit 1
fi

echo "Found install script at: $INSTALL_SCRIPT"
echo "Executing install.sh..."

# Make install.sh executable and run it
chmod +x "$INSTALL_SCRIPT"
cd "$(dirname "$INSTALL_SCRIPT")"
./install.sh

# Return to original directory
cd "$ORIGINAL_DIR" >/dev/null

echo "MusicBox update completed successfully!"
