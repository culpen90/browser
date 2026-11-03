#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
swift build -c release
browser_bin_dir="$(swift build -c release --show-bin-path)"
browser_stage="$(mktemp -d -t browser-build)"
trap 'rm -rf "$browser_stage"' EXIT
browser_app="$browser_stage/Browser.app"
mkdir -p "$browser_app/Contents/MacOS" "$browser_app/Contents/Resources"
cp "$browser_bin_dir/Browser" "$browser_app/Contents/MacOS/Browser"
cp Resources/Info.plist "$browser_app/Contents/Info.plist"
if [[ ! -f Resources/Browser.icns ]]; then
    swift scripts/make-icon.swift
    iconutil -c icns .build/Browser.iconset -o Resources/Browser.icns
fi
cp Resources/Browser.icns "$browser_app/Contents/Resources/Browser.icns"
xattr -cr "$browser_app"
codesign --force --sign - "$browser_app"
codesign --verify --strict "$browser_app"
mkdir -p dist
ditto --norsrc --noextattr "$browser_app" "$PWD/dist/Browser.app"
ditto -c -k --keepParent --norsrc --noextattr "$browser_app" "$PWD/dist/Browser.zip"
print "Built: $PWD/dist/Browser.app"
