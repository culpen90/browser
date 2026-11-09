# Browser v0.4.0

Browser Search brings web search into the address bar on macOS and Android. Results open in a built-in page that shows the query in the address bar. Opening a result shows the destination website’s address.

## macOS

- Browser starts its bundled SearXNG service on the Mac when you open the app and stops it when you quit.
- Use the toolbar gear or **⌘,** to manage local search, pick sources, and adjust SafeSearch. Brave Search and DuckDuckGo are enabled by default, and Bing is available as an option.
- SearXNG sends submitted queries to the sources you enable. Provider availability and SafeSearch support can vary.

## Android

- Browser Search uses the Mwmbl web search API and displays the results in the app.
- Back and Forward restore cached results, and Reload refreshes them.

## Downloads

- **Browser-0.4.0-macOS-universal.dmg** or **Browser-0.4.0-macOS-universal.zip** for macOS 13 or later on Apple Silicon or Intel.
- **Browser-0.4.0-Android.apk** for Android 8.0 or later. The APK uses the existing production signing certificate and version code 6.
- **SHA256SUMS.txt** and **Android-SHA256SUMS.txt** list the package checksums. **Android-signature.txt** lists the public Android signing-certificate fingerprint.

The Mac app uses ad-hoc signing. macOS may require you to approve the first launch in **System Settings → Privacy & Security**. [Apple’s first-launch instructions](https://support.apple.com/102445)
