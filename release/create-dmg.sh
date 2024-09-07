#!/bin/bash

set -ex

cd "$( dirname "${BASH_SOURCE[0]}" )/.." || exit 1

xcodebuild archive -project MusicBox.xcodeproj -scheme MusicBox -archivePath MusicBox ONLY_ACTIVE_ARCH=NO

cd release
rm -f *.dmg
hdiutil create -size 200m -fs APFS -volname "MusicBox" -o MusicBox-tmp.dmg
hdiutil attach MusicBox-tmp.dmg -noverify -mountpoint /Volumes/MusicBox

cp -r ../musicbox.xcarchive/Products/Applications/MusicBox.app /Volumes/MusicBox/
ln -s /Applications /Volumes/MusicBox/Applications

osascript layout.scpt

hdiutil detach /Volumes/MusicBox
hdiutil convert MusicBox-tmp.dmg -format UDZO -o MusicBox.dmg

rm MusicBox-tmp.dmg
cd ..
rm -r MusicBox.xcarchive
