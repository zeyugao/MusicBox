#!/bin/bash

# Script to download, install, and cleanup MusicBox nightly release
# Usage: ./update.sh

set -e # Exit on any error

cd "$(dirname "$0")" || exit 1

echo "Starting MusicBox update process..."

# Define variables
DOWNLOAD_URL="https://github.com/zeyugao/MusicBox/releases/download/nightly/MusicBox.tar.gz"
ARCHIVE_FILE="MusicBox.tar.gz"
EXTRACT_DIR="MusicBox_temp"

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
    # Cleanup on error
    rm -rf "$EXTRACT_DIR"
    rm -f "$ARCHIVE_FILE"
    exit 1
fi

echo "Found install script at: $INSTALL_SCRIPT"
echo "Executing install.sh..."

# Make install.sh executable and run it
chmod +x "$INSTALL_SCRIPT"
cd "$(dirname "$INSTALL_SCRIPT")"
./install.sh

# Return to original directory
cd - >/dev/null

# Cleanup
echo "Cleaning up temporary files..."
rm -rf "$EXTRACT_DIR"
rm -f "$ARCHIVE_FILE"

echo "MusicBox update completed successfully!"
echo "Temporary files have been cleaned up."
