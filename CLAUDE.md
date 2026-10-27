# CLAUDE.md

Bridge Viewer: iOS/iPadOS app over the pbn-to-pdf renderer. See [README.md](README.md) for the
layout and build steps.

## Things that fail quietly

- **The xcframework is a build product.** `PbnToPdfKit/PbnToPdfFFI.xcframework`
  is gitignored and made by `scripts/build-xcframework.sh`. Xcode builds against
  whatever copy is on disk, so after a renderer change the app silently keeps
  the old one until the script is rerun.
- **The header is hand-written.** `rust/include/PbnToPdfFFI.h` must match the
  `#[no_mangle]` functions and `#[repr(C)]` structs in `rust/src/lib.rs`. A
  mismatch links fine and corrupts memory at runtime. Change both together.
- **Nothing may unwind into Swift.** Every exported function runs inside
  `catch_unwind` (`boundary` in lib.rs); keep it that way for new entry points,
  and keep `panic = "unwind"` in the release profile.
- **Every Rust allocation goes back to Rust.** Buffers and strings returned
  across the boundary are freed with `ptp_buffer_free` / `ptp_string_free`;
  `PbnToPdfKit` copies them into `Data`/`String` and frees immediately.
- **azul-core is patched for iOS** (`vendor/`, see its README). If a renderer
  update moves printpdf onto a newer azul-core, the `[patch.crates-io]` entry
  stops applying and the iOS build fails with E0425 in `resources.rs` — re-vendor
  that version with the same change, or drop it if upstream has fixed it.
- **The Mac slice is one universal library.** An xcframework takes one library
  per platform, so the script `lipo`s the arm64 and x86_64 Mac builds together.
- **Pinch-to-grid watches, never captures.** On iPad a second pinch recognizer
  runs alongside PDFView's; on the Mac `PinchablePDFView` observes magnify
  events after `super`. Taking the gesture instead breaks PDFView's own zoom.
- **No `ViewThatFits` around controls next to the PDF.** It keeps hidden
  copies of its children; with buttons among them, PDFView's next document
  swap sent UIKit's first-responder promotion into an endless loop and the
  app hung on every re-render. `LayoutBar` measures its width instead. Repro:
  launch with `-LoadSample -ToggleCircling` and sample the process for
  `_setFirstResponder`.
- **`SwiftUI.Layout` exists.** The renderer's layout type is `PageLayout` for
  that reason.
- **Old builds stay registered on the Mac.** Launch Services keeps every copy
  it has seen — stale builds under `build/`, simulator builds, apps in the
  Trash — and an old copy's `Info.plist` can win type and icon lookups.
  `lsregister -dump` lists them; `lsregister -u <path>` drops one. Dragging an
  app to the Trash doesn't unregister it.
- **The Mac caches icons per app path.** After an icon change, Finder and the
  Dock can keep the old one (even the generic placeholder) until the bundle is
  touched and re-registered with `lsregister -f`. Not a bug in the build.
- **Another app may own `.pbn`.** Shark Bridge Game exports its own type for
  the extension, and which of two exports wins is undocumented. The extension
  claim in `Info.plist` and `UTType.pbnFiles` are what keep opening working
  regardless; don't narrow either to `com.popperbiz.pbn`.
- **The product is "Bridge Viewer", the module `BridgeViewer`.** `PRODUCT_NAME`
  carries the space so Finder shows it; `PRODUCT_MODULE_NAME` pins the module.

## Direction: the PDF stays the view, the bridge data rides inside it

Planned, not built. The app keeps showing pbn-to-pdf's PDF rather than drawing
its own layouts. Bridge knowledge (a hand index first) comes from **Contract
5**: the attachments and `lesson-block:` link annotations that lesson PDFs
already carry. pbn-to-pdf is to produce a PBN profile of it, and this app to
render with it and read the click map back through the FFI. The plan, including
the contract's move to lesson-stage, is
`../lesson-stage/docs/contract-5-shared-plan.md`. Until it lands, the contract
text is `../lesson-studio/documentation/contracts/pdf-attachments.md`.

Sister repos in the same family: **lesson-studio** (lesson editor, Contract 5's
first producer), **lesson-stage** (iPad presenter, its consumer; its card-play
popout runs the Bridge-Classroom Vue components in a web view, see its
ADR-003), **pbn-to-pdf** (the renderer). Don't build interactive hands here:
that's lesson-stage's popout.

## Conventions

Matches the sister apps (Kennit, BTLabel, LessonStage): plain `.xcodeproj` with
file-system-synchronized groups, automatic signing under team `8H3FX5B8KD`,
bundle ID `com.popperbiz.BridgeViewer`, local Swift package for the library. The
pbn-to-pdf dependency is an unpinned git dependency and `rust/Cargo.lock` is not
committed — breakage should surface the same day.

Unlicense, like pbn-to-pdf and the sister repos.

Layout display names in `PbnToPdfKit/Sources/PbnToPdfKit/Renderer.swift` mirror
`layoutLabel` in pbn-to-pdf's `web/src/lib/render.js`. The order deliberately
does not follow its `LAYOUT_ORDER`: analysis, hand record, dealer summary,
bidding sheets, then the declarer's plans 1-, 2- and 4-up. The last layout
chosen is saved and every file opens in it.
