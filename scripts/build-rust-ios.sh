#!/bin/bash
set -euo pipefail

case "$#:${1-}" in
    0:|1:--all) targets=(aarch64-apple-ios aarch64-apple-ios-sim) ;;
    1:--device) targets=(aarch64-apple-ios) ;;
    1:--simulator) targets=(aarch64-apple-ios-sim) ;;
    *)
        printf 'Usage: %s [--device|--simulator|--all]\n' "${0##*/}" >&2
        exit 2
        ;;
esac

if [[ -d /opt/homebrew/opt/rustup/bin ]]; then
    export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
fi

CDPATH= cd -- "$(dirname "$0")/.."
ROOT=$PWD
export CARGO_TARGET_DIR="$ROOT/elsewhere-core/target"
mkdir -p "$ROOT/build"
STAGING=$(mktemp -d "$ROOT/build/.rust-ios.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
HEADERS_DIR="$STAGING/Headers"
mkdir "$HEADERS_DIR"

libraries=()
for target in "${targets[@]}"; do
    cargo +1.94.0 build --locked --release --manifest-path "$ROOT/elsewhere-core/Cargo.toml" --target "$target"
    libraries+=(-library "$CARGO_TARGET_DIR/$target/release/libelsewhere_core.a" -headers "$HEADERS_DIR")
done

TARGET="${targets[0]}" cbindgen --config "$ROOT/elsewhere-core/cbindgen.toml" --crate elsewhere-core \
    --output "$HEADERS_DIR/ElsewhereCore.h" --only-target-dependencies "$ROOT/elsewhere-core"
cp "$ROOT/elsewhere-core/include/module.modulemap" "$HEADERS_DIR/module.modulemap"

xcodebuild -create-xcframework "${libraries[@]}" -output "$STAGING/ElsewhereCore.xcframework"
rm -rf "$ROOT/build/ElsewhereCore.xcframework"
mv "$STAGING/ElsewhereCore.xcframework" "$ROOT/build/"
