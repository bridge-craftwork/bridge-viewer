#!/usr/bin/env bash
# Build the Rust renderer into PbnToPdfKit/PbnToPdfFFI.xcframework.
#
# The xcframework is generated and gitignored; run this before the first Xcode
# build, and again whenever pbn-to-pdf changes. `cargo update` first if you
# want the newest renderer -- the git dependency is unpinned, but cargo keeps
# whatever revision it last resolved until asked.
#
#   scripts/build-xcframework.sh            # iOS device, Apple-silicon simulator, macOS
#   scripts/build-xcframework.sh --update   # cargo update first
#
# Cargo runs through dev-build.sh, as in the other Rust repos: with [patch]
# overrides in a local .cargo/config.toml it checks that pbn-to-pdf and the
# bridge crates really resolved to the sibling checkouts, rather than cargo
# quietly building the GitHub revisions when the versions differ.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
crate="$root/rust"
out="$root/PbnToPdfKit/PbnToPdfFFI.xcframework"
lib=libpbn_to_pdf_ffi.a
ios_targets=(aarch64-apple-ios aarch64-apple-ios-sim)
# An xcframework holds one library per platform, so the two Mac architectures
# are merged into one universal library first.
mac_targets=(aarch64-apple-darwin x86_64-apple-darwin)
targets=("${ios_targets[@]}" "${mac_targets[@]}")

# Match the app's deployment targets, so the linker doesn't warn that the
# library was built for a newer OS than the app supports.
export IPHONEOS_DEPLOYMENT_TARGET=18.0
export MACOSX_DEPLOYMENT_TARGET=15.0

if [[ "${1:-}" == "--update" ]]; then
  "$root/dev-build.sh" --workspace rust update
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
  "$root/dev-build.sh" --workspace rust build --release --lib --target "$t"
done

mac_dir="$crate/target/universal-apple-darwin/release"
mkdir -p "$mac_dir"
mac_libs=()
for t in "${mac_targets[@]}"; do mac_libs+=("$crate/target/$t/release/$lib"); done
lipo -create "${mac_libs[@]}" -output "$mac_dir/$lib"

rm -rf "$out"
args=()
for t in "${ios_targets[@]}"; do
  args+=(-library "$crate/target/$t/release/$lib" -headers "$crate/include")
done
args+=(-library "$mac_dir/$lib" -headers "$crate/include")
xcodebuild -create-xcframework "${args[@]}" -output "$out" >/dev/null

echo "Built $out"
du -sh "$out"/*/$lib
