#!/usr/bin/env bash
#
# build_rust.sh
#
# Cross-compiles the retichat-ffi Rust crate for iOS and macOS (Mac Catalyst)
# targets and creates a universal static library + XCFramework for Xcode.
#
# Usage:
#   cd Retichat-ios
#   ./build_rust.sh [release|debug]
#
# Prerequisites:
#   rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
#   rustup target add aarch64-apple-ios-macabi x86_64-apple-ios-macabi
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUST_DIR="$SCRIPT_DIR/rust/retichat-ffi"
BUILD_TYPE="${1:-release}"
OUT_DIR="$SCRIPT_DIR/Frameworks"

if [[ "$BUILD_TYPE" == "release" ]]; then
    CARGO_FLAGS="--release"
    TARGET_SUBDIR="release"
else
    CARGO_FLAGS=""
    TARGET_SUBDIR="debug"
fi

echo "==> Building retichat-ffi ($BUILD_TYPE) for iOS + macOS (Mac Catalyst) targets..."

# Ensure targets are installed
rustup target add aarch64-apple-ios 2>/dev/null || true
rustup target add aarch64-apple-ios-sim 2>/dev/null || true
rustup target add x86_64-apple-ios 2>/dev/null || true
rustup target add aarch64-apple-ios-macabi 2>/dev/null || true
rustup target add x86_64-apple-ios-macabi 2>/dev/null || true

cd "$RUST_DIR"

# Set deployment target so C dependencies (bzip2, etc.) don't default to the SDK
# version, which causes "built for newer version" linker warnings.
export IPHONEOS_DEPLOYMENT_TARGET=17.6

# Build for each iOS target
echo "--- aarch64-apple-ios (device) ---"
cargo build $CARGO_FLAGS --target aarch64-apple-ios

echo "--- aarch64-apple-ios-sim (Apple Silicon simulator) ---"
cargo build $CARGO_FLAGS --target aarch64-apple-ios-sim

echo "--- x86_64-apple-ios (Intel simulator) ---"
cargo build $CARGO_FLAGS --target x86_64-apple-ios

# Build for Mac Catalyst targets (ios-macabi = iOS app running on macOS)
echo "--- aarch64-apple-ios-macabi (Mac Catalyst Apple Silicon) ---"
cargo build $CARGO_FLAGS --target aarch64-apple-ios-macabi

echo "--- x86_64-apple-ios-macabi (Mac Catalyst Intel) ---"
cargo build $CARGO_FLAGS --target x86_64-apple-ios-macabi

# Paths to built static libs
DEVICE_LIB="$RUST_DIR/target/aarch64-apple-ios/$TARGET_SUBDIR/libretichat_ffi.a"
SIM_ARM_LIB="$RUST_DIR/target/aarch64-apple-ios-sim/$TARGET_SUBDIR/libretichat_ffi.a"
SIM_X86_LIB="$RUST_DIR/target/x86_64-apple-ios/$TARGET_SUBDIR/libretichat_ffi.a"
CATALYST_ARM_LIB="$RUST_DIR/target/aarch64-apple-ios-macabi/$TARGET_SUBDIR/libretichat_ffi.a"
CATALYST_X86_LIB="$RUST_DIR/target/x86_64-apple-ios-macabi/$TARGET_SUBDIR/libretichat_ffi.a"

# Verify outputs exist
for lib in "$DEVICE_LIB" "$SIM_ARM_LIB" "$SIM_X86_LIB" "$CATALYST_ARM_LIB" "$CATALYST_X86_LIB"; do
    if [[ ! -f "$lib" ]]; then
        echo "ERROR: Expected library not found: $lib"
        exit 1
    fi
done

# Create universal simulator lib (fat binary with both arm64 + x86_64)
echo "==> Creating universal simulator library..."
UNIVERSAL_SIM_DIR="$RUST_DIR/target/universal-sim/$TARGET_SUBDIR"
mkdir -p "$UNIVERSAL_SIM_DIR"
lipo -create "$SIM_ARM_LIB" "$SIM_X86_LIB" \
     -output "$UNIVERSAL_SIM_DIR/libretichat_ffi.a"

# Create universal Mac Catalyst lib (fat binary with arm64 + x86_64, ios-macabi platform)
echo "==> Creating universal Mac Catalyst library..."
UNIVERSAL_CATALYST_DIR="$RUST_DIR/target/universal-catalyst/$TARGET_SUBDIR"
mkdir -p "$UNIVERSAL_CATALYST_DIR"
lipo -create "$CATALYST_ARM_LIB" "$CATALYST_X86_LIB" \
     -output "$UNIVERSAL_CATALYST_DIR/libretichat_ffi.a"

# Build header directory (shared C header + module map)
HEADERS_DIR="$RUST_DIR/target/headers"
mkdir -p "$HEADERS_DIR"
cp "$SCRIPT_DIR/Retichat/Bridge/CRetichatFFI.h" "$HEADERS_DIR/"

cat > "$HEADERS_DIR/module.modulemap" <<EOF
module RetichatFFI {
    header "CRetichatFFI.h"
    export *
}
EOF

# Assemble XCFramework manually so the Mac Catalyst slice is tagged correctly.
# xcodebuild -create-xcframework auto-detects macOS libs as plain "macos" platform,
# but Mac Catalyst needs SupportedPlatform=ios + SupportedPlatformVariant=maccatalyst.
echo "==> Assembling XCFramework..."
XCFW_PATH="$OUT_DIR/RetichatFFI.xcframework"
rm -rf "$XCFW_PATH"
mkdir -p "$OUT_DIR"

# Device slice
DEVICE_SLICE="$XCFW_PATH/ios-arm64"
mkdir -p "$DEVICE_SLICE/Headers"
cp "$DEVICE_LIB" "$DEVICE_SLICE/libretichat_ffi.a"
cp "$HEADERS_DIR/CRetichatFFI.h" "$DEVICE_SLICE/Headers/"
cp "$HEADERS_DIR/module.modulemap" "$DEVICE_SLICE/Headers/"

# Simulator slice
SIM_SLICE="$XCFW_PATH/ios-arm64_x86_64-simulator"
mkdir -p "$SIM_SLICE/Headers"
cp "$UNIVERSAL_SIM_DIR/libretichat_ffi.a" "$SIM_SLICE/libretichat_ffi.a"
cp "$HEADERS_DIR/CRetichatFFI.h" "$SIM_SLICE/Headers/"
cp "$HEADERS_DIR/module.modulemap" "$SIM_SLICE/Headers/"

# Mac Catalyst slice (ios platform + maccatalyst variant)
CATALYST_SLICE="$XCFW_PATH/ios-arm64_x86_64-maccatalyst"
mkdir -p "$CATALYST_SLICE/Headers"
cp "$UNIVERSAL_CATALYST_DIR/libretichat_ffi.a" "$CATALYST_SLICE/libretichat_ffi.a"
cp "$HEADERS_DIR/CRetichatFFI.h" "$CATALYST_SLICE/Headers/"
cp "$HEADERS_DIR/module.modulemap" "$CATALYST_SLICE/Headers/"

# Info.plist — Mac Catalyst requires SupportedPlatform=ios + SupportedPlatformVariant=maccatalyst
cat > "$XCFW_PATH/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AvailableLibraries</key>
    <array>
        <dict>
            <key>BinaryPath</key>      <string>libretichat_ffi.a</string>
            <key>LibraryIdentifier</key> <string>ios-arm64</string>
            <key>LibraryPath</key>     <string>libretichat_ffi.a</string>
            <key>SupportedArchitectures</key>
            <array><string>arm64</string></array>
            <key>SupportedPlatform</key> <string>ios</string>
        </dict>
        <dict>
            <key>BinaryPath</key>      <string>libretichat_ffi.a</string>
            <key>LibraryIdentifier</key> <string>ios-arm64_x86_64-simulator</string>
            <key>LibraryPath</key>     <string>libretichat_ffi.a</string>
            <key>SupportedArchitectures</key>
            <array><string>arm64</string><string>x86_64</string></array>
            <key>SupportedPlatform</key>           <string>ios</string>
            <key>SupportedPlatformVariant</key>    <string>simulator</string>
        </dict>
        <dict>
            <key>BinaryPath</key>      <string>libretichat_ffi.a</string>
            <key>LibraryIdentifier</key> <string>ios-arm64_x86_64-maccatalyst</string>
            <key>LibraryPath</key>     <string>libretichat_ffi.a</string>
            <key>SupportedArchitectures</key>
            <array><string>arm64</string><string>x86_64</string></array>
            <key>SupportedPlatform</key>           <string>ios</string>
            <key>SupportedPlatformVariant</key>    <string>maccatalyst</string>
        </dict>
    </array>
    <key>CFBundlePackageType</key> <string>XFWK</string>
    <key>XCFrameworkFormatVersion</key> <string>1.0</string>
</dict>
</plist>
PLIST
echo "==> XCFramework assembled at: $XCFW_PATH"

# Sync to the Retichat/ folder so the PBXFileSystemSynchronizedRootGroup picks it up
RETICHAT_XCFW="$SCRIPT_DIR/Retichat/RetichatFFI.xcframework"
if [[ -d "$RETICHAT_XCFW" ]] || [[ -d "$SCRIPT_DIR/Retichat" ]]; then
    echo "==> Syncing xcframework to Retichat/RetichatFFI.xcframework..."
    rm -rf "$RETICHAT_XCFW"
    cp -R "$XCFW_PATH" "$RETICHAT_XCFW"
fi

echo ""
echo "Done!"
