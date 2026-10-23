# Vendored crates

Crates carried with a small patch so the renderer compiles for iOS. Each one is
the unmodified crates.io release apart from lines marked `pbn-to-pdf-apple
patch`, wired in through `[patch.crates-io]` in `rust/Cargo.toml`. Remove a copy
once upstream releases the fix.

| Crate | Version | Licence | Patch |
|---|---|---|---|
| azul-core | 0.0.6 | MPL-2.0 | `src/resources.rs`: `FontInstancePlatformOptions` and its construction are declared per `target_os` for windows, macos and linux plus `wasm32`; iOS matched none and failed with E0425. iOS now takes the macOS arm. pbn-to-pdf never reaches this code — printpdf pulls azul-core in through its `svg` feature — so the choice only has to compile. |

azul-core is MPL-2.0, which is file-level copyleft: a modified file must stay
available under the MPL. It does — the patched source is right here. The crate
ships no licence file (MPL-2.0 is declared in its `Cargo.toml`), so none is
copied. It places no terms on the rest of the app.
