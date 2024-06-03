tell application "Finder"
    tell disk "MusicBox"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set the bounds of container window to {100, 100, 600, 400}
        set icon size of icon view options of container window to 72
        set arrangement of icon view options of container window to not arranged
        set position of item "MusicBox.app" of container window to {150, 100}
        set position of item "Applications" of container window to {350, 100}
        update without registering applications
        delay 1
        close
    end tell
end tell
