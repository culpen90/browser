# Browser for Android v0.1.0

The first Android release of Browser brings the independent HTML/CSS engine to native Android controls and Canvas drawing. The existing macOS app and its v0.1.0 release remain available separately.

## Install

Requires **Android 8.0 (API 26) or later**. Download **`Browser-0.1.0-Android.apk`**, open it, and allow installation from your browser or file manager if prompted. The universal APK works across CPU architectures.

This is an optimized, production-signed release APK with debugging disabled. The stable release identity is used for future updates; no debug key is used. `Android-SHA256SUMS.txt` verifies the download, and `Android-signature.txt` reports the public signing certificate. Certificate SHA-256:

```text
d0e2ce47b1e6492ab974a35f7de0a9c61c1b14e45a88ddf84e110f649ca7da2e
```

## Included

- Native address entry, Back/Forward, Android back navigation, Home, Reload/Stop, and load feedback.
- HTTP/HTTPS, redirects, relative links, fragment anchors, and HTML/text documents opened through Android's document picker.
- Independent HTML parsing, CSS cascade and selectors, block/inline layout, wrapping, lists, images, preformatted text, and colors.
- Touch and keyboard links, TalkBack page text/link actions, text/address copying, scrolling, and width reflow.
- Offline sample pages, bounded network/parser/rendering work, cancellation, and in-memory history and cookies.
- Separate debug/release application IDs and documented signing/build commands. The private signing identity stays outside the repository.

## Engine scope

This production-signed package contains the same **early engine foundation** as the macOS app. It targets simple pages with server-rendered text and links. JavaScript, interactive forms, tabs, downloads, full HTML/CSS behavior, and persistent browsing data are not implemented. Flex, grid, and tables flow as blocks. Websites that depend on those features will be incomplete.

Chosen local files support inline styles and network resources. Relative companion files are unavailable through the document picker. History survives Activity recreation; cookies reset when its loader is recreated. Large pages may show a display-limit notice when bounded rendering work is exhausted.

There is no WebView, Chromium, WebKit, system HTML importer, analytics, or third-party runtime dependency.

## Verification

- 32 Android unit tests passed for both debug and release configurations; debug and release lint passed.
- All 10 instrumentation tests passed against the optimized signed release APK on **Android 8.0/API 26** and **Android 16/API 36** emulators. Tests cover navigation/history/restoration, relative and fragment links, HTTP loading and cancellation, error recovery, reflow, images/colors, accessibility actions, and rendering work limits.
- The existing 27 macOS tests passed. No macOS application source or packaging scripts were changed.
- APK signature and ZIP alignment were verified. Testing used emulators only.

See the [README](https://github.com/culpen90/browser#readme) for installation and source builds. Android uses `android-v*` release tags independently of macOS.
