# Bridge Viewer

An iPhone, iPad and Mac app for bridge teaching material.

A native SwiftUI app over [pbn-to-pdf](https://github.com/bridge-craftwork/pbn-to-pdf):
open a PBN file, pick a layout, and get a printable PDF — declarer's plans,
bidding sheets, dealer summaries, analysis, hand records.

The renderer is the same Rust crate the CLI and the web app use, compiled as a
static library for iOS and macOS rather than to WebAssembly. PDFKit shows the
result, so scrolling and zoom are native; the share sheet (and on the Mac, Save
and Print) send it on.

The layout bar stays collapsed to one row showing the current layout --
most people use one nearly always, and it (and the circling choices) is
remembered between launches. Tap it for the strip of every layout. Search
sits beside it: matches are highlighted, with a count and previous/next (⌘F,
⌘G and ⇧⌘G on the Mac).

For long documents there is a page counter, and a page grid: pinch out past
fit-to-width (or use the Pages/Grid toggle, or View ▸ Show Page Grid on the
Mac), pinch within the grid to change its size, tap a page to read it.

One target builds both platforms, the way BTLabel does (`SDKROOT = auto`). The
Mac app is sandboxed with read/write access to files the user picks.

## Layout

```
rust/            pbn-to-pdf-ffi: a C ABI over the renderer (staticlib)
  include/       its hand-written header and module map
vendor/          crates patched to compile for iOS (see vendor/README.md)
scripts/         build-xcframework.sh
PbnToPdfKit/     Swift package: the xcframework plus a Swift API (Renderer, PageLayout)
app/             the Xcode project
```

## Building

Needs Xcode and four Rust targets:

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin x86_64-apple-darwin
scripts/build-xcframework.sh          # before the first Xcode build
open app/BridgeViewer.xcodeproj
```

The xcframework is generated and gitignored. Rebuild it whenever the renderer
changes; `scripts/build-xcframework.sh --update` pulls the newest pbn-to-pdf
first.

Debug builds take launch arguments for screenshots: `-LoadSample` or
`-LoadFile <path>` (the latter not on the sandboxed Mac), then `-Layout
<name>`, `-ShowGrid`, `-Search <text>`, `-SwitchLayout <name>` (a layout
change two seconds in, folding the strip as a tap does) and `-ToggleCircling`
(a re-render two seconds in, with search open).

```bash
cd PbnToPdfKit && swift test                    # the Swift API, on the Mac
cargo test --manifest-path rust/Cargo.toml      # the C ABI
```

## Opening .pbn files

iOS has no system type for `.pbn` — which is why Safari greys PBN files out of a
file picker. `app/Info.plist` imports one (`com.popperbiz.pbn`, conforming to
plain text) and claims it as a viewer, so PBN files can be picked here, opened
from Files, and sent to the app from the share sheet.

## Licence

[Unlicense](LICENSE), matching pbn-to-pdf. The vendored `azul-core` keeps its
own MPL-2.0.
