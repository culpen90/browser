#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
browser_universal=false
case "${1:-}" in
    --universal) browser_universal=true ;;
    '') ;;
    *) print -u2 'Usage: ./scripts/build-app.sh [--universal]'; exit 1 ;;
esac
if (( $# > 1 )); then
    print -u2 'Usage: ./scripts/build-app.sh [--universal]'
    exit 1
fi
browser_stage="$(mktemp -d -t browser-build)"
trap 'rm -rf "$browser_stage"' EXIT
browser_app="$browser_stage/Browser.app"
mkdir -p "$browser_app/Contents/MacOS" "$browser_app/Contents/Resources"
if $browser_universal; then
    for browser_arch in arm64 x86_64; do
        browser_options=(-c release --product Browser --triple "${browser_arch}-apple-macosx13.0" --scratch-path ".build/release-${browser_arch}")
        swift build "${browser_options[@]}"
        browser_bin_dir="$(swift build "${browser_options[@]}" --show-bin-path)"
        cp "$browser_bin_dir/Browser" "$browser_stage/Browser-${browser_arch}"
    done
    lipo -create "$browser_stage/Browser-arm64" "$browser_stage/Browser-x86_64" -output "$browser_app/Contents/MacOS/Browser"
    for browser_arch in arm64 x86_64; do
        lipo "$browser_app/Contents/MacOS/Browser" -verify_arch "$browser_arch"
    done
else
    swift build -c release --product Browser
    browser_bin_dir="$(swift build -c release --show-bin-path)"
    cp "$browser_bin_dir/Browser" "$browser_app/Contents/MacOS/Browser"
fi
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
# Replace the generated bundle instead of merging it with an older build.
rm -rf dist/Browser.app
ditto --norsrc --noextattr "$browser_app" "$PWD/dist/Browser.app"
ditto -c -k --keepParent --norsrc --noextattr "$browser_app" "$PWD/dist/Browser.zip"
print "Built: $PWD/dist/Browser.app"
