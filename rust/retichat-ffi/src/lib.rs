//! C FFI bridge for Retichat iOS.
//!
//! This crate produces a static library (`libretichat_ffi.a`) linked into
//! the Swift app via an xcframework + bridging header.
//!
//! ## Two API layers
//!
//! | Prefix       | Source              | Scope                                 |
//! |--------------|---------------------|---------------------------------------|
//! | `lxmf_*`     | `lxmf_rust::cffi`   | Universal LXMF client FFI             |
//! | `retichat_*` | this file           | Transport, identity, packet, settings |
//!
//! The `lxmf_*` functions handle the full LXMF client lifecycle (start,
//! callbacks, messages, sync, shutdown).  The `retichat_*` functions below
//! provide transport-level operations, raw packet/link sending, standalone
//! identity utilities, and network settings that fall outside the LXMF scope.

// Re-export the universal C FFI layers so all symbols end up in
// this static library.
pub use lxmf_rust::cffi::*;
pub use reticulum_rust::cffi::*;

use std::ffi::CStr;
use std::os::raw::{c_char, c_void};
use std::sync::{Arc, Mutex};

use reticulum_rust::destination::{Destination, DestinationType};
use reticulum_rust::ffi as rns;
use reticulum_rust::identity::Identity;
use reticulum_rust::packet::Packet;
use reticulum_rust::transport::Transport;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

unsafe fn cstr_to_string(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    CStr::from_ptr(ptr).to_string_lossy().into_owned()
}

fn parse_destination_aspects(app: &str, aspects: &str) -> Vec<String> {
    let normalized_app = app.trim();
    let mut parsed: Vec<String> = aspects
        .split(|c| c == '.' || c == ',')
        .map(str::trim)
        .filter(|segment| !segment.is_empty())
        .map(|segment| segment.to_string())
        .collect();

    if parsed.first().map(|segment| segment.as_str()) == Some(normalized_app) {
        parsed.remove(0);
    }

    parsed
}

fn slice_from_raw(ptr: *const u8, len: u32) -> Vec<u8> {
    if ptr.is_null() || len == 0 {
        return Vec::new();
    }
    unsafe { std::slice::from_raw_parts(ptr, len as usize).to_vec() }
}

// ---------------------------------------------------------------------------
// Identity (standalone — for use outside the LXMF client lifecycle)
// ---------------------------------------------------------------------------

/// Load identity from raw bytes.  Returns handle or 0.
///
/// Use this when reconstructing a remote identity from announce data.
/// Clean up with [`retichat_identity_destroy`].
#[no_mangle]
pub extern "C" fn retichat_identity_from_bytes(bytes: *const u8, len: u32) -> u64 {
    let b = slice_from_raw(bytes, len);
    match rns::identity_from_bytes(&b) {
        Ok(h) => h,
        Err(e) => {
            rns::set_error(e);
            0
        }
    }
}

/// Get identity public key.  Writes to `out_buf` (must be >= 64 bytes).
/// Returns byte count written, or -1 on error.
#[no_mangle]
pub extern "C" fn retichat_identity_public_key(handle: u64, out_buf: *mut u8, buf_len: u32) -> i32 {
    match rns::identity_public_key(handle) {
        Ok(bytes) => {
            if buf_len < bytes.len() as u32 {
                rns::set_error("Buffer too small".into());
                return -1;
            }
            unsafe {
                std::ptr::copy_nonoverlapping(bytes.as_ptr(), out_buf, bytes.len());
            }
            bytes.len() as i32
        }
        Err(e) => {
            rns::set_error(e);
            -1
        }
    }
}

/// Sign `data` with the identity's Ed25519 signing key.
/// Writes 64-byte signature to `out_sig`. Returns 64 on success, -1 on error.
#[no_mangle]
pub extern "C" fn retichat_identity_sign(
    handle: u64,
    data: *const u8,
    data_len: u32,
    out_sig: *mut u8,
    sig_buf_len: u32,
) -> i32 {
    if sig_buf_len < 64 {
        rns::set_error("signature buffer too small (need 64)".into());
        return -1;
    }
    let d = slice_from_raw(data, data_len);
    match rns::identity_sign(handle, &d) {
        Ok(sig) => {
            unsafe {
                std::ptr::copy_nonoverlapping(sig.as_ptr(), out_sig, 64);
            }
            64
        }
        Err(e) => {
            rns::set_error(e);
            -1
        }
    }
}

/// Seed a known destination from a scanned public key.
///
/// Stores the mapping `dest_hash -> public_key` in the known-destinations
/// table so outbound encrypted sends can proceed before the first announce.
#[no_mangle]
pub extern "C" fn retichat_identity_remember_destination(
    dest_hash: *const u8,
    dest_hash_len: u32,
    public_key: *const u8,
    public_key_len: u32,
) -> i32 {
    let hash = slice_from_raw(dest_hash, dest_hash_len);
    let pub_key = slice_from_raw(public_key, public_key_len);

    if hash.is_empty() {
        rns::set_error("destination hash is empty".into());
        return -1;
    }

    if let Err(e) = Identity::from_public_key(&pub_key) {
        rns::set_error(format!("invalid public key: {}", e));
        return -1;
    }

    match Identity::remember_destination(&hash, &pub_key, None) {
        Ok(()) => 0,
        Err(e) => {
            rns::set_error(e);
            -1
        }
    }
}

#[no_mangle]
pub extern "C" fn retichat_identity_recall_public_key(
    dest_hash: *const u8,
    dest_hash_len: u32,
    out_buf: *mut u8,
    buf_len: u32,
) -> i32 {
    let hash = slice_from_raw(dest_hash, dest_hash_len);
    let Some(public_key) = Identity::recall_public_key(&hash) else { return -1; };
    if out_buf.is_null() || buf_len < public_key.len() as u32 { return -1; }
    unsafe { std::ptr::copy_nonoverlapping(public_key.as_ptr(), out_buf, public_key.len()); }
    public_key.len() as i32
}

#[no_mangle]
pub extern "C" fn retichat_identity_remember_lxmf_delivery(
    dest_hash: *const u8,
    dest_hash_len: u32,
    public_key: *const u8,
    public_key_len: u32,
) -> i32 {
    let claimed_hash = slice_from_raw(dest_hash, dest_hash_len);
    let public_key = slice_from_raw(public_key, public_key_len);
    let identity = match Identity::from_public_key(&public_key) {
        Ok(identity) => identity,
        Err(error) => { rns::set_error(error); return -1; }
    };
    let destination = match Destination::new_outbound(
        Some(identity), DestinationType::Single, "lxmf".into(), vec!["delivery".into()],
    ) {
        Ok(destination) => destination,
        Err(error) => { rns::set_error(error); return -1; }
    };
    if destination.hash != claimed_hash {
        rns::set_error("public key does not match claimed lxmf.delivery hash".into());
        return -1;
    }
    match Identity::remember_destination(&claimed_hash, &public_key, None) {
        Ok(()) => 0,
        Err(error) => { rns::set_error(error); -1 }
    }
}

/// Destroy a standalone identity handle.  Returns 0 on success, -1 on error.
///
/// Do **not** call this on the identity owned by an `lxmf_client` — that is
/// destroyed automatically by [`lxmf_client_shutdown`].
#[no_mangle]
pub extern "C" fn retichat_identity_destroy(handle: u64) -> i32 {
    match rns::identity_destroy(handle) {
        Ok(()) => 0,
        Err(e) => {
            rns::set_error(e);
            -1
        }
    }
}

// ---------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------

/// Check if transport has path to destination.  Returns 1/0.
#[no_mangle]
pub extern "C" fn retichat_transport_has_path(dest_hash: *const u8, len: u32) -> i32 {
    let h = slice_from_raw(dest_hash, len);
    if rns::transport_has_path(&h) {
        1
    } else {
        0
    }
}

/// Check whether the destination's current route has been verified by a live
/// announce in this process. Cached paths loaded from disk do not count.
/// Returns 1/0.
#[no_mangle]
pub extern "C" fn retichat_transport_path_verified_this_session(
    dest_hash: *const u8,
    len: u32,
) -> i32 {
    let h = slice_from_raw(dest_hash, len);
    if Transport::is_path_verified_this_session(&h) {
        1
    } else {
        0
    }
}

/// Block until the destination has a path verified in this process (a path
/// response or announce seen now, not a route loaded from disk), or
/// `budget_secs` pass. Event-driven (Transport::wait_for_path_verified_this_session),
/// no polling. Returns 1 when verified, 0 otherwise. For a caller that has no
/// run loop to wait on, such as the notification extension.
#[no_mangle]
pub extern "C" fn retichat_transport_wait_for_path_verified(
    dest_hash: *const u8,
    len: u32,
    budget_secs: f64,
) -> i32 {
    let h = slice_from_raw(dest_hash, len);
    let budget = std::time::Duration::from_secs_f64(budget_secs.max(0.0));
    if Transport::wait_for_path_verified_this_session(&h, budget) {
        1
    } else {
        0
    }
}

/// Check whether the destination's identity (public key) is in the
/// known-destinations table. Outbound encrypted send needs identity,
/// not just a path.  Returns 1/0.
#[no_mangle]
pub extern "C" fn retichat_identity_known(dest_hash: *const u8, len: u32) -> i32 {
    let h = slice_from_raw(dest_hash, len);
    if rns::identity_known(&h) {
        1
    } else {
        0
    }
}

/// Request path to destination.  Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn retichat_transport_request_path(dest_hash: *const u8, len: u32) -> i32 {
    let h = slice_from_raw(dest_hash, len);
    match rns::transport_request_path(&h) {
        Ok(()) => 0,
        Err(e) => {
            rns::set_error(e);
            -1
        }
    }
}

/// Get hop count to destination.  Returns hops or -1.
#[no_mangle]
pub extern "C" fn retichat_transport_hops_to(dest_hash: *const u8, len: u32) -> i32 {
    let h = slice_from_raw(dest_hash, len);
    rns::transport_hops_to(&h)
}

/// Query whether the cached path's attached interface is online.
/// Returns: 1 = online, 0 = offline, -1 = no path / unknown interface.
#[no_mangle]
pub extern "C" fn retichat_transport_path_interface_online(dest_hash: *const u8, len: u32) -> i32 {
    let h = slice_from_raw(dest_hash, len);
    let Some(interface_name) = Transport::next_hop_interface(&h) else {
        return -1;
    };
    rns::interface_online(&interface_name)
}

/// Soft-expire a cached path so the next lookup forces fresh path resolution.
/// Returns 1 if an existing path entry was expired, 0 if no cached path exists.
#[no_mangle]
pub extern "C" fn retichat_transport_drop_path(dest_hash: *const u8, len: u32) -> i32 {
    let h = slice_from_raw(dest_hash, len);
    if Transport::expire_path(&h) { 1 } else { 0 }
}

/// Write a consistent copy of the known destinations database (Reticulum-rust
/// known_destinations.rs) to `path`, for the notification extension's own
/// storage. A plain file copy of a live SQLite database can capture it
/// half-written. Returns 1 on success, 0 on error (see rns_last_error).
#[no_mangle]
pub extern "C" fn retichat_known_destinations_snapshot(path: *const c_char) -> i32 {
    let target = unsafe { cstr_to_string(path) };
    if target.is_empty() {
        rns::set_error("empty snapshot path".into());
        return 0;
    }
    match Identity::snapshot_known_destinations(std::path::Path::new(&target)) {
        Ok(()) => 1,
        Err(e) => {
            rns::set_error(e);
            0
        }
    }
}

/// Clone a live path entry from `source_hash` to `dest_hash` and, when the
/// source destination's public key is known, remember that same public key for
/// the destination hash. This is used for sibling SINGLE destinations on the
/// same remote identity (e.g. rfed.node -> rfed.notify).
///
/// Returns 1 if a live path entry was cloned, 0 otherwise.
#[no_mangle]
pub extern "C" fn retichat_transport_clone_path_and_identity(
    source_hash: *const u8,
    source_len: u32,
    dest_hash: *const u8,
    dest_len: u32,
) -> i32 {
    let source = slice_from_raw(source_hash, source_len);
    let dest = slice_from_raw(dest_hash, dest_len);
    if source.is_empty() || dest.is_empty() || source == dest {
        return 0;
    }

    if !Transport::clone_path(&source, &dest) {
        return 0;
    }

    if let Some(public_key) = Identity::recall_public_key(&source) {
        let _ = Identity::remember_destination(&dest, &public_key, None);
    }

    1
}

/// Force-flush the in-memory destination/path table to disk so newly
/// resolved essential paths survive a force-quit. Cheap (a few KB).
/// Returns 0 on success.
#[no_mangle]
pub extern "C" fn retichat_transport_save_paths() -> i32 {
    Transport::save_path_table();
    0
}

// ---------------------------------------------------------------------------
// Announce filtering & keepalive
// ---------------------------------------------------------------------------

/// Enable/disable announce filtering.  1 = enabled, 0 = disabled.
#[no_mangle]
pub extern "C" fn retichat_set_drop_announces(enabled: i32) {
    rns::set_drop_announces(enabled != 0);
}

/// Add a destination hash to the announce watchlist.
/// Announces from watchlisted destinations always pass through, even when
/// drop_announces is enabled.  `dest_hash` must be exactly 16 bytes.
#[no_mangle]
pub extern "C" fn retichat_watch_announce(dest_hash: *const u8, len: u32) {
    let h = slice_from_raw(dest_hash, len);
    rns::watch_announce(h);
}

/// Remove a destination hash from the announce watchlist.
#[no_mangle]
pub extern "C" fn retichat_unwatch_announce(dest_hash: *const u8, len: u32) {
    let h = slice_from_raw(dest_hash, len);
    rns::unwatch_announce(&h);
}

/// Set keepalive interval in seconds.  Returns 0 on success.
#[no_mangle]
pub extern "C" fn retichat_set_keepalive_interval(secs: f64) -> i32 {
    match rns::set_keepalive_interval(secs) {
        Ok(()) => 0,
        Err(e) => {
            rns::set_error(e);
            -1
        }
    }
}

// ---------------------------------------------------------------------------
// Raw packet send (used by APNs token registration)
// ---------------------------------------------------------------------------

/// Send a single encrypted DATA packet to a remote destination identified by
/// its 16-byte (truncated) destination hash.
///
/// The remote identity must already be in Reticulum's known-destinations table
/// (i.e. the destination's announce has been heard).  Returns 0 on success,
/// -1 on error (call `lxmf_last_error` for details).
///
/// NOTE: the actual transmission (`packet.send()`) is dispatched on a
/// background thread so this function returns immediately — Swift may
/// safely call it from the main thread. Synchronous errors (e.g. malformed
/// hash, unknown destination, packet construction) still return -1; send
/// failures discovered later are logged but cannot be surfaced to the
/// caller. ApnsTokenRegistrar's retry loop tolerates this because it
/// drives retries from its own state, not from this return value.
#[no_mangle]
pub extern "C" fn retichat_packet_send_to_hash(
    dest_hash: *const u8,
    dest_hash_len: u32,
    app_name: *const c_char,
    aspects: *const c_char,
    payload: *const u8,
    payload_len: u32,
) -> i32 {
    let hash = slice_from_raw(dest_hash, dest_hash_len);
    let app = unsafe { cstr_to_string(app_name) };
    let asp_str = unsafe { cstr_to_string(aspects) };
    let asp_vec = parse_destination_aspects(&app, &asp_str);
    let payload_data = slice_from_raw(payload, payload_len);

    let dest_handle = match rns::destination_create_outbound_from_hash(&hash, &app, asp_vec) {
        Ok(h) => h,
        Err(e) => {
            rns::set_error(e);
            return -1;
        }
    };

    let packet_handle = match rns::packet_create(dest_handle, &payload_data, false) {
        Ok(h) => h,
        Err(e) => {
            rns::destroy_handle(dest_handle);
            rns::set_error(e);
            return -1;
        }
    };
    rns::destroy_handle(dest_handle);

    // Dispatch the blocking send to a background thread so iOS Swift
    // callers (notably ApnsTokenRegistrar) can invoke us without
    // risking a main-thread stall if Transport::outbound is contended.
    std::thread::Builder::new()
        .name("retichat-packet-send".to_string())
        .spawn(move || {
            if let Err(e) = rns::packet_send(packet_handle) {
                eprintln!("[retichat-ffi] packet_send dispatch failed: {}", e);
            }
        })
        .map(|_| 0)
        .unwrap_or_else(|e| {
            rns::set_error(format!("failed to spawn send thread: {}", e));
            -1
        })
}

// ---------------------------------------------------------------------------
// Link-based request (synchronous one-shot)
// ---------------------------------------------------------------------------

/// Open a Link to a remote destination, identify, send a request, wait for
/// response, tear down, and return the response bytes.
///
/// This is a **blocking** call — Swift must call it from a background thread.
///
/// Returns a pointer to the response bytes (caller must free with
/// `lxmf_free_bytes`), or NULL on error (check `lxmf_last_error`).
#[no_mangle]
pub extern "C" fn retichat_link_request(
    dest_hash: *const u8,
    dest_hash_len: u32,
    app_name: *const c_char,
    aspects: *const c_char,
    identity_handle: u64,
    path: *const c_char,
    payload: *const u8,
    payload_len: u32,
    timeout_secs: f64,
    out_len: *mut u32,
) -> *mut u8 {
    let hash = slice_from_raw(dest_hash, dest_hash_len);
    let app = unsafe { cstr_to_string(app_name) };
    let asp_str = unsafe { cstr_to_string(aspects) };
    let asp_vec = parse_destination_aspects(&app, &asp_str);
    let p = unsafe { cstr_to_string(path) };
    let data = slice_from_raw(payload, payload_len);

    match rns::link_request(
        &hash,
        &app,
        asp_vec,
        identity_handle,
        &p,
        &data,
        timeout_secs,
    ) {
        Ok(response) => {
            let len = response.len() as u32;
            let boxed = response.into_boxed_slice();
            let raw = Box::into_raw(boxed);
            if !out_len.is_null() {
                unsafe {
                    *out_len = len;
                }
            }
            raw as *mut u8
        }
        Err(e) => {
            rns::set_error(e);
            std::ptr::null_mut()
        }
    }
}

// ---------------------------------------------------------------------------
// RFed delivery fallback (legacy inbound channel blob endpoint)
// ---------------------------------------------------------------------------

type RfedBlobCallback = Option<extern "C" fn(*mut c_void, *const u8, u32)>;

#[derive(Copy, Clone)]
struct RfedDeliveryCallbackState {
    callback: RfedBlobCallback,
    ctx: usize,
}

struct RfedDeliveryState {
    dest: Destination,
}

static RFED_DELIVERY: Mutex<Option<RfedDeliveryState>> = Mutex::new(None);
static RFED_DELIVERY_CB: Mutex<Option<RfedDeliveryCallbackState>> = Mutex::new(None);

#[no_mangle]
pub extern "C" fn retichat_rfed_delivery_start(
    identity_handle: u64,
    callback: RfedBlobCallback,
    context: *mut c_void,
) -> i32 {
    let identity: Identity = match rns::get_handle::<Identity>(identity_handle) {
        Some(id) => id,
        None => {
            rns::set_error("invalid identity handle".into());
            return -1;
        }
    };

    if RFED_DELIVERY.lock().unwrap().is_some() {
        let _ = retichat_rfed_delivery_stop();
    }

    let mut dest = match Destination::new_inbound(
        Some(identity),
        DestinationType::Single,
        "rfed".to_string(),
        vec!["delivery".to_string()],
    ) {
        Ok(d) => d,
        Err(e) => {
            rns::set_error(e);
            return -1;
        }
    };
    // Prove every packet RFed delivers here, so RFed can count a delivery
    // only when it is proved and queue and push the rest (RFed SPEC §7).
    // Until 2026-09-26 nothing was proved.
    if let Err(e) = dest.set_proof_strategy(reticulum_rust::destination::PROVE_ALL) {
        rns::set_error(e);
        return -1;
    }

    *RFED_DELIVERY_CB.lock().unwrap() = Some(RfedDeliveryCallbackState {
        callback,
        ctx: context as usize,
    });

    let packet_cb: Arc<dyn Fn(&[u8], &Packet) + Send + Sync> = Arc::new(move |data: &[u8], _pkt: &Packet| {
        let guard = RFED_DELIVERY_CB.lock().unwrap();
        let Some(state) = guard.as_ref() else { return; };
        let Some(callback) = state.callback else { return; };
        callback(state.ctx as *mut c_void, data.as_ptr(), data.len() as u32);
    });
    dest.set_packet_callback(Some(packet_cb));
    Transport::register_destination(dest.clone());

    // Keep the compatibility destination published so mixed-version RFed nodes
    // always have a fresh path back to this device when stream receive is absent.
    Transport::publish_destination(
        dest.hash.clone(),
        Some(std::time::Duration::from_secs(30 * 60)),
        None,
    );

    *RFED_DELIVERY.lock().unwrap() = Some(RfedDeliveryState { dest });
    0
}

#[no_mangle]
pub extern "C" fn retichat_rfed_delivery_announce() -> i32 {
    let mut guard = RFED_DELIVERY.lock().unwrap();
    if let Some(ref mut state) = *guard {
        if let Err(e) = state.dest.announce(None, false, None, None, true) {
            rns::set_error(e);
            return -1;
        }
        return 0;
    }

    rns::set_error("rfed delivery not started".into());
    -1
}

#[no_mangle]
pub extern "C" fn retichat_rfed_delivery_stop() -> i32 {
    let mut guard = RFED_DELIVERY.lock().unwrap();
    if let Some(state) = guard.take() {
        Transport::unpublish_destination(&state.dest.hash);
        Transport::deregister_destination(&state.dest.hash);
    }
    *RFED_DELIVERY_CB.lock().unwrap() = None;
    0
}

// ---------------------------------------------------------------------------
// Channel crypto
// ---------------------------------------------------------------------------

/// Derive a channel keypair from `name` (e.g. "public.general") and use the
/// channel's X25519 public key to encrypt `plaintext`.
///
/// Returns a heap-allocated ciphertext (free with `lxmf_free_bytes`) or NULL
/// on error.  Wire format: `ephemeral_x25519_pub(32) | iv(16) | aes_cbc_ct | hmac(32)`.
fn channel_private_key_bytes(name: &str) -> [u8; 64] {
    // SHA-256(name) as both the X25519 and the Ed25519 seed, mirroring
    // ChannelKeypair::from_name in RFed-rust/rfed/src/channel.rs.
    lxmf_rust::channel::channel_private_key_bytes(name)
}

#[no_mangle]
pub extern "C" fn retichat_channel_encrypt(
    name_ptr: *const c_char,
    plaintext: *const u8,
    plaintext_len: u32,
    out_len: *mut u32,
) -> *mut u8 {
    let name = unsafe { cstr_to_string(name_ptr) };
    let pt = slice_from_raw(plaintext, plaintext_len);
    let prv = channel_private_key_bytes(&name);
    let identity = match Identity::from_bytes(&prv) {
        Ok(id) => id,
        Err(e) => {
            rns::set_error(e);
            unsafe {
                *out_len = 0;
            }
            return std::ptr::null_mut();
        }
    };
    match identity.encrypt(&pt) {
        Ok(ct) => {
            let len = ct.len() as u32;
            let mut boxed = ct.into_boxed_slice();
            let ptr = boxed.as_mut_ptr();
            std::mem::forget(boxed);
            unsafe {
                *out_len = len;
            }
            ptr
        }
        Err(e) => {
            rns::set_error(e);
            unsafe {
                *out_len = 0;
            }
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub extern "C" fn retichat_channel_decrypt(
    name_ptr: *const c_char,
    ciphertext: *const u8,
    ciphertext_len: u32,
    out_len: *mut u32,
) -> *mut u8 {
    let name = unsafe { cstr_to_string(name_ptr) };
    let ct = slice_from_raw(ciphertext, ciphertext_len);
    let prv = channel_private_key_bytes(&name);
    let mut identity = match Identity::from_bytes(&prv) {
        Ok(id) => id,
        Err(e) => {
            rns::set_error(e);
            unsafe {
                *out_len = 0;
            }
            return std::ptr::null_mut();
        }
    };
    match identity.decrypt(&ct) {
        Ok(pt) => {
            let len = pt.len() as u32;
            let mut boxed = pt.into_boxed_slice();
            let ptr = boxed.as_mut_ptr();
            std::mem::forget(boxed);
            unsafe {
                *out_len = len;
            }
            ptr
        }
        Err(e) => {
            rns::set_error(e);
            unsafe {
                *out_len = 0;
            }
            std::ptr::null_mut()
        }
    }
}

/// Compute a PoW stamp for a channel SEND packet.
///
/// `payload` is the entire wire payload that will be sent BEFORE the stamp
/// is appended — i.e. `channel_id_hash(16) | EC_encrypted_tail`.
/// `cost` is the `stamp_cost` value the rfed node returned in its
/// `/rfed/subscribe` response.
///
/// Returns a heap-allocated 32-byte stamp (free with `lxmf_free_bytes`).
/// Returns NULL when `cost == 0` (no stamp required) — `*out_len` set to 0.
/// Returns NULL on failure (e.g. the PoW search ran out of iterations
/// without finding a stamp meeting `cost`); call `lxmf_last_error` for
/// the reason.
///
/// ─── STAMP CONTRACT — DO NOT BREAK ─────────────────────────────────────
///   * `transient_id = identity::full_hash(payload)`
///   * `workblock    = LXStamper::stamp_workblock(transient_id, 16)`
///   * `stamp_value(workblock, stamp) >= cost`
///   * `STAMP_EXPAND_ROUNDS = 16` MUST match
///     `RFed-rust/rfed/src/destinations.rs::STAMP_EXPAND_ROUNDS`.
///   * `payload` MUST be byte-identical to what the rfed SEND handler
///     sees as `data[..data.len() - LXStamper::STAMP_SIZE]`.  Any change
///     to wire format → both sides must change in lock-step.
///
/// See `RFed-rust/rfed/src/config.rs` (TierPolicy section) and
/// `/memories/repo/retichat-rfed-channel-integration.md` for the full
/// contract and historical regressions.
#[no_mangle]
pub extern "C" fn retichat_compute_channel_stamp(
    payload: *const u8,
    payload_len: u32,
    cost: u32,
    out_len: *mut u32,
) -> *mut u8 {
    use reticulum_rust::lxstamper::LXStamper;
    if cost == 0 {
        unsafe {
            *out_len = 0;
        }
        return std::ptr::null_mut();
    }
    let data = slice_from_raw(payload, payload_len);
    let transient_id = reticulum_rust::identity::full_hash(&data);
    let workblock = LXStamper::stamp_workblock(&transient_id, 16);
    let (stamp, value) = LXStamper::generate_stamp(&transient_id, cost, 16);
    // generate_stamp no longer returns a sub-cost stamp when it gives up — it
    // returns None — so the workaround this comment used to describe is gone.
    // The check stays: it still catches a workblock mismatch against the SAME
    // workblock the rfed node uses, rather than letting the node reject it.
    let stamp = stamp.unwrap_or_default();
    if value < cost || !LXStamper::stamp_valid(&stamp, cost, &workblock) {
        rns::set_error(format!(
            "stamp PoW failed: required cost={} but achieved value={} (payload_len={}). \
             Either iteration cap exceeded or workblock mismatch.",
            cost,
            value,
            data.len()
        ));
        unsafe {
            *out_len = 0;
        }
        return std::ptr::null_mut();
    }
    let len = stamp.len() as u32;
    let mut boxed = stamp.into_boxed_slice();
    let ptr = boxed.as_mut_ptr();
    std::mem::forget(boxed);
    unsafe {
        *out_len = len;
    }
    ptr
}

// ---------------------------------------------------------------------------
// LXMF channel pack / unpack  (AUTHORITATIVE FORMAT)
// ---------------------------------------------------------------------------
//
// CHANNEL MESSAGES ARE LXMF PACKAGES.  THEY ARE LXMF PACKAGES.
//
// On the wire, the payload going to RFed (and what RFed forwards to each
// subscriber) carries the EXACT same authentication payload an LXMF
// propagation node carries — i.e. the EC-encrypted tail produced by
// `LXMessage::pack(PROPAGATED)`:
//
//     wire_payload = [ channel_id_hash(16) | EC_encrypted(
//                          source_hash (16) || signature (64) || msgpack_payload
//                      ) ]
//
// `channel_id_hash` is the channel identity hash — the same 16-byte routing
// label that subscribers registered with RFed via `/rfed/subscribe` and
// that RFed uses as the `subscription_table` key.  The encrypted tail is
// byte-identical to what an LXMF propagation node carries.
//
// The receiver:
//   1. EC-decrypts the encrypted tail using the channel identity (derived
//      deterministically from the channel name).
//   2. Reconstructs the canonical LXMF block:
//          [ lxmf_dest_hash(16) | source_hash(16) | signature(64) | payload ]
//      where `lxmf_dest_hash` is the `lxmf.delivery` destination hash for
//      the channel identity — i.e. exactly the dest_hash the sender used
//      inside `LXMessage::pack(PROPAGATED)` when it computed the signature.
//   3. Calls `LXMessage::unpack_from_bytes(_, Some(PROPAGATED))`, which
//      parses dest/source/sig/payload (timestamp, title, content, fields),
//      recalls the source identity from Reticulum's known-destinations
//      table, and validates the Ed25519 signature → `signature_validated`.
//      Emits `unverified_reason = SOURCE_UNKNOWN` if the sender hasn't
//      been seen via an announce yet (i.e. you cannot prove who the
//      message is from).
//
// Why the wire prefix is `channel_id_hash` and not the LXMF
// `lxmf.delivery` destination hash: RFed routes channel messages by the
// channel identity hash (subscribers signed it during `/rfed/subscribe`).
// Wrapping the LXMF authentication payload behind that label keeps the
// RFed routing model intact while still requiring an LXMF-valid signature
// from a known sender to deliver — i.e. you cannot prove who the message
// is from unless the sender's identity is in the cache.
//
// The legacy custom plaintext layout (sender_hash | ts_be | pubkey | sig |
// content_utf8 inside `channel_encrypt`) is GONE.  Do not reintroduce it.

// ---------------------------------------------------------------------------
// SOURCE-IDENTITY PRELUDE AND KEY BINDING — DO NOT BREAK
// ---------------------------------------------------------------------------
//
// The decrypted post is
//
//     [ b"RTID" (4) | sender_identity_pub (64) | source_hash (16) | sig (64) | msgpack_payload ]
//
// The prelude carries the sender's public key so the LXMF signature can be
// checked without waiting for the sender's announce. Unpack checks that
// the key produces the claimed source hash as an `lxmf.delivery`
// destination BEFORE remembering it, and rejects the post otherwise
// (DISPLAY_NAMES.md §2.3): the channel key is derived from the channel's
// name, so anyone who knows the name can post, and without the check could
// post as a contact and overwrite that contact's stored key.
//
// Pack and unpack live once in `lxmf_rust::channel`, shared with the
// Android JNI bridge; these functions are thin wrappers.

fn channel_out_error(out_len: *mut u32, message: String) -> *mut u8 {
    rns::set_error(message);
    if !out_len.is_null() {
        unsafe {
            *out_len = 0;
        }
    }
    std::ptr::null_mut()
}

fn channel_out_buffer(bytes: Vec<u8>, out_len: *mut u32) -> *mut u8 {
    if out_len.is_null() {
        rns::set_error("out_len is NULL".into());
        return std::ptr::null_mut();
    }
    let len = bytes.len() as u32;
    let mut boxed = bytes.into_boxed_slice();
    let ptr = boxed.as_mut_ptr();
    std::mem::forget(boxed);
    unsafe {
        *out_len = len;
    }
    ptr
}

/// Build a channel post (an LXMF message addressed to the channel) and pack
/// it into the on-wire payload. The caller appends the optional PoW stamp
/// and sends `output[8..]` as the `rfed.channel` SEND payload.
///
/// Inputs:
///   * `name_ptr`            — channel name (UTF-8 C string), e.g. "public.general"
///   * `sender_handle`       — identity handle of the local user (the *source*)
///   * `content_ptr/_len`    — message body bytes (UTF-8)
///   * `title_ptr/_len`      — optional title bytes (UTF-8); NULL/0 for none
///   * `display_name_state`  — the Channel Display Name to carry in key 0 of
///                             field 0xD1 (DISPLAY_NAMES.md §2.3, §4.2): 0 =
///                             none (no 0xD1; the bytes are exactly the
///                             pre-name format), 1 = clear ({0xD1: {0: empty
///                             bin}}), 2 = the name
///                             in `display_name_ptr/_len`
///   * `display_name_ptr/_len` — raw UTF-8 name for state 2 (cleaned here;
///                             a name that cleans to nothing is an error)
///
/// Returns a heap-allocated buffer (free with `lxmf_free_bytes`), or NULL on
/// error (call `lxmf_last_error`):
///
/// ```text
/// offset  size  field
/// ------  ----  -----
/// 0       8     timestamp_ms_be    (u64 BE) — the LXMF timestamp in the
///                                   signed payload, for echo dedup.
/// 8       16    channel_id_hash    (the routing label for RFed)
/// 24      *     EC_encrypted(prelude || source_hash || signature || msgpack_payload)
/// ```
#[no_mangle]
pub extern "C" fn retichat_channel_lxm_pack(
    name_ptr: *const c_char,
    sender_handle: u64,
    content_ptr: *const u8,
    content_len: u32,
    title_ptr: *const u8,
    title_len: u32,
    display_name_state: u8,
    display_name_ptr: *const u8,
    display_name_len: u32,
    out_len: *mut u32,
) -> *mut u8 {
    let name = unsafe { cstr_to_string(name_ptr) };
    let content = slice_from_raw(content_ptr, content_len);
    let title = slice_from_raw(title_ptr, title_len);
    let post_name = match lxmf_rust::channel::post_name_from_state(
        display_name_state,
        &slice_from_raw(display_name_ptr, display_name_len),
    ) {
        Ok(post_name) => post_name,
        Err(e) => return channel_out_error(out_len, e),
    };
    let Some(sender) = rns::get_handle::<Identity>(sender_handle) else {
        return channel_out_error(out_len, "invalid sender identity handle".into());
    };
    match lxmf_rust::channel::pack(&name, &sender, &content, &title, &post_name) {
        Ok(post) => channel_out_buffer(post.to_bridge_bytes(), out_len),
        Err(e) => channel_out_error(out_len, e),
    }
}

/// Unpack a channel post received via RFed.
///
/// Input is the wire payload as `retichat_channel_lxm_pack` produced it
/// (without the 8-byte timestamp prefix):
///     [ channel_id_hash(16) | EC_encrypted(prelude || source_hash || signature || payload) ]
///
/// A post whose prelude key does not produce its claimed source hash is
/// rejected (NULL, `lxmf_last_error` says "key binding") and no key is
/// remembered (DISPLAY_NAMES.md §2.3).
///
/// Returns a heap-allocated buffer (free with `lxmf_free_bytes`), or NULL on
/// error:
///
/// ```text
/// offset      size  field
/// ------      ----  -----
/// 0           16    source_hash
/// 16          8     timestamp_ms_be      (u64, big-endian, milliseconds)
/// 24          1     signature_validated  (1 = OK, 0 = NOT verified)
/// 25          1     unverified_reason    (0 = ok, 1 = SOURCE_UNKNOWN,
///                                         2 = SIGNATURE_INVALID)
/// 26          2     title_len_be         (u16, big-endian)
/// 28          4     content_len_be       (u32, big-endian)
/// 32          t     title bytes (UTF-8)
/// 32+t        c     content bytes (UTF-8)
/// 32+t+c      1     name_state           (0 = absent, 1 = clear, 2 = name)
/// 33+t+c      2     name_len_be          (u16, big-endian; 0 unless state 2)
/// 35+t+c      n     name bytes           (cleaned UTF-8)
/// ```
///
/// The name trailer is new (2026-09-27) and sits at the end, so decoders
/// that read the first 32+t+c bytes keep working. It reports the post's
/// Channel Display Name only when the signature validated; otherwise the
/// state is 0.
#[no_mangle]
pub extern "C" fn retichat_channel_lxm_unpack(
    name_ptr: *const c_char,
    lxmf_data: *const u8,
    lxmf_data_len: u32,
    out_len: *mut u32,
) -> *mut u8 {
    let name = unsafe { cstr_to_string(name_ptr) };
    let data = slice_from_raw(lxmf_data, lxmf_data_len);
    match lxmf_rust::channel::unpack(&name, &data).and_then(|post| post.to_bridge_bytes()) {
        Ok(bytes) => channel_out_buffer(bytes, out_len),
        Err(e) => channel_out_error(out_len, e),
    }
}

// ── Distro ───────────────────────────────────────────────────────────────────
//
// Thin FFI over `lxmf_rust::distro`. The payload construction and blob
// unwrapping live there, once, shared with the Android bridge — wire formats
// are the one thing that must not be written twice per platform.
//
// Every function returns a heap buffer the caller frees with
// `rns_free_bytes`, matching the channel functions above.

fn distro_identity(handle: u64, label: &str) -> Option<reticulum_rust::identity::Identity> {
    match rns::get_handle::<reticulum_rust::identity::Identity>(handle) {
        Some(id) => Some(id),
        None => {
            rns::set_error(format!("invalid {label} identity handle"));
            None
        }
    }
}

fn emit_buffer(bytes: Vec<u8>, out_len: *mut u32) -> *mut u8 {
    let len = bytes.len() as u32;
    let mut boxed = bytes.into_boxed_slice();
    let ptr = boxed.as_mut_ptr();
    std::mem::forget(boxed);
    unsafe {
        *out_len = len;
    }
    ptr
}

fn emit_error(out_len: *mut u32, message: String) -> *mut u8 {
    rns::set_error(message);
    unsafe {
        *out_len = 0;
    }
    std::ptr::null_mut()
}

/// msgpack payload for `/rfed/distro/register` and `/rfed/distro/unregister`.
///
/// Signed with the DISTRO key over the device public key — that signature is
/// what proves the caller may enrol a device under this distro.
#[no_mangle]
pub extern "C" fn retichat_distro_register_payload(
    device_handle: u64,
    distro_handle: u64,
    out_len: *mut u32,
) -> *mut u8 {
    let (Some(device), Some(distro)) = (
        distro_identity(device_handle, "device"),
        distro_identity(distro_handle, "distro"),
    ) else {
        unsafe { *out_len = 0; }
        return std::ptr::null_mut();
    };

    match lxmf_rust::distro::register_payload(&device, &distro) {
        Ok(bytes) => emit_buffer(bytes, out_len),
        Err(e) => emit_error(out_len, e),
    }
}

/// msgpack payload for `/rfed/distro/list`.
#[no_mangle]
pub extern "C" fn retichat_distro_list_payload(distro_handle: u64, out_len: *mut u32) -> *mut u8 {
    let Some(distro) = distro_identity(distro_handle, "distro") else {
        unsafe { *out_len = 0; }
        return std::ptr::null_mut();
    };
    match lxmf_rust::distro::list_payload(&distro) {
        Ok(bytes) => emit_buffer(bytes, out_len),
        Err(e) => emit_error(out_len, e),
    }
}

/// msgpack payload for `/rfed/distro/announce`.
///
/// RFed only ever learns the distro public key, so it cannot sign an announce
/// for the distro address itself. Without this the address resolves nowhere.
///
/// `announce_name/_len` is the raw UTF-8 Announce Display Name
/// (DISPLAY_NAMES.md §2.2), NULL/0 for none. The announce app_data is
/// `[name | nil, nil, [0xD0]]`, the name cleaned with the announce rules.
/// (Until 2026-09-27 this argument was caller app_data; every caller passed
/// NULL, which still means "no name".)
#[no_mangle]
pub extern "C" fn retichat_distro_announce_payload(
    distro_handle: u64,
    announce_name: *const u8,
    announce_name_len: u32,
    out_len: *mut u32,
) -> *mut u8 {
    let Some(distro) = distro_identity(distro_handle, "distro") else {
        unsafe { *out_len = 0; }
        return std::ptr::null_mut();
    };
    let name = if announce_name.is_null() || announce_name_len == 0 {
        None
    } else {
        Some(slice_from_raw(announce_name, announce_name_len))
    };
    match lxmf_rust::distro::announce_payload(&distro, name.as_deref()) {
        Ok(bytes) => emit_buffer(bytes, out_len),
        Err(e) => emit_error(out_len, e),
    }
}

/// The distro's `lxmf.delivery` hash — the address senders use. NOT the
/// identity hash, which is a different value and routes nowhere.
#[no_mangle]
pub extern "C" fn retichat_distro_delivery_hash(
    distro_handle: u64,
    out_buf: *mut u8,
    buf_len: u32,
) -> i32 {
    if buf_len < 16 {
        rns::set_error("delivery hash buffer too small (need 16)".into());
        return -1;
    }
    let Some(distro) = distro_identity(distro_handle, "distro") else { return -1 };
    match lxmf_rust::distro::delivery_hash(&distro) {
        Ok(hash) => {
            unsafe { std::ptr::copy_nonoverlapping(hash.as_ptr(), out_buf, 16); }
            16
        }
        Err(e) => {
            rns::set_error(e);
            -1
        }
    }
}

/// Decrypt a distro blob and return the message as JSON.
///
/// JSON rather than a struct because this is a client-internal boundary, not a
/// wire format: Swift decodes it with JSONDecoder and no manual field
/// marshalling. Returns a zero-length buffer (not an error) when the blob is
/// addressed to a different distro, which a node may legitimately hand over.
///
/// Fields: source_hash (hex), timestamp, title, content,
/// is_delivery_notification, ticket, distro_transfer_key, sent_to, sent_by,
/// display_name_state, display_name, signature_validated, unverified_reason.
/// sent_to/sent_by are the RFed SPEC §17.11 sent-message sync marker (null
/// unless the message is a sync copy; a non-null sent_by with a null sent_to
/// is a copy with a malformed 0xFC) — same keys as Android's nativeDistroUnwrap.
/// display_name_state is 0 absent, 1 clear, 2 name (display_name is the
/// cleaned name, null unless 2); signature_validated / unverified_reason
/// (0 ok, 1 source unknown, 2 signature invalid) decide whether to accept it
/// (DISPLAY_NAMES.md §5.2).
#[no_mangle]
pub extern "C" fn retichat_distro_unwrap(
    distro_handle: u64,
    blob: *const u8,
    blob_len: u32,
    out_len: *mut u32,
) -> *mut u8 {
    let Some(mut distro) = distro_identity(distro_handle, "distro") else {
        unsafe { *out_len = 0; }
        return std::ptr::null_mut();
    };
    let data = slice_from_raw(blob, blob_len);

    match lxmf_rust::distro::unwrap_blob(&mut distro, &data) {
        Ok(None) => emit_buffer(Vec::new(), out_len),
        Ok(Some(msg)) => emit_buffer(msg.to_json().into_bytes(), out_len),
        Err(e) => emit_error(out_len, e),
    }
}

/// Generate a fresh distro private key (64 bytes: X25519_priv || Ed25519_priv).
///
/// Goes through Identity::new so key generation matches every other identity in
/// the stack. Callers must not substitute 64 random bytes of their own — the
/// halves are not interchangeable and a subtly wrong key fails later, at
/// decrypt time, far from the mistake.
#[no_mangle]
pub extern "C" fn retichat_distro_generate(out_len: *mut u32) -> *mut u8 {
    let identity = reticulum_rust::identity::Identity::new(true);
    match identity.get_private_key() {
        Ok(key) => emit_buffer(key, out_len),
        Err(e) => emit_error(out_len, e),
    }
}

// ---------------------------------------------------------------------------
// Distro: sending identity and flags
// ---------------------------------------------------------------------------
//
// The Swift side needs two things the `lxmf_*` layer cannot give it: to ask
// whether a destination is a distro (so a send can propagate at once instead
// of waiting on a direct link nothing answers), and to create a message whose
// source is the distro rather than the device (so replies reach every device).
// Both are thin wrappers over lxmf_rust::ffi, exactly as Android exposes them
// in Retichat-android/rust/retichat-jni/src/lib.rs.

/// 1 if `dest_hash`'s last `lxmf.delivery` announce carried `SF_RFED_DISTRO`
/// (0xD0), else 0 — RFed SPEC §17.10.
///
/// The announce flag is the only way an address is known to be a distro:
/// `lxma://` links carry a key, never distro-ness. An unknown destination is
/// therefore not a distro, and a wrong-length hash is not one either rather
/// than an error, so the caller's send path has a single boolean to act on.
/// Mirrors Android `nativePeerIsDistro` (retichat-jni lib.rs:866-879).
#[no_mangle]
pub extern "C" fn retichat_peer_is_distro(dest_hash: *const u8, dest_len: u32) -> u8 {
    if dest_len != 16 {
        return 0;
    }
    let h = slice_from_raw(dest_hash, dest_len);
    if h.len() != 16 {
        return 0;
    }
    lxmf_rust::ffi::peer_is_distro(&h) as u8
}

/// Create an outbound message with a caller-chosen source address and signing
/// identity. Returns a message handle, or 0 with `rns_last_error` set.
///
/// iOS counterpart of Android `nativeMessageCreate` (retichat-jni
/// lib.rs:766-783). `lxmf_message_new` always signs as the client's device
/// identity; a device holding a distro must instead send AS the distro
/// (source = distro `lxmf.delivery` hash, signed with the distro key) so the
/// recipient's reply is addressed to the distro and fans out to every device.
///
/// The handle lives in the same global HANDLES store as every other message,
/// so all `lxmf_message_*` functions (add_field, send_via_app_links, hash,
/// clone_propagated, destroy) accept it.
///
/// `method` is the raw LXMF constant: 0x01 opportunistic, 0x02 direct,
/// 0x03 propagated. (The "0/1/2" doc on lxmf_rust::ffi::message_create is
/// stale — the value is passed straight through as `desired_method`.)
#[no_mangle]
pub extern "C" fn retichat_message_create(
    dest_hash: *const u8,
    dest_len: u32,
    src_hash: *const u8,
    src_len: u32,
    content: *const c_char,
    title: *const c_char,
    method: u8,
    source_identity_handle: u64,
) -> u64 {
    // Checked here rather than left to LXMessage: a wrong-length source hash
    // would otherwise produce a message that packs but never verifies at the
    // recipient, a failure far from its cause.
    if dest_len != 16 || src_len != 16 {
        rns::set_error(format!(
            "message_create: hashes must be 16 bytes (dest {dest_len}, src {src_len})"
        ));
        return 0;
    }
    let d = slice_from_raw(dest_hash, dest_len);
    let s = slice_from_raw(src_hash, src_len);
    if d.len() != 16 || s.len() != 16 {
        rns::set_error("message_create: null destination or source hash".into());
        return 0;
    }
    let c = unsafe { cstr_to_string(content) };
    let t = unsafe { cstr_to_string(title) };

    match lxmf_rust::ffi::message_create(&d, &s, &c, &t, method, source_identity_handle) {
        Ok(h) => h,
        Err(e) => {
            rns::set_error(e);
            0
        }
    }
}

#[cfg(test)]
mod distro_send_tests {
    use super::*;
    use std::ffi::CString;

    fn distro_handle_and_delivery() -> (u64, [u8; 16]) {
        let mut key_len: u32 = 0;
        let key_ptr = retichat_distro_generate(&mut key_len);
        assert!(!key_ptr.is_null() && key_len == 64, "distro key generation");
        let key = unsafe { std::slice::from_raw_parts(key_ptr, key_len as usize).to_vec() };
        rns_free_bytes(key_ptr, key_len);

        let handle = retichat_identity_from_bytes(key.as_ptr(), key.len() as u32);
        assert_ne!(handle, 0, "identity_from_bytes on a distro private key");

        let mut delivery = [0u8; 16];
        assert_eq!(retichat_distro_delivery_hash(handle, delivery.as_mut_ptr(), 16), 16);
        (handle, delivery)
    }

    /// message_create needs no running stack: it only builds an LXMessage
    /// from a stored identity handle, so this runs offline.
    #[test]
    fn message_create_signs_as_distro_and_accepts_fields() {
        let (identity, delivery) = distro_handle_and_delivery();
        let dest = [0x11u8; 16];
        let content = CString::new("x").unwrap();
        let title = CString::new("").unwrap();

        let msg = retichat_message_create(
            dest.as_ptr(), 16,
            delivery.as_ptr(), 16,
            content.as_ptr(), title.as_ptr(),
            0x03, identity,
        );
        assert_ne!(msg, 0, "message_create failed");

        let ty = CString::new("rfed.distro.transfer").unwrap();
        assert_eq!(lxmf_message_add_field(msg, 0xFB, ty.as_ptr()), 0,
            "message handle is not in the shared lxmf_message_* store");

        let bad = retichat_message_create(
            dest.as_ptr(), 16,
            delivery.as_ptr(), 15,
            content.as_ptr(), title.as_ptr(),
            0x03, identity,
        );
        assert_eq!(bad, 0, "a 15-byte source hash must be rejected");

        assert_eq!(lxmf_message_destroy(msg), 0);
        assert_eq!(retichat_identity_destroy(identity), 0);
    }

    #[test]
    fn peer_is_distro_is_false_for_unknown_and_bad_length() {
        let unknown = [0x22u8; 16];
        assert_eq!(retichat_peer_is_distro(unknown.as_ptr(), 16), 0);
        assert_eq!(retichat_peer_is_distro(unknown.as_ptr(), 15), 0);
        assert_eq!(retichat_peer_is_distro(std::ptr::null(), 16), 0);
    }
}

#[cfg(test)]
mod display_name_bridge_tests {
    use super::*;
    use std::ffi::CString;

    fn take(ptr: *mut u8, len: u32) -> Vec<u8> {
        assert!(!ptr.is_null(), "NULL result: {:?}", rns::take_error());
        let bytes = unsafe { std::slice::from_raw_parts(ptr, len as usize).to_vec() };
        lxmf_free_bytes(ptr, len);
        bytes
    }

    fn sender() -> (u64, Identity) {
        let identity = Identity::new(true);
        (rns::store_handle(identity.clone()), identity)
    }

    fn pack(channel: &CString, sender: u64, state: u8, name: &[u8]) -> Vec<u8> {
        let mut len = 0u32;
        let ptr = retichat_channel_lxm_pack(
            channel.as_ptr(), sender,
            b"body".as_ptr(), 4,
            std::ptr::null(), 0,
            state, name.as_ptr(), name.len() as u32,
            &mut len,
        );
        take(ptr, len)
    }

    fn unpack_bytes(channel: &CString, wire: &[u8]) -> Option<Vec<u8>> {
        let mut len = 0u32;
        let ptr = retichat_channel_lxm_unpack(channel.as_ptr(), wire.as_ptr(), wire.len() as u32, &mut len);
        if ptr.is_null() { None } else { Some(take(ptr, len)) }
    }

    #[test]
    fn channel_pack_and_unpack_carry_the_name_state() {
        let channel = CString::new("public.ffi-names").unwrap();
        let (handle, identity) = sender();
        for (state, name, trailer) in [
            (0u8, &b"ignored"[..], vec![0u8, 0, 0]),
            (1, b"", vec![1, 0, 0]),
            (2, b" Bob ", vec![2, 0, 3, b'B', b'o', b'b']),
        ] {
            let out = pack(&channel, handle, state, name);
            let got = unpack_bytes(&channel, &out[8..]).expect("unpack");
            assert_eq!(&got[..16], &lxmf_rust::channel::lxmf_delivery_hash_for_public_key(&identity.get_public_key().unwrap()).unwrap()[..]);
            assert_eq!(&got[16..24], &out[..8], "the echo timestamp matches");
            assert_eq!(got[24], 1, "signature validated");
            assert_eq!(&got[32..36], b"body");
            assert_eq!(&got[36..], &trailer[..], "state {state}");
        }
        // A name that cleans to nothing, or an unknown state, is an error.
        let mut len = 7u32;
        let zwsp = "\u{200B}".as_bytes();
        let ptr = retichat_channel_lxm_pack(channel.as_ptr(), handle, b"x".as_ptr(), 1, std::ptr::null(), 0, 2, zwsp.as_ptr(), zwsp.len() as u32, &mut len);
        assert!(ptr.is_null() && len == 0);
        let ptr = retichat_channel_lxm_pack(channel.as_ptr(), handle, b"x".as_ptr(), 1, std::ptr::null(), 0, 9, std::ptr::null(), 0, &mut len);
        assert!(ptr.is_null());
    }

    /// DISPLAY_NAMES.md §2.3 through the C API: a post whose prelude key does
    /// not produce its claimed source is rejected and nothing is remembered.
    #[test]
    fn channel_unpack_rejects_a_key_that_does_not_bind() {
        let name = "public.ffi-binding";
        let channel = CString::new(name).unwrap();
        let (attacker, _) = sender();
        let victim = Identity::new(true);
        let victim_hash = lxmf_rust::channel::lxmf_delivery_hash_for_public_key(&victim.get_public_key().unwrap()).unwrap();
        let out = pack(&channel, attacker, 0, b"");
        let mut id = lxmf_rust::channel::channel_identity(name).unwrap();
        let mut plaintext = id.decrypt(&out[8 + 16..]).unwrap();
        plaintext[68..84].copy_from_slice(&victim_hash);
        let mut forged = lxmf_rust::channel::channel_id_hash(name).unwrap();
        forged.extend_from_slice(&lxmf_rust::channel::channel_destination(name).unwrap().encrypt(&plaintext).unwrap());

        assert!(unpack_bytes(&channel, &forged).is_none());
        assert!(rns::take_error().unwrap_or_default().contains("key binding"));
        assert_eq!(Identity::recall_public_key(&victim_hash), None);
    }

    #[test]
    fn distro_announce_payload_takes_the_announce_name() {
        let identity = Identity::new(true);
        let handle = rns::store_handle(identity);
        let mut len = 0u32;
        let name = b"Alice";
        let named = take(retichat_distro_announce_payload(handle, name.as_ptr(), name.len() as u32, &mut len), len);
        assert!(named.windows(7).any(|w| w == [0x93, 0xc4, 0x05, b'A', b'l', b'i', b'c']), "[bin \"Alice\", nil, [0xD0]]");
        let bare = take(retichat_distro_announce_payload(handle, std::ptr::null(), 0, &mut len), len);
        assert!(bare.windows(4).any(|w| w == [0x93, 0xc0, 0xc0, 0x91]), "[nil, nil, [0xD0]]");
    }

    #[test]
    fn display_name_clean_and_decode_are_exported() {
        let raw = " Alice\u{202e} ".as_bytes();
        let ptr = lxmf_display_name_clean(raw.as_ptr(), raw.len() as u32, 0);
        assert!(!ptr.is_null());
        assert_eq!(unsafe { std::ffi::CStr::from_ptr(ptr) }.to_str().unwrap(), "Alice");
        lxmf_free_string(ptr);
        let anon = b"Anonymous Peer";
        assert!(lxmf_display_name_clean(anon.as_ptr(), anon.len() as u32, 1).is_null());
        let ptr = lxmf_display_name_clean(anon.as_ptr(), anon.len() as u32, 0);
        assert!(!ptr.is_null(), "a message name may be anything");
        lxmf_free_string(ptr);
        assert!(lxmf_display_name_clean(std::ptr::null(), 0, 0).is_null());

        // DISPLAY_NAMES.md §2.1: {0xD1: {0: name}}.
        let fields = [0x81, 0xcc, 0xd1, 0x81, 0x00, 0xa3, b'B', b'o', b'b'];
        let mut len = 0u32;
        assert_eq!(take(lxmf_display_name_decode(fields.as_ptr(), fields.len() as u32, &mut len), len), vec![2, 0, 3, b'B', b'o', b'b']);
        let clear = [0x81, 0xcc, 0xd1, 0x81, 0x00, 0xc4, 0x00];
        assert_eq!(take(lxmf_display_name_decode(clear.as_ptr(), clear.len() as u32, &mut len), len), vec![1, 0, 0]);
        let beside_group = [0x81, 0xcc, 0xd1, 0x82, 0x01, 0xa1, b'g', 0x00, 0xc4, 0x01, b'A'];
        assert_eq!(take(lxmf_display_name_decode(beside_group.as_ptr(), beside_group.len() as u32, &mut len), len), vec![2, 0, 1, b'A']);
        let not_a_map = [0x81, 0xcc, 0xd1, 0xa3, b'B', b'o', b'b'];
        assert_eq!(take(lxmf_display_name_decode(not_a_map.as_ptr(), not_a_map.len() as u32, &mut len), len), vec![0, 0, 0], "a non-map 0xD1 is absent");
        let retired = [0x81, 0x10, 0xa3, b'B', b'o', b'b'];
        assert_eq!(take(lxmf_display_name_decode(retired.as_ptr(), retired.len() as u32, &mut len), len), vec![0, 0, 0]);
        assert_eq!(take(lxmf_display_name_decode(std::ptr::null(), 0, &mut len), len), vec![0, 0, 0]);
    }

    /// The Swift header must say what the Rust library does: the buffer that
    /// holds every name, and the delivery callback's reason argument
    /// (DISPLAY_NAMES.md §5.2 needs "unknown" apart from "invalid").
    #[test]
    fn the_header_matches_the_display_name_exports() {
        let header = include_str!("../../../Retichat/Bridge/CRetichatFFI.h");
        let define = header
            .lines()
            .find_map(|l| l.strip_prefix("#define LXMF_DISPLAY_NAME_BUF_LEN "))
            .expect("LXMF_DISPLAY_NAME_BUF_LEN in the header");
        assert_eq!(define.trim().parse::<u32>().unwrap(), LXMF_DISPLAY_NAME_BUF_LEN);

        let start = header.find("typedef void (*lxmf_delivery_callback_t)(").expect("delivery typedef");
        let typedef = &header[start..start + header[start..].find(");").unwrap()];
        let params: Vec<&str> = typedef.split(|c| c == ',' || c == '(').map(str::trim).collect();
        let valid = params.iter().position(|p| *p == "int32_t signature_valid").expect("signature_valid");
        assert_eq!(params[valid + 1], "int32_t unverified_reason", "unverified_reason follows signature_valid");
    }

    /// DISPLAY_NAMES.md §10: the Retichat field setters are declared with
    /// the signatures the library exports (an int32_t key, so Swift passes
    /// the key unchanged and the library refuses out-of-range keys instead
    /// of a uint8_t truncating them).
    #[test]
    fn the_header_declares_the_retichat_field_setters() {
        let header = include_str!("../../../Retichat/Bridge/CRetichatFFI.h");
        assert!(header.contains("int32_t lxmf_message_set_retichat_string(uint64_t msg, int32_t key, const char *value);"));
        assert!(header.contains("int32_t lxmf_message_set_retichat_bool(uint64_t msg, int32_t key, int32_t value);"));
        let _: extern "C" fn(u64, i32, *const std::os::raw::c_char) -> i32 = lxmf_message_set_retichat_string;
        let _: extern "C" fn(u64, i32, i32) -> i32 = lxmf_message_set_retichat_bool;
        // Key 0 is the router's; refused before the handle is even looked up.
        let value = std::ffi::CString::new("x").unwrap();
        assert_eq!(lxmf_message_set_retichat_string(0, 0, value.as_ptr()), -1);
        assert_eq!(lxmf_message_set_retichat_bool(0, 0, 1), -1);
    }
}
