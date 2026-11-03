# Browser v0.1.0

The first public release of Browser, a native macOS app with an independent HTML/CSS engine written in Swift.

## Download and install

Requires **macOS 13 or later**. Both packages include a universal `Browser.app` for **Apple silicon and Intel**. No Xcode or developer account is needed to run it.

- **`Browser-0.1.0-macOS-universal.dmg`**: open the disk image and drag Browser to Applications.
- **`Browser-0.1.0-macOS-universal.zip`**: extract the archive and move Browser to Applications.
- **`SHA256SUMS.txt`**: SHA-256 checksums for both packages.

Open Browser from Applications. This release is **ad-hoc signed and not notarized by Apple**, so macOS may block the first launch. After attempting to open it, go to **System Settings → Privacy & Security → Open Anyway** for Browser, then confirm **Open**. See [Apple's instructions](https://support.apple.com/102445). No paid Apple Developer membership is used.

## Included

- A native window, address bar, Back/Forward, Home, Reload/Stop, menus, and keyboard shortcuts.
- HTTP/HTTPS and local HTML/text pages, redirects, relative links, and fragment navigation.
- Custom HTML parsing, a supported CSS subset, block and inline layout, images, and text rendering through AppKit.
- Accessible page text and link actions, text copying, scrolling, and reflow when resizing.
- Bounded document/resource loading and in-memory history, cookies, and cache.

## Current limits

This is an early browser engine foundation aimed at simple pages with server-rendered text and links. It does not yet support JavaScript, interactive forms, tabs, downloads, persistent browsing data, or full HTML/CSS behavior. Flex, grid, and table content currently flows as blocks. Many modern websites will not render or function fully.

The app uses no WebKit, Chromium, web view, or third-party packages. See the [README](https://github.com/culpen90/browser#readme) for the supported features, engine limits, source build instructions, and shortcuts.
