# Integration Test Handoff — April 16 2026

## Infrastructure

| Item | Value |
|---|---|
| rnsd transport | `192.168.2.107:4242` (Raspberry Pi, always running) |
| Prop node dest hash | `90c650419e3a991a0bbe4cb3123724a4` (`lxmf.propagation` aspect, rfed process) |
| rfed.node dest hash | `8c7ca26f7b4f640cc05a9f55494b3392` |
| RNS config | `enable_transport = no`, TCPClientInterface to `192.168.2.107:4242` |
| Python libs | `../../../../../../Reticulum-master/` and `../../../../../../LXMF-master/` |

## Running Tests

```bash
cd Retichat-ios/rust/retichat-ffi
cargo test --no-fail-fast -- --test-threads=1 --nocapture
```

## Current Test State

| Suite | Status | Notes |
|---|---|---|
| identity (4) | ✅ | |
| client_lifecycle (8) | ✅ | |
| announce (1) | ✅ | |
| messaging rust→python | ✅ | |
| messaging python→rust | ✅ | Fixed: ingress_control=false |
| propagation (2) | ✅ | Fixed: ingress_control=false |
| link_request (1) | ✅ | Fixed: rfed + path-wait |

**All 18 tests pass.**

## Fixes Applied This Session

1. **Announce handler never fired** (`Reticulum-rust/src/transport.rs`) — `extract_announce_name_hash` and `name_hash_for_aspect_filter` used `TRUNCATED_HASHLENGTH/8 = 16` bytes but the announce packet name hash field is only `NAME_HASH_LENGTH/8 = 10` bytes. Fixed both to use `NAME_HASH_LENGTH/8`. This silently broke all aspect-filtered announce callbacks.

2. **SIGSEGV after shutdown** (`LXMF-rust/src/ffi.rs`) — `router_destroy` now clears all callbacks before dropping the handle, preventing Transport background threads from calling into freed memory.

3. **Python prop-sender stuck in OUTBOUND** (`tests/python/rns_prop_sender.py`) — Added `router.set_outbound_propagation_node(prop_node_bytes)` (required by LXMF to route PROPAGATED messages). Added 15s path-wait. `PROP_NODE_HASH` env var passed from Rust harness.

4. **Mutex poisoning cascade** — All `TEST_MUTEX.lock().unwrap()` → `.unwrap_or_else(|e| e.into_inner())` across 5 test files.

5. **Transport singleton left live on panic** — Added `ClientGuard` RAII struct to `helpers/mod.rs`. `propagation.rs` updated to use it.

---

## Root Cause — Ingress Control (python→rust & propagation failures)

Python's `Interface.__init__` sets `ingress_control = True` by default. When a
TCPClientInterface connects to rnsd, rnsd sends a burst of cached announces
from other devices, triggering the `IC_BURST_FREQ_NEW = 3.5` threshold. Once
`ic_burst_active = True`, ALL announces for unknown destinations are held for
60 s + 300 s penalty — including the Rust client's announce.

`LocalInterface` (shared-instance clients) overrides `should_ingress_limit()` →
`False`, so they are never affected. Standalone TCP clients like our test
helpers use the default → get ingress-limited.

**Fix:** Added `ingress_control = false` to the TCP interface config template in
`tests/helpers/mod.rs`. This config is used by both Rust and Python test clients.
