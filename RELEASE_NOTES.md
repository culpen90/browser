# Browser v0.2.2

Adds a visible **Connect Phone…** button beside Run and Stop in the Mac's agent panel, so phone pairing is easy to find.

## Changes

- Open **AI Agent** in the Mac browser's toolbar, click **Connect Phone…**, then choose **Start Sharing** to show the pairing QR code and link.
- The button opens the existing encrypted pairing flow and remains available while using the agent. The Model menu shortcut remains available.
- Updated the README and the Mac download's installation instructions to use the visible button.
- The Android app's behavior is unchanged from v0.2.1; its version advances to v0.2.2 for this coordinated release. Both platforms retain the greeting and unclear-input fixes from v0.2.1.

## Downloads

- **Browser-0.2.2-macOS-universal.dmg** — open the disk image and drag Browser to Applications. Requires macOS 13 or later, on Apple silicon or Intel.
- **Browser-0.2.2-macOS-universal.zip** — the same universal Mac app in a ZIP archive.
- **Browser-0.2.2-Android.apk** — install or update Browser on Android 8.0 (API 26) or later. Uses the existing production signing certificate, version code 4, with debugging disabled.
- **SHA256SUMS.txt**, **Android-SHA256SUMS.txt**, and **Android-signature.txt** — package checksums and the public Android signing-certificate report.

The Mac app is ad-hoc signed and is not notarized by Apple. If macOS blocks its first launch, follow [Apple's first-launch instructions](https://support.apple.com/102445).

The model remains a separate download. Android browsing tasks use the local model on a paired Mac; recognized simple replies do not require pairing. Keep both devices on the same local network and desktop Browser open while sharing.
