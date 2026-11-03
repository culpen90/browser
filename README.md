# Browser

A native browser foundation for macOS and Android with an independent HTML/CSS engine and no third-party runtime dependencies.

The engine parses HTML into a document tree, computes a supported subset of CSS, lays out blocks and inline text, and produces its own display list. AppKit draws that display list and supplies the native window and controls. Foundation supplies HTTP, HTTPS, file access, and TLS. There is no WebKit, Chromium, web view, or system HTML importer.

The macOS implementation remains in `Sources` and uses Swift/AppKit. The Android port lives in `android` and uses Java, native Android controls, Canvas drawing, and platform HTTP/TLS and image APIs. Both versions share the same early engine scope. The Mac build and its release remain available independently.

## Android download and install

[Download Browser for Android v0.1.0](https://github.com/culpen90/browser/releases/tag/android-v0.1.0). Choose **`Browser-0.1.0-Android.apk`**. Requires **Android 8.0 (API 26) or later**; one APK supports phones and tablets across CPU architectures. It is a signed, optimized release build with debugging disabled.

Open the downloaded APK and allow your browser or file manager to install apps if Android asks. Future APK updates must be signed with the same release key. The release includes `Android-SHA256SUMS.txt` and the public signing-certificate fingerprint in `Android-signature.txt`.

Android provides an address bar, Back/Forward, Home, Reload/Stop, scrolling, touch and keyboard links, TalkBack page text/link actions, and a menu for opening HTML/text files through Android's document picker or copying page text/address. The bundled sample page works offline. Chosen local documents currently support inline CSS and network resources; relative companion files are unavailable through the document picker.

This is a production-signed package of the **early browser foundation**, with the same broad limits as the Mac app: no JavaScript, interactive forms, tabs, downloads, or complete CSS layout. Use it for simple text-and-link pages. History stays in memory and is restored across Activity recreation; cookies are in memory and reset when the Activity's loader is recreated. No analytics or account service is included.

### Build Android from source

Install JDK 21, Android SDK platform 36, and build-tools 36.0.0. Set `JAVA_HOME` and `ANDROID_HOME`, then:

```sh
cd android
./gradlew testDebugUnitTest lintDebug assembleDebug
```

Open the `android` folder in Android Studio, or install `android/app/build/outputs/apk/debug/app-debug.apk` on an emulator. Debug builds use a separate application ID (`com.culpen.browser.debug`) and can coexist with the release app (`com.culpen.browser`). The application itself has no third-party dependencies; Gradle, the Android build plugin, JUnit, and AndroidX Test are build/test dependencies.

To test on an **emulator only**, select its serial explicitly:

```sh
cd android
ANDROID_SERIAL=emulator-5580 ./gradlew connectedDebugAndroidTest
```

For release signing, generate a dedicated identity **once** using `./scripts/setup-android-signing.sh`. It writes the keystore and password properties outside the checkout at `~/.local/share/browser-android/` with private file permissions. Back up both files securely; losing them prevents compatible updates. Build the signed APK with:

```sh
./scripts/package-android-release.sh
```

Set `ANDROID_BROWSER_SIGNING_PROPERTIES` to use a different private properties file (keys: `storeFile`, `storePassword`, `keyAlias`, `keyPassword`). An unconfigured Gradle release is unsigned; the packaging script requires release signing and verifies the APK signature and alignment. It writes the APK, checksum, and public signature report into `dist`. Never commit the signing files or include them in a release.

To run the instrumentation suite against that optimized release on an emulator:

```sh
cd android
ANDROID_BROWSER_SIGNING_PROPERTIES="$HOME/.local/share/browser-android/release-signing.properties" \
ANDROID_SERIAL=emulator-5580 ./gradlew -PtestRelease connectedReleaseAndroidTest
```

Android releases use separate `android-v*` tags. Publishing remains manual; Android CI runs unit tests, lint, and compiles the app/instrumentation APKs, while the existing macOS CI continues to test and package the Mac app.

## Download and install

[Download Browser v0.1.0 for macOS](https://github.com/culpen90/browser/releases/tag/v0.1.0). The release includes a real `Browser.app` for macOS 13 or later, with both Apple silicon and Intel support. Xcode and a developer account are not required to run it.

1. Download `Browser-0.1.0-macOS-universal.dmg`, open it, and drag `Browser.app` to Applications. Alternatively, download and extract `Browser-0.1.0-macOS-universal.zip`, then move `Browser.app` to Applications.
2. Open Browser from Applications.
3. If macOS blocks the first launch because it cannot verify the developer, open **System Settings → Privacy & Security**, click **Open Anyway** for Browser, and confirm **Open**. See [Apple's first-launch instructions](https://support.apple.com/102445).

This release is ad-hoc signed and is not notarized by Apple. It does not use a paid Apple Developer membership. Ad-hoc signing checks the bundle's integrity but does not establish a verified developer identity.

This is an early engine foundation. Text and links on simple pages are the current target; JavaScript, interactive forms, and tabs are not implemented. Read the [engine boundaries](#engine-boundaries) before relying on it for everyday browsing.

The release provides `SHA256SUMS.txt` to check the downloaded packages. With both the DMG and ZIP beside that file, run:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

## Build and open from source

Requirements for source builds: macOS 13 or later and Xcode's Swift toolchain (Swift 6 or later).

Clone the repository, build, and install the app locally:

```sh
git clone https://github.com/culpen90/browser.git
cd browser
./scripts/install-app.sh
open ~/Applications/Browser.app
```

The install script creates `~/Applications/Browser.app`, `dist/Browser.app`, and a portable `dist/Browser.zip`. Build outputs are excluded from the repository. Local builds target the architecture of the Mac used to build them and are ad-hoc signed.

## Develop

From the checkout:

```sh
swift run Browser
swift test
./scripts/build-app.sh
./scripts/install-app.sh
```

Open `Package.swift` in Xcode to work on the project. `scripts/build-app.sh` creates the release app and ZIP in `dist`; `scripts/install-app.sh` also installs it in your user Applications folder. Quit Browser before reinstalling. No package downloads are required. To launch with a document:

```sh
swift run Browser Fixtures/index.html
open dist/Browser.app --args https://example.com
```

To build the app for both Apple silicon and Intel, use `./scripts/build-app.sh --universal`. To create the versioned universal ZIP, DMG, and SHA-256 checksums used for a GitHub release, run:

```sh
./scripts/package-release.sh
```

Releases are published manually. GitHub Actions runs tests on Apple silicon and Intel and checks universal packaging; it does not create tags or publish releases.

For synced Documents folders, use the installed app or the ZIP: file-provider metadata can invalidate a loose app bundle's signature after the build. Packaging uses a temporary folder outside the synced workspace before signing.

## Current foundation

- Native address bar, Back, Forward, Home, Reload/Stop, menus, and load feedback.
- HTTP/HTTPS documents, redirects, relative URLs, fragment links, local HTML/text files, and plain-text responses.
- A custom tokenizer and tree builder, quoted attributes, common character references, raw-text handling, and recovery for several omitted end tags.
- CSS tag, class, ID, descendant, child, comma, `:root`, and link selectors; cascade order, specificity, `!important`, inline styles, and inheritance.
- Text sizes, weights, italics, monospace, underlining, colors, backgrounds, vertical margins, uniform padding, and preformatted text.
- Block flow, inline whitespace collapsing, word wrapping, headings, lists, rules, images, and scrolling with reflow on resize.
- Mouse and keyboard links, accessible page text/link actions, and Copy Page Text/Copy Link commands.
- Bounded document/resource loading and parser/layout work. Cancellation prevents an old request from replacing a later navigation. Remote pages cannot load local file subresources.

## Engine boundaries

This is the starting foundation for an independent engine. It does not yet implement JavaScript, interactive forms, tabs, downloads, persistent browsing data, full HTML tree-construction rules, or the full CSS box model. Flex/grid/table layout currently flows as blocks. Images use system image decoders; CSS image sizing and SVG document rendering are not implemented. External stylesheets use UTF-8, and CSS `@import`/media queries are not interpreted.

Pages with server-rendered text and links are the current target. Sites that depend on JavaScript or advanced layout will need the next engine layers.

Limits currently include 5 MB per document, 1 MB per external stylesheet, 8 MB per image resource, 16 style sources, 24 unique images, 80,000 parsed nodes, 256 levels of nesting, and 40,000 display items. Resources load in batches of four. The HTTP session keeps its cookies/cache in memory for the life of the app; browser history is also in memory.

## Shortcuts

| Action | Shortcut |
| --- | --- |
| Address | ⌘L |
| Open file | ⌘O |
| Back / Forward | ⌘[ / ⌘] |
| Reload | ⌘R |
| Stop | Esc |
| Home | ⇧⌘H |
| Focus a page link / Follow | Tab / Return |
| Scroll page | Arrows, Page Up/Down, Space |

## Verify with local pages

`Fixtures/index.html` exercises external CSS, inline formatting, entities, nested lists, image loading/fallback, relative links, anchors, preformatted text, and wrapping. Open it with ⌘O, or serve it locally:

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory Fixtures
```

Then visit `http://127.0.0.1:8765/index.html`. The test suite covers parsing, the CSS cascade and selector ancestry, URL/history behavior, file/HTTP loading, encodings, load limits, custom layout, link hit areas, image scaling, color conversion, and remote/local resource boundaries.

## Source map

| File | Responsibility |
| --- | --- |
| `Sources/BrowserCore/HTML.swift` | HTML tokenizer, document tree, entities |
| `Sources/BrowserCore/CSS.swift` | CSS parser, selectors, cascade, computed styles |
| `Sources/BrowserCore/PageLoader.swift` | Bounded network/file transport and decoding |
| `Sources/BrowserCore/Navigation.swift` | Address resolution and history |
| `Sources/BrowserApp/PageCanvas.swift` | Layout, display list, drawing, hit testing, accessibility |
| `Sources/BrowserApp/BrowserWindow.swift` | Native UI and navigation orchestration |
| `Sources/BrowserApp/main.swift` | Application lifecycle and menus |
