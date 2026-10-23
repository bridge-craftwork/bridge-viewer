#!/usr/bin/env bash
# Build the Rust renderer into PbnToPdfKit/PbnToPdfFFI.xcframework.
#
# The xcframework is generated and gitignored; run this before the first Xcode
# build, and again whenever pbn-to-pdf changes. `cargo update` first if you
# want the newest renderer -- the git dependency is unpinned, but cargo keeps
# whatever revision it last resolved until asked.
#
#   scripts/build-xcframework.sh            # device + Apple-silicon simulator
#   scripts/build-xcframework.sh --update   # cargo update first
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
crate="$root/rust"
out="$root/PbnToPdfKit/PbnToPdfFFI.xcframework"
lib=libpbn_to_pdf_ffi.a
targets=(aarch64-apple-ios aarch64-apple-ios-sim)

# Matches the app's IPHONEOS_DEPLOYMENT_TARGET, so the linker doesn't warn
# that the library was built for a newer iOS than the app supports.
export IPHONEOS_DEPLOYMENT_TARGET=18.0

if [[ "${1:-}" == "--update" ]]; then
  cargo update --manifest-path "$crate/Cargo.toml"
fi

missing=()
for t in "${targets[@]}"; do
  rustup target list --installed | grep -qx "$t" || missing+=("$t")
done
if (( ${#missing[@]} )); then
  echo "Missing Rust targets: ${missing[*]}" >&2
  echo "  rustup target add ${missing[*]}" >&2
  exit 1
fi

for t in "${targets[@]}"; do
  cargo build --manifest-path "$crate/Cargo.toml" --release --lib --target "$t"
done

rm -rf "$out"
args=()
for t in "${targets[@]}"; do
  args+=(-library "$crate/target/$t/release/$lib" -headers "$crate/include")
done
xcodebuild -create-xcframework "${args[@]}" -output "$out" >/dev/null

echo "Built $out"
du -sh "$out"/*/$lib
