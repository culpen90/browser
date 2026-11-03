#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
./scripts/build-app.sh
browser_destination="$HOME/Applications/Browser.app"
if [[ -e "$browser_destination" ]]; then
    browser_existing_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$browser_destination/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$browser_existing_id" != 'local.browser.foundation' ]]; then
        print -u2 "Another app already exists at $browser_destination; it has been left unchanged."
        exit 1
    fi
fi
mkdir -p "$HOME/Applications"
ditto --norsrc --noextattr dist/Browser.app "$browser_destination"
xattr -cr "$browser_destination"
codesign --force --sign - "$browser_destination"
codesign --verify --strict "$browser_destination"
print "Installed: $browser_destination"
