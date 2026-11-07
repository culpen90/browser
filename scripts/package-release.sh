#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

browser_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
if [[ ! "$browser_version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    print -u2 'CFBundleShortVersionString must be a three-part release version.'
    exit 1
fi
./scripts/build-app.sh --universal
browser_release="Browser-${browser_version}-macOS-universal"
browser_stage="$(mktemp -d -t browser-release)"
trap 'rm -rf "$browser_stage"' EXIT
mkdir -p "$browser_stage/disk"
ditto --norsrc --noextattr dist/Browser.app "$browser_stage/disk/Browser.app"
ln -s /Applications "$browser_stage/disk/Applications"
cat > "$browser_stage/disk/Read Me.txt" <<'EOF'
Browser for macOS 13 or later (Apple Silicon and Intel)

Drag Browser.app to Applications, then open it from Applications.

This app is ad-hoc signed and is not notarized by Apple. If macOS blocks
the first launch, open System Settings > Privacy & Security > Open Anyway,
then confirm Open. Only do this for the app you downloaded from our releases.
Apple's instructions: https://support.apple.com/102445

Click AI Agent in the toolbar to open the side panel. Close it with its X
button or toggle it with Shift-Command-A. Choose Download Model to install
the default local model, or choose a compatible Qwen GGUF file.
To connect Android, click Connect Phone beside Run and Stop in the panel,
then choose Start Sharing and scan the QR code or paste the pairing link
on your phone.
Keep Browser open on this Mac and both devices on the same local network.

Reddit opens in Website Compatibility, which supports JavaScript and forms.
Use Navigate > Website Compatibility to switch engines for other websites.
The independent engine supports basic HTML and CSS. The app has no tabs
or download manager.

Source and releases: https://github.com/culpen90/browser
EOF
codesign --verify --strict "$browser_stage/disk/Browser.app"
cp dist/Browser.zip "$browser_stage/${browser_release}.zip"
hdiutil create -quiet -volname "Browser ${browser_version}" -srcfolder "$browser_stage/disk" -format UDZO "$browser_stage/${browser_release}.dmg"
hdiutil verify -quiet "$browser_stage/${browser_release}.dmg"

# Validate the copy users will extract, not only the app before archiving.
ditto -x -k "$browser_stage/${browser_release}.zip" "$browser_stage/extracted"
codesign --verify --strict "$browser_stage/extracted/Browser.app"
for browser_arch in arm64 x86_64; do
    lipo "$browser_stage/extracted/Browser.app/Contents/MacOS/Browser" -verify_arch "$browser_arch"
done
plutil -lint "$browser_stage/extracted/Browser.app/Contents/Info.plist"
cp "$browser_stage/${browser_release}.zip" "$browser_stage/${browser_release}.dmg" dist/
(
    cd dist
    shasum -a 256 "${browser_release}.zip" "${browser_release}.dmg" > SHA256SUMS.txt
    shasum -a 256 -c SHA256SUMS.txt
)
print "Release files: $PWD/dist/${browser_release}.{zip,dmg} and SHA256SUMS.txt"
