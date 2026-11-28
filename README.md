# Bridge Viewer

An iPhone, iPad and Mac app for bridge teaching material.

A native SwiftUI app over [pbn-to-pdf](https://github.com/bridge-craftwork/pbn-to-pdf):
open a PBN or LIN file, pick a layout, and get a printable PDF — declarer's plans,
bidding sheets, dealer summaries, analysis, hand records.

The renderer is the same Rust crate the CLI and the web app use, compiled as a
static library for iOS and macOS rather than to WebAssembly. PDFKit shows the
result, so scrolling and zoom are native; the share sheet (and on the Mac, Save
and Print) send it on.

The layout bar stays collapsed to one row showing the current layout --
most people use one nearly always, and it (and the circling choices) is
remembered between launches. On the analysis layout, the Play toggle (View ▸ Show
Play Records) draws every board's trick-by-trick play, for files like Brill's
exports that record it but don't ask for it with `BCFlags`. Beside it, By Seat (View ▸ Play Records by Seat, on unless turned off) lays the play out one column per player instead of Bridge Composer's play order, and when the file has a `[DoubleDummyPlay]` section (bridge-solver's `--play`) marks each card that cost a trick. Tap it for the strip of every layout. Search
sits beside it: matches are highlighted, with a count and previous/next (⌘F,
⌘G, ⇧⌘G, and ⌘E to find the selected text). In the page grid, each page shows how many
matches it has, and previous/next move through them without leaving the grid.

For long documents there is a page counter, and a page grid: pinch out past
fit-to-width (or use the Pages/Grid toggle, or View ▸ Show Page Grid on the
Mac), pinch within the grid to change its size, tap a page to read it.

The Boards button (Go ▸ Go to Board…, ⌥⌘B) lists every board with
its page. Choose one to go straight to it.

Solve (the wand, or File ▸ Solve Double Dummy, ⇧⌘D) works out every board
double dummy in the background, as bridge-solver's CLI does (its `annotate`
module, linked in): `[DoubleDummyTricks]`, par and `[OptimumResultTable]` for
each board without them, and for a file that records its play a
`[DoubleDummyPlay]` section per board, which Play by Seat turns into costs on
the cards. A strip under the layout bar shows progress with Cancel (⌘.), then
what was done and which boards were skipped. The analysis goes into the PBN
the app shows, the rest of the file kept byte for byte; File ▸ Save PBN… (⇧⌘S)
writes it out, and a LIN file is saved as PBN. Solve Every Board Again redoes
boards that already have analysis.

View ▸ View Source (⌥⌘U, or the `</>` button) shows the file as it was
opened — PBN or LIN, syntax-coloured — beside the PDF, or in a sheet on a
phone. Click a board's record in the source and the PDF goes to that board;
click a board in the PDF (or choose one in the board index) and its record is
highlighted and scrolled to. The map between the two comes from the Rust side
(`ptp_source_records`), which divides the file into records exactly as the
renderer and the LIN reader do.

With a keyboard (the Mac, or an iPad's menu bar and ⌘-hold list) there are
the usual menu commands: Open, Close (⌘W), Save PDF (⌘S), Print (⌘P); Copy and
Select All on text selected in the page (drag across it on the Mac); zoom
(⌘0 actual size, ⌘9 fit, ⌘= and ⌘-); and a Go menu for the previous and next
page (⌥⌘↑ ⌥⌘↓, with ⇧ for the first and last).

Every PDF the app saves, prints or shares carries its own source: the `.pbn`,
the boards, and where each one sits on the page (Contract 5, the format
lesson-studio's lesson PDFs use). Open one in lesson-stage and its boards can
be tapped and played out.

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
first. To build against sibling checkouts of pbn-to-pdf, bridge-types and
bridge-encodings instead, put `[patch]` entries pointing at them in a
`.cargo/config.toml` at the repo root (gitignored), as the other Rust repos do.
Cargo then goes through `dev-build.sh` (the script those repos share, run with
`--workspace rust`), which the xcframework script already uses: it checks each
patched crate really resolved to its local checkout, since cargo quietly
builds the GitHub revision instead when the versions differ.

Debug builds take launch arguments for screenshots: `-LoadSample` or
`-LoadFile <path>` (the latter not on the sandboxed Mac), then `-Layout
<name>`, `-ShowGrid`, `-ShowBoards` (the board index open), `-GoToBoard <n>`, `-Search <text>`, `-SwitchLayout <name>` (a layout
change two seconds in, folding the strip as a tap does) and `-ToggleCircling`
(a re-render two seconds in, with search open) and `-Solve` (a solve once the PDF
is up, its outcome printed).

```bash
cd PbnToPdfKit && swift test                    # the Swift API, on the Mac
./dev-build.sh --workspace rust test            # the C ABI
```

CI (`.github/workflows/ci.yml`) runs the Rust checks on Linux, and on macOS
builds the xcframework, runs the Swift tests and builds the app unsigned for
the Mac and the iOS simulator. It also runs daily, since a pbn-to-pdf change
can break this repo with no commit here.

## Opening .pbn files

Neither iOS nor macOS has a system type for `.pbn` — which is why Safari greys
PBN files out of a file picker. PBN is an open specification with no owner, so
`app/Info.plist` exports one (`com.popperbiz.pbn`, conforming to plain text)
and claims it as a viewer, so PBN files can be picked here, opened from Files,
and sent to the app from the share sheet.

Other bridge apps export their own type for `.pbn` (Shark Bridge Game's is
`com.emabridge.bridgedeal`), and which one the system honours is undocumented.
So the app also claims the `.pbn` extension directly, which keeps it under
Open With whoever wins, and its file picker accepts every type `.pbn` maps to.
Which app opens a `.pbn` on double-click is the user's choice (Get Info ▸ Open
with ▸ Change All on the Mac), not something the app can set.

## Opening .lin files

LIN, Bridge Base Online's hand records, opens the same way. The Rust side reads
it into PBN (`ptp_lin_to_pbn`, over bridge-encodings' `LinData::to_board`), the
way Bridge Composer opens LIN, and from then on the file is PBN to the app.
`Info.plist` exports `com.popperbiz.lin` and claims the `.lin` extension, as
for `.pbn`, but as the **owner** (`LSHandlerRank Owner`): BBO declares no type
for it, so this app is offered first.

## Licence

[Unlicense](LICENSE), matching pbn-to-pdf. The vendored `azul-core` keeps its
own MPL-2.0.
