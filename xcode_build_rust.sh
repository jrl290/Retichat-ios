#!/usr/bin/env bash
#
# xcode_build_rust.sh
#
# Run by Xcode (the "RustLibrary" target, which Retichat depends on) before
# every build of the app: builds retichat-ffi for the platform and
# architectures Xcode is building, and writes the static library to
# $BUILT_PRODUCTS_DIR, where the app links it (-lretichat_ffi). cargo
# recompiles only what changed, and the library is replaced only when it
# differs, so an unchanged crate costs a few seconds and no relink.
#
# Before 2026-10-19 the app linked Retichat/RetichatFFI.xcframework, which is
# not in git: Xcode linked whatever build_rust.sh had last produced on that
# Mac, so an app could ship with Rust older than its Swift. The app no longer
# links the xcframework (Xcode unpacks an xcframework before any target runs,
# so a build step can't refresh it in time). build_rust.sh still builds it, for
# anything else that wants every slice at once.
#
# Swift sees the Rust functions through the bridging header
# (Retichat/Bridge/CRetichatFFI.h), not through the library.
#
# The Rust side is always built --release: a debug Rust build runs the crypto
# far slower and panics on integer overflow where the release build doesn't.

set -euo pipefail

[[ "${ACTION:-build}" == "indexbuild" ]] && exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUST_DIR="$SCRIPT_DIR/rust/retichat-ffi"
OUT="${BUILT_PRODUCTS_DIR:?run this from Xcode, or use build_rust.sh}/libretichat_ffi.a"

PLATFORM="${PLATFORM_NAME:?}"
if [[ "${IS_MACCATALYST:-NO}" == "YES" || "${EFFECTIVE_PLATFORM_NAME:-}" == "-maccatalyst" ]]; then
    PLATFORM="maccatalyst"
fi

TARGETS=()
for arch in ${ARCHS:?}; do
    case "$PLATFORM/$arch" in
        iphoneos/arm64)         TARGETS+=(aarch64-apple-ios) ;;
        iphonesimulator/arm64)  TARGETS+=(aarch64-apple-ios-sim) ;;
        iphonesimulator/x86_64) TARGETS+=(x86_64-apple-ios) ;;
        maccatalyst/arm64)      TARGETS+=(aarch64-apple-ios-macabi) ;;
        maccatalyst/x86_64)     TARGETS+=(x86_64-apple-ios-macabi) ;;
        *) echo "error: xcode_build_rust.sh: no Rust target for $PLATFORM $arch"; exit 1 ;;
    esac
done

# Xcode's environment (SDKROOT for the iOS SDK, its PATH, dozens of build
# settings) breaks the host build scripts and makes cargo rebuild after every
# terminal build, so cargo gets the same plain environment a terminal gives it.
CARGO_ENV=(
    env -i
    HOME="$HOME" USER="${USER:-}" TMPDIR="${TMPDIR:-/tmp}" LANG="${LANG:-en_US.UTF-8}"
    PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    IPHONEOS_DEPLOYMENT_TARGET=17.6
)
[[ -n "${DEVELOPER_DIR:-}" ]] && CARGO_ENV+=(DEVELOPER_DIR="$DEVELOPER_DIR")

cd "$RUST_DIR"
LIBS=()
for t in "${TARGETS[@]}"; do
    echo "--- cargo build --release --target $t ---"
    "${CARGO_ENV[@]}" rustup target add "$t" >/dev/null 2>&1 || true
    "${CARGO_ENV[@]}" cargo build --release --target "$t"
    LIBS+=("$RUST_DIR/target/$t/release/libretichat_ffi.a")
done

mkdir -p "$(dirname "$OUT")"
NEW="$OUT.new"
trap 'rm -f "$NEW"' EXIT
if (( ${#LIBS[@]} > 1 )); then
    lipo -create "${LIBS[@]}" -output "$NEW"
else
    cp "${LIBS[0]}" "$NEW"
fi

if cmp -s "$NEW" "$OUT"; then
    echo "==> libretichat_ffi.a unchanged"
else
    mv "$NEW" "$OUT"
    echo "==> libretichat_ffi.a updated (${TARGETS[*]})"
fi
