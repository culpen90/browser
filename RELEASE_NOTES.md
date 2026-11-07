# Browser v0.2.0

This release adds AI Agent side panels to the Mac and Android browsers, local model inference on the Mac, and phone pairing so Android can use the Mac's model. Both platforms' downloads are included in this release.

## Downloads

- **Browser-0.2.0-macOS-universal.dmg** — open the disk image and drag Browser to Applications. Requires macOS 13 or later, on Apple silicon or Intel.
- **Browser-0.2.0-macOS-universal.zip** — extract the archive and move Browser to Applications. Includes the same universal Mac app.
- **Browser-0.2.0-Android.apk** — install or update Browser on Android 8.0 (API 26) or later. The APK uses the existing production signing identity and has debugging disabled.
- **SHA256SUMS.txt** — checksums for the Mac DMG and ZIP.
- **Android-SHA256SUMS.txt** and **Android-signature.txt** — the APK checksum and public signing-certificate report.

The Mac app is ad-hoc signed and is not notarized by Apple. If macOS blocks its first launch, open **System Settings → Privacy & Security → Open Anyway** for Browser, then confirm **Open**. See [Apple's first-launch instructions](https://support.apple.com/102445).

## What's new

- Open the **AI Agent** side panel from the Mac toolbar, close it with **×**, or toggle it with **⇧⌘A**. The panel retains its task and results when reopened.
- Run Hugging Face Qwen2/Qwen2.5 GGUF models directly in the Mac app through a Swift/C inference engine. Choose **Download Model** for the default Qwen2.5 0.5B Instruct model, or choose a compatible local GGUF file. The default model is a separate 429 MB download.
- Give the agent a task on the current page. It can read page text, follow links, navigate, scroll, go back, and enable Website Compatibility. The panel includes an activity log, website-action review, and Stop.
- Connect Android to the Mac's model through QR or pairing links. Tasks, page observations, and responses travel in authenticated encrypted messages over the local network.
- Reddit opens in Website Compatibility, using WebKit on Mac and Android System WebView on Android for JavaScript, forms, media, and persistent site storage. Other network pages can be switched manually through the navigation menu.

## Pair your phone

1. Keep your Mac and phone on the same Wi-Fi or local network.
2. On the Mac, open **AI Agent → Model → Connect Phone… → Start Sharing**.
3. Scan the QR code with the phone's camera and open it in Browser, or open **AI → Connect PC** in the Android browser and paste the pairing link.
4. Keep Browser open on the Mac while using the phone's agent. **Stop Sharing** ends the session. Starting sharing again creates a new pairing link.

## Current scope

The local agent has a 2,048-token context and a ten-step task limit. Specific tasks and short relevant page sections work best. Website observations cover the main document, and some sites require manual interaction.

The independent HTML/CSS engine continues to target simple pages. Website Compatibility handles sites that need a full platform engine and requires an installed WebView provider on Android. Tabs, a download manager, and complete independent-engine HTML/CSS support remain outside the current scope.

## Validation

Mac and Android unit tests, encrypted transport checks, universal Mac packaging, and Android signing/alignment checks passed. Android 16 emulator tests exercised website controls, reviews, stale-page rejection, and real phone-to-Mac inference with model-selected navigation. Android 8 native panel tests passed; its website-control checks were skipped because that emulator had no WebView provider. An existing rendering timing test passed on an isolated rerun after concurrent build and emulator startup load stopped.
