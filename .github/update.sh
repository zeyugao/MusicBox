#!/bin/bash

# Script to download, install, and cleanup MusicBox nightly release
# Usage: ./update.sh

set -e # Exit on any error

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
