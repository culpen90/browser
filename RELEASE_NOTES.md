# Browser v0.2.1

Fixes the agent starting unrelated browser actions after a simple greeting such as `hola`. Updated Mac and Android apps are included.

## Changes

- Recognized greetings, thanks, and help requests receive an immediate reply without reading the page, running the model, or starting browser actions.
- Simple replies work without a downloaded model on Mac or a paired PC on Android.
- Unclear input such as `hmm` receives a response without entering the browser action loop. Home no longer makes web search available merely because it is the current page.
- Page questions, requested navigation, and greetings followed by a browsing task continue to use the agent.

## Downloads

- **Browser-0.2.1-macOS-universal.dmg** — open the disk image and drag Browser to Applications. Requires macOS 13 or later, on Apple silicon or Intel.
- **Browser-0.2.1-macOS-universal.zip** — the same universal Mac app in a ZIP archive.
- **Browser-0.2.1-Android.apk** — install or update Browser on Android 8.0 (API 26) or later. Uses the existing production signing certificate, version code 3, with debugging disabled.
- **SHA256SUMS.txt**, **Android-SHA256SUMS.txt**, and **Android-signature.txt** — package checksums and the public Android signing-certificate report.

The Mac app is ad-hoc signed and is not notarized by Apple. If macOS blocks its first launch, follow [Apple's first-launch instructions](https://support.apple.com/102445).

The model remains a separate download. Android browsing tasks use the local model on a paired Mac; recognized simple replies do not require pairing.
