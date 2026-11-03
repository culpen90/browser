# Browser

A native macOS browser foundation with an engine written in Swift. The project starts from an empty repository and has no third-party dependencies.

The engine parses HTML into a document tree, computes a supported subset of CSS, lays out blocks and inline text, and produces its own display list. AppKit draws that display list and supplies the native window and controls. Foundation supplies HTTP, HTTPS, file access, and TLS. There is no WebKit, Chromium, web view, or system HTML importer.

## Build and open the app

Requirements: macOS 13 or later and Xcode's Swift toolchain (Swift 6 or later).

Clone the repository, build, and install the app locally:

```sh
git clone https://github.com/culpen90/browser.git
cd browser
./scripts/install-app.sh
open ~/Applications/Browser.app
```

The install script creates `~/Applications/Browser.app`, `dist/Browser.app`, and a portable `dist/Browser.zip`. Build outputs are excluded from the repository. The packaged binary targets the architecture of the Mac used to build it. Local builds are ad-hoc signed; they are not notarized for distribution.

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
