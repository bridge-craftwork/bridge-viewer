# Bridge Viewer

An iPhone and iPad app for bridge teaching material.

A native SwiftUI app over [pbn-to-pdf](https://github.com/bridge-craftwork/pbn-to-pdf):
open a PBN file, pick a layout, and get a printable PDF — declarer's plans,
bidding sheets, dealer summaries, analysis, hand records.

The renderer is the same Rust crate the CLI and the web app use, compiled for
iOS as a static library rather than to WebAssembly. PDFKit shows the result, so
scrolling and pinch-zoom are native, and the share sheet saves, prints or sends
it.

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

Needs Xcode and the two iOS Rust targets:

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
scripts/build-xcframework.sh          # before the first Xcode build
open app/BridgeViewer.xcodeproj
```

The xcframework is generated and gitignored. Rebuild it whenever the renderer
changes; `scripts/build-xcframework.sh --update` pulls the newest pbn-to-pdf
first. In Debug, launching with `-LoadSample` opens the bundled sample.

Tests for the Swift API run on a simulator (the xcframework has no macOS
slice):

```bash
cd PbnToPdfKit
xcodebuild test -scheme PbnToPdfKit -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)'
cargo test --manifest-path ../rust/Cargo.toml   # the C ABI, on the Mac
```

## Opening .pbn files

iOS has no system type for `.pbn` — which is why Safari greys PBN files out of a
file picker. `app/Info.plist` imports one (`com.popperbiz.pbn`, conforming to
plain text) and claims it as a viewer, so PBN files can be picked here, opened
from Files, and sent to the app from the share sheet.

## Licence

[Unlicense](LICENSE), matching pbn-to-pdf. The vendored `azul-core` keeps its
own MPL-2.0.
