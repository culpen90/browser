# Browser for Android v0.2.2

Included in the [Browser v0.2.2 release](https://github.com/culpen90/browser/releases/tag/v0.2.2).

## Changes

- The Mac companion app now shows **Connect Phone…** beside Run and Stop in its AI Agent panel. Click it, then choose **Start Sharing** to pair Android.
- Android's pairing and agent behavior are unchanged in this release.
- Retains the v0.2.1 fix: recognized greetings such as `hola`, thanks, and help requests receive an immediate reply without reading the page, contacting the Mac, or starting browser actions. Unclear input cannot enter the browser action loop.

## Install

Requires **Android 8.0 (API 26) or later**. Download **Browser-0.2.2-Android.apk** and open it to install or update Browser. Version code is 4; debugging is disabled. The APK uses the same production signing identity as previous releases.

The release includes **Android-SHA256SUMS.txt** and **Android-signature.txt**. The production certificate SHA-256 fingerprint is:

```text
d0e2ce47b1e6492ab974a35f7de0a9c61c1b14e45a88ddf84e110f649ca7da2e
```

Browsing tasks use the local model running in Browser on a paired Mac. Keep both devices on the same local network and the Mac's sharing session open. Simple recognized replies do not require that connection.
