# Retichat iOS

A decentralized, end-to-end encrypted messenger for iOS built on
[Reticulum](https://reticulum.network) and [LXMF](https://github.com/markqvist/LXMF).
Today it is focused on direct messaging over internet and local Reticulum
connectivity — no phone number or account required.

The networking stack is written in Rust and compiled to a static library via
a C FFI bridge. The UI is pure SwiftUI with SwiftData persistence.

## Development Note

This project was created with substantial AI assistance during design,
implementation, refactoring, and documentation.

## Repository Layout

```
Retichat-ios/
├── xcode_build_rust.sh        # Run by Xcode on every build: Rust → libretichat_ffi.a
├── build_rust.sh              # Cross-compiles every slice → XCFramework (optional)
├── rust/retichat-ffi/         # Rust C FFI bridge (staticlib)
│   ├── Cargo.toml
│   └── src/lib.rs
├── Frameworks/                # (generated) RetichatFFI.xcframework
├── Retichat/                  # Swift/SwiftUI iOS app
│   ├── Bridge/                # C header + Swift FFI wrappers
│   ├── Models/                # SwiftData entities
│   ├── Services/              # Networking, direct chat, notifications
│   ├── Theme/                 # Colors and glass background
│   └── Views/                 # SwiftUI views + view models
├── NotificationService/       # Push notification extension
└── Retichat.xcodeproj/        # Xcode project
```

## Prerequisites

| Requirement | Version |
|-------------|---------|
| Xcode | 15+ (Swift 5.9, SwiftData) |
| iOS deployment target | 17.0+ |
| Rust toolchain | stable |
| macOS | 14+ (Sonoma) recommended |

### Sibling repositories

The Rust FFI crate depends on two sibling repositories via relative paths.
Clone all three into the **same parent directory**:

```bash
mkdir retichat-workspace && cd retichat-workspace
git clone https://github.com/jrl290/Rusticulum.git Reticulum-rust
git clone https://github.com/jrl290/LXMF-rust.git
git clone https://github.com/jrl290/Retichat-ios.git
```

Your directory tree should look like:

```
retichat-workspace/
├── Reticulum-rust/    # Reticulum networking stack (Rust)
├── LXMF-rust/         # LXMF messaging protocol (Rust)
└── Retichat-ios/      # This repository
```

## Build

### 1. Install Rust iOS targets

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
rustup target add aarch64-apple-ios-macabi x86_64-apple-ios-macabi
```

### 2. Open in Xcode & build

```bash
open Retichat.xcodeproj
```

Select a signing team under **Signing & Capabilities**, pick a device or
simulator, and build.

Every build first runs the `RustLibrary` target (`xcode_build_rust.sh`), which
builds the Rust crate (always `--release`) for the device, simulator or Mac
Catalyst architectures being built, and the app links that library. cargo only
recompiles what changed, so an unchanged crate adds a second or two. There is
no separate Rust step to remember; `build_rust.sh` still builds the full
XCFramework if you want every slice at once.

### Optional: private push bridge configuration

Public builds compile and run without push-bridge registration configured.
If you want APNs bridge registration enabled for local/private builds, create:

```bash
cp PushBridgeConfig.plist.example Retichat/PushBridgeConfig.plist
```

Then fill in the two destination hashes in the copied plist. That file is
gitignored and will be bundled only in your local build.

## Architecture

| Layer | Technology |
|-------|-----------|
| UI | SwiftUI |
| Persistence | SwiftData |
| Networking & Crypto | Rust (via C FFI → XCFramework) |
| Push Notifications | APNs via Notification Service Extension |
| Current transport | TCP (internet or local-network hosts); no AutoInterface LAN discovery for now (iOS multicast needs an entitlement the app does not carry; on the Mac it took a VPN tunnel, 2026-10-12) |

## Roadmap

The following features are planned but are not ready for public use yet:

- LoRa / RNode transport support
- Group messaging
- Channels

### Key Design Decisions

- **Static linking** — iOS requires `staticlib` Rust crate type
- **C function pointers + void\* context** — callback bridge between Rust and Swift
- **Handle-based API** — Rust objects referenced by `UInt64` handles
- **NSLog integration** — Rust logs route through `NSLog`

## URL Scheme

The app registers the `lxma://` URL scheme. Scanning or tapping
`lxma://<32-char-hex-hash>` or `lxma://<32-char-hex-hash>.<128-char-hex-pubkey>`
opens a conversation with that destination. The older `lxmf://` scheme is also
accepted for backwards compatibility.

## Interoperability

Retichat uses the standard LXMF protocol and is interoperable with
[Sideband](https://github.com/markqvist/Sideband),
[NomadNet](https://github.com/markqvist/NomadNet), and other LXMF clients.

## License

MIT — see [LICENSE](LICENSE) for details.

## Default Endpoints

7 TCP transport endpoints are used when no custom interfaces are configured:
- Multiple geographic endpoints (US, EU, etc.)
- Ports 4242 and 4281
