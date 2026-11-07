# Browser for Android v0.2.0

The Android APK is included alongside the Mac app in the [Browser v0.2.0 release](https://github.com/culpen90/browser/releases/tag/v0.2.0).

## Install

Requires **Android 8.0 (API 26) or later**. Download **Browser-0.2.0-Android.apk**, open it, and allow installation from your browser or file manager if prompted. It updates the previous production release using the same signing certificate. Version code is 2 and debugging is disabled.

The release includes **Android-SHA256SUMS.txt** and **Android-signature.txt**. The production certificate SHA-256 fingerprint is

```text
d0e2ce47b1e6492ab974a35f7de0a9c61c1b14e45a88ddf84e110f649ca7da2e
```

## What's new

- An **AI** toolbar button opens the agent side panel. Close it with **×** and reopen it to return to the task and results.
- QR and pairing links connect the agent to the local model running in Browser on your Mac. Open **AI → Connect PC** to paste a link, or scan the Mac's QR code with the phone camera.
- Encrypted model requests and responses, saved pairing, activity/results, website-action review, and Stop.
- The phone can read pages, follow links, navigate, scroll, and operate reviewed website controls while the Mac performs inference.
- Reddit uses Website Compatibility for JavaScript, forms, media, and persistent website storage. An installed Android System WebView provider is required for this mode.

## Connect the Mac's model

Keep both devices on the same Wi-Fi or local network. In the Mac's agent panel, choose **Model → Connect Phone… → Start Sharing**. Pair the Android browser and keep desktop Browser open while running tasks. **Stop Sharing** ends the session; a new sharing session has a new pairing link.

## Validation and scope

Debug and release unit tests passed, 37 each, along with lint, release shrinking, signature, and alignment checks. Android 16 emulator testing covered native and website agent controls and real model-selected navigation through the Mac. Android 8 native panel tests passed; its website-control tests were skipped because the emulator had no WebView provider. An existing rendering timing test passed on an isolated rerun after build and emulator startup load stopped.

The independent engine supports a subset of HTML/CSS. Tabs and a download manager are outside the current scope. The agent uses a 2,048-token context and a ten-step task limit.
