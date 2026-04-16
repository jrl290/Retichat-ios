# App Links — Integration Handoff

## What was built (Rust side, LXMF-rust commit 591c875)

Three new C FFI functions for proactive link management, designed for "user
opens a chat screen → link is ready before they press send":

### C API (add to CRetichatFFI.h)

```c
#pragma mark - LXMF App Links

/// Open an app link.  Watches dest, requests path, establishes link
/// when path arrives.  Push-driven (no polling).  Link kept alive
/// automatically and exempt from inactivity cleanup.
/// Returns 0 on success, -1 on error.
int32_t lxmf_app_link_open(uint64_t client,
                            const uint8_t *dest_hash, uint32_t dest_len);

/// Close an app link.  Tears down the direct link.
/// Returns 0 on success, -1 on error.
int32_t lxmf_app_link_close(uint64_t client,
                             const uint8_t *dest_hash, uint32_t dest_len);

/// Query app link status.
///   0 = not tracked (NONE)
///   1 = path requested (PATH_REQUESTED)
///   2 = link establishing (ESTABLISHING)
///   3 = link active, ready to send (ACTIVE)
///   4 = disconnected, will reconnect on next announce (DISCONNECTED)
///  -1 = parameter error
int32_t lxmf_app_link_status(uint64_t client,
                              const uint8_t *dest_hash, uint32_t dest_len);
```

## How it works

1. **`lxmf_app_link_open(dest_hash)`** — called when the user opens a chat screen:
   - Adds dest to `app_links` set (exempt from inactivity teardown)
   - Adds dest to `watched_destinations` (LXMF level)
   - Adds dest to transport `announce_watchlist` (passes through even with `drop_announces`)
   - If path already known → creates link immediately
   - If no path → sends `request_path()`; the announce handler establishes the link when the path response arrives (push, no polling)

2. **`lxmf_app_link_close(dest_hash)`** — called when the user leaves the chat screen:
   - Removes from `app_links`
   - Tears down the direct link
   - Does NOT remove from `watched_destinations` (caller manages that separately)

3. **`lxmf_app_link_status(dest_hash)`** — snapshot of current state:
   - `0` NONE — not in app_links
   - `1` PATH_REQUESTED — waiting for path/announce
   - `2` ESTABLISHING — link handshake in progress
   - `3` ACTIVE — link is up, send will be instant
   - `4` DISCONNECTED — link failed/closed, will auto-reconnect on next announce

## Reconnection behavior

- If a link drops while the chat screen is open (status → DISCONNECTED), the
  next announce from that destination triggers `establish_app_link()` automatically
  via the delivery announce handler.  No polling, no timers.
- The link watchdog still sends keepalives per normal Reticulum protocol.
- `clean_links()` skips inactivity teardown for any dest in `app_links`.

## Integration points in Swift

### 1. Update CRetichatFFI.h
Add the three function declarations above.

### 2. Add to LxmfClient.swift
Follow the existing pattern (see `peerLinkStatus`):

```swift
// MARK: - App Links

func appLinkOpen(_ destHash: Data) -> Bool {
    destHash.withUnsafeBytes { buf -> Bool in
        let p = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
        return lxmf_app_link_open(handle, p, UInt32(destHash.count)) == 0
    }
}

func appLinkClose(_ destHash: Data) -> Bool {
    destHash.withUnsafeBytes { buf -> Bool in
        let p = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
        return lxmf_app_link_close(handle, p, UInt32(destHash.count)) == 0
    }
}

func appLinkStatus(_ destHash: Data) -> Int32 {
    destHash.withUnsafeBytes { buf -> Int32 in
        let p = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
        return lxmf_app_link_status(handle, p, UInt32(destHash.count))
    }
}
```

### 3. Call from chat screen lifecycle
- `onAppear` / `viewDidAppear` → `appLinkOpen(peer.destHash)`
- `onDisappear` / `viewDidDisappear` → `appLinkClose(peer.destHash)`
- UI can show link status indicator by reading `appLinkStatus()` reactively
  (e.g. after announce callback fires, which already triggers UI updates)

### 4. ConnectionStateManager
The existing `deliveryMethod()` check at line 103 uses `peerLinkStatus`.
With app links, when the chat screen is open, `appLinkStatus == 3` (ACTIVE)
means the link is pre-established → send is instant (no path request or link
establishment delay).  The `peerLinkStatus` call still works — it reads the
same `direct_links` table — but `appLinkStatus` gives richer state info.

## Relationship to existing APIs

| API | Level | Purpose |
|-----|-------|---------|
| `retichat_watch_announce` | Transport | Whitelist — prevent announce drop |
| `lxmf_client_watch` | LXMF | Process announces (stamp cost, outbound trigger) |
| `lxmf_peer_link_status` | LXMF | Read-only link check (0/1/2) |
| **`lxmf_app_link_open`** | **LXMF** | **Does all three above + establishes link** |
| **`lxmf_app_link_status`** | **LXMF** | **Richer status (5 states vs 3)** |

`app_link_open` calls `watch_announce` and `watch_destination` internally,
so the caller does NOT need to call those separately for chat-screen peers.

## XCFramework

Already rebuilt with `./build_rust.sh release` — all 5 targets compiled.
The `.a` files in the xcframework include the new symbols.  Just update
CRetichatFFI.h and the Swift wrapper.
