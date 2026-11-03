#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_BROWSER_SIGNING_PROPERTIES="${ANDROID_BROWSER_SIGNING_PROPERTIES:-$HOME/.local/share/browser-android/release-signing.properties}"
if [ ! -f "$ANDROID_BROWSER_SIGNING_PROPERTIES" ]; then
    echo 'Configure release signing first with scripts/setup-android-signing.sh.' >&2
    exit 1
fi
cd "$ROOT/android"
./gradlew testReleaseUnitTest lintRelease assembleRelease --console=plain
VERSION=$(sed -n "s/.*versionName '\([^']*\)'.*/\1/p" app/build.gradle)
OUTPUT="$ROOT/dist/Browser-$VERSION-Android.apk"
mkdir -p "$ROOT/dist"
cp app/build/outputs/apk/release/app-release.apk "$OUTPUT"
SIGNER="$ANDROID_HOME/build-tools/36.0.0/apksigner"
"$SIGNER" verify --verbose --print-certs "$OUTPUT" > "$ROOT/dist/Android-signature.txt"
"$ANDROID_HOME/build-tools/36.0.0/zipalign" -c -P 16 -v 4 "$OUTPUT" > /dev/null
cd "$ROOT/dist"
shasum -a 256 "Browser-$VERSION-Android.apk" > Android-SHA256SUMS.txt
echo "Signed release APK: $OUTPUT"
