# Browser

A native browser for macOS and Android with an independent HTML/CSS engine, a website compatibility mode for Reddit, and an AI Agent side panel.

The default engine parses HTML into a document tree, computes a supported subset of CSS, lays out blocks and inline text, and produces its own display list. AppKit draws that display list and supplies the native window and controls. Foundation supplies HTTP, HTTPS, file access, and TLS. This renderer uses no system HTML importer.

Browser automatically opens Reddit in a full website compatibility view: WebKit on macOS and Android System WebView on Android. These platform engines provide JavaScript, modern layout, editable forms, media, and persistent website storage for Reddit's normal login and interactive pages. Links and authentication redirects stay in the same website session. Entering an unrelated address or opening Home returns to the independent engine. To switch the current network page manually, use **Navigate → Website Compatibility** on Mac, or **Use full website** in the Android menu.

Compatibility sessions keep website cookies and storage on this device between launches. They do not share cookies with the independent engine or other installed browsers. Certificate validation stays enabled, and remote pages cannot navigate to local files or arbitrary app schemes. Some identity providers restrict embedded-browser sign-in; use a sign-in method Reddit offers in this browser. Website CAPTCHA or account verification may require you to complete it yourself.

The macOS implementation remains in `Sources` and uses Swift/AppKit. The Android port lives in `android` and uses Java, native Android controls, Canvas drawing, and platform HTTP/TLS and image APIs. Both versions share the same early engine scope. The Mac build and its release remain available independently.

## AI Agent on macOS

Click **AI Agent** in Browser's toolbar to open its side panel. Close it with the panel's **×** button, click **AI Agent** again, or use **View → AI Agent** (⇧⌘A). Your task and results stay in the panel when you reopen it.

Select **Download Model** to install the default [Qwen2.5 0.5B Instruct checkpoint from Hugging Face](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF) (429 MB), or use **Model → Choose Model…** to select a compatible local Qwen2 or Qwen2.5 Instruct GGUF. The loader supports Q4_0, Q8_0, Q6_K, and floating-point tensors. Browser verifies the default download against a pinned SHA-256 hash and keeps the file in `~/Library/Application Support/Browser/Models`.

Open a page and describe what you want, for example `Follow the About link and tell me when the museum opens`. The agent can read page text, follow links, navigate, scroll, go back, and turn on Website Compatibility. Review and confirm proposed searches, new addresses that were not in the task, and interactive website controls. The activity log shows each step and the final answer. Use **Stop** to cancel the run.

Simple greetings such as `hola` receive an immediate reply without reading the page or starting browser actions. Give the agent a browsing task when you want it to navigate or search.

Browser's own inference engine implements GGUF loading, byte-level BPE, and the Qwen2 transformer in Swift and C. It uses Accelerate for matrix operations and runs in the browser process. Hugging Face supplies the model file; the task and page text go to the local model. The agent has a 2,048-token context and a ten-step limit. On long or dense pages, scroll closer to the relevant section or give the agent a more specific task. Website Compatibility currently exposes elements in the main document; some sites require manual interaction.

### Direct model connections (development builds)

The current source builds let Android and macOS select a remembered computer by name. Device discovery, pairing, socket transport, and router mapping are implemented in this project using platform APIs. No account, hosted server, relay, STUN server, external discovery service, or networking SDK is required. The published v0.2.2 downloads still have the earlier same-network phone pairing interface.

1. On the computer with the model, open **AI Agent → Devices… → Share This Mac’s Model… → Start Sharing**. Keep Browser running and the computer awake.
2. On your phone or another Mac, open **AI Agent → Devices**, then add the pairing link once. A phone camera can also open the QR code in Browser. Pairing links contain a secret; share them only with your own devices.
3. Select the computer's name in **Devices**. Future tasks use its model while browser actions stay on the device where you started the task. On Mac, choose **This Mac** to return to local inference.

You can also start from the **computer**: open **Devices → Connect a Phone…**, choose a nearby phone, and confirm the matching code on both devices the first time. On the phone, open Browser's **Devices → Connect from Computer** to make it available. The model stays on the computer; the phone becomes its client. An already paired phone keeps an encrypted outbound presence connection to its remembered computers while Browser is open, so the computer can select it over the internet even if the phone's network blocks incoming connections. For first-time remote pairing, add the computer's reachable pairing link on the phone; alternatively, use a directly reachable phone invitation link.

Nearby discovery uses Bonjour/mDNS on the local network. It can refresh a paired computer's nearby route without changing its saved internet address or pairing key. Pairing and your selected device survive restarts in the system Keychain (Mac) or an Android Keystore encrypted file. Sharing still starts only when you turn it on. **Stop Sharing** closes connections; **Reset Pairing** revokes every existing pairing link.

For **internet access**, the receiving computer needs a directly reachable address. In **Share Model**, use **Find Internet Address** to ask your own router for a temporary UPnP TCP mapping. This contacts only devices on your local network. On supported routers, Browser renews its one-hour lease while sharing and removes the mapping when sharing stops. If Browser quits unexpectedly, the lease expires automatically.

Alternatively, enter a global IPv6 address and allow TCP **38765** in the receiving network's firewall, or enter your router's public IPv4 address and forward its chosen external TCP port to **38765** on the Mac. Choose that address in the sharing window before copying or scanning the pairing link. Browser also lists global IPv6 addresses available on the computer. Mac firewall permission may be needed for incoming connections.

With no external discovery or relay service, two devices behind carrier-grade NAT or blocked incoming connections cannot always connect. The app does not bypass those network restrictions. If the public address changes, add the updated pairing link again; the stable device identity updates the existing entry. Android currently consumes a computer's model rather than hosting local inference.

Model requests and replies use authenticated AES-256-GCM encryption with random nonces and a response bound to its request. The sharing computer remembers used request nonces across restarts to reject replayed messages. The directory and pairing keys stay on your devices; only encrypted model messages cross the direct connection.

The reciprocal integration fixture uses an emulator and the real downloaded Mac model. After building the debug app and instrumentation APK, run `python3 scripts/test-phone-connection.py --serial emulator-5580`. It compares the codes, verifies the Mac-to-phone model handoff, obtains an answer from the actual model, then deselects the computer on the phone and verifies that selecting the phone on the Mac restores the connection.

## Android download and install

[Download Browser for Android v0.2.2](https://github.com/culpen90/browser/releases/tag/v0.2.2). Choose **`Browser-0.2.2-Android.apk`**. Requires **Android 8.0 (API 26) or later**; one APK supports phones and tablets across CPU architectures. It is a signed, optimized release build with debugging disabled.

Open the downloaded APK and allow your browser or file manager to install apps if Android asks. Future APK updates must be signed with the same release key. The release includes `Android-SHA256SUMS.txt` and the public signing-certificate fingerprint in `Android-signature.txt`.

Android provides an address bar, Back/Forward, Home, Reload/Stop, scrolling, touch and keyboard links, TalkBack page text/link actions, and a menu for opening HTML/text files through Android's document picker or copying page text/address. The bundled sample page works offline. Chosen local documents currently support inline CSS and network resources; relative companion files are unavailable through the document picker.

Version 0.2.2 includes Reddit compatibility and an AI panel that pairs with the Mac's model, as described above. Website Compatibility requires an installed Android System WebView provider. History stays in memory and is restored across Activity recreation; independent-engine cookies are in memory and reset when the Activity's loader is recreated. No analytics or browser account service is included.

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

Version 0.2.2 includes both Android and macOS downloads under the shared `v0.2.2` release tag. Publishing remains manual; Android CI runs unit tests, lint, and compiles the app/instrumentation APKs, while macOS CI tests and packages the Mac app.

## Download and install

[Download Browser v0.2.2 for macOS](https://github.com/culpen90/browser/releases/tag/v0.2.2). The release includes a real `Browser.app` for macOS 13 or later, with both Apple silicon and Intel support. Xcode and a developer account are not required to run it.

1. Download `Browser-0.2.2-macOS-universal.dmg`, open it, and drag `Browser.app` to Applications. Alternatively, download and extract `Browser-0.2.2-macOS-universal.zip`, then move `Browser.app` to Applications.
2. Open Browser from Applications.
3. If macOS blocks the first launch because it cannot verify the developer, open **System Settings → Privacy & Security**, click **Open Anyway** for Browser, and confirm **Open**. See [Apple's first-launch instructions](https://support.apple.com/102445).

This release is ad-hoc signed and is not notarized by Apple. It does not use a paid Apple Developer membership. Ad-hoc signing checks the bundle's integrity but does not establish a verified developer identity.

The independent engine targets text and links on simple pages. Website Compatibility supplies JavaScript and interactive forms for sites that need them. Tabs and a download manager are not implemented. Read the [engine boundaries](#engine-boundaries) for supported behavior.

The release provides `SHA256SUMS.txt` to check the downloaded packages. With both the DMG and ZIP beside that file, run:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

## Build and open from source

Requirements for source builds: macOS 13 or later and Xcode's Swift toolchain (Swift 6 or later).

The macOS integration tests also require `python3` for a local HTTP fixture. They exercise JavaScript modules and shadow DOM, editable form submission, cookies and storage, sign-in popups, and navigation across the two rendering engines without using real account credentials.

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

- Automatic Reddit compatibility with JavaScript, forms, persistent site storage, and native website navigation; the independent engine remains available for other pages.
- Native address bar, Back, Forward, Home, Reload/Stop, menus, and load feedback.
- HTTP/HTTPS documents, redirects, relative URLs, fragment links, local HTML/text files, and plain-text responses.
- A custom tokenizer and tree builder, quoted attributes, common character references, raw-text handling, and recovery for several omitted end tags.
- CSS tag, class, ID, descendant, child, comma, `:root`, and link selectors; cascade order, specificity, `!important`, inline styles, and inheritance.
- Text sizes, weights, italics, monospace, underlining, colors, backgrounds, vertical margins, uniform padding, and preformatted text.
- Block flow, inline whitespace collapsing, word wrapping, headings, lists, rules, images, and scrolling with reflow on resize.
- Mouse and keyboard links, accessible page text/link actions, and Copy Page Text/Copy Link commands.
- Bounded document/resource loading and parser/layout work. Cancellation prevents an old request from replacing a later navigation. Remote pages cannot load local file subresources.

## Engine boundaries

The independent engine does not yet implement JavaScript, interactive forms, tabs, downloads, persistent browsing data, full HTML tree-construction rules, or the full CSS box model. Flex/grid/table layout currently flows as blocks. Images use system image decoders; CSS image sizing and SVG document rendering are not implemented. External stylesheets use UTF-8, and CSS `@import`/media queries are not interpreted. These limits apply to the custom renderer, rather than Reddit's platform compatibility view. Downloads and tab management are not provided by the app shell in either mode.

Pages with server-rendered text and links remain the custom renderer's target. Use Website Compatibility for pages that require a full platform engine.

Custom-engine limits include 5 MB per document, 1 MB per external stylesheet, 8 MB per image resource, 16 style sources, 24 unique images, 80,000 parsed nodes, 256 levels of nesting, and 40,000 display items. Resources load in batches of four. Its HTTP session keeps cookies/cache in memory for the life of the app; browser history is also in memory. The platform view manages its own resource loading and persistent site data.

## Shortcuts

| Action | Shortcut |
| --- | --- |
| Address | ⌘L |
| Open file | ⌘O |
| Back / Forward | ⌘[ / ⌘] |
| Reload | ⌘R |
| Stop | Esc |
| Home | ⇧⌘H |
| Open / Close AI Agent | ⇧⌘A |
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
| `Sources/BrowserApp/SiteSession.swift` | Full website compatibility, persistent WebKit sessions, forms, popups |
| `Sources/BrowserApp/main.swift` | Application lifecycle and menus |
