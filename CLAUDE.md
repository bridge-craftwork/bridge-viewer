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
- **`SwiftUI.Layout` exists.** The renderer's layout type is `PageLayout` for
  that reason.

## Conventions

Matches the sister apps (Kennit, BTLabel, LessonStage): plain `.xcodeproj` with
file-system-synchronized groups, automatic signing under team `8H3FX5B8KD`,
bundle ID `com.popperbiz.BridgeViewer`, local Swift package for the library. The
pbn-to-pdf dependency is an unpinned git dependency and `rust/Cargo.lock` is not
committed — breakage should surface the same day.

Licensed MIT OR Apache-2.0 (unlike the Unlicense sister repos); pbn-to-pdf
itself is Unlicense, which is compatible.

Layout display names and order in `PbnToPdfKit/Sources/PbnToPdfKit/Renderer.swift`
mirror `layoutLabel` and `LAYOUT_ORDER` in pbn-to-pdf's `web/src/lib/render.js`.
