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

mod distro_outbox;
mod group_status;

use std::ffi::CStr;
use std::os::raw::{c_char, c_void};
use std::sync::atomic::{AtomicBool, Ordering};
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

/// Seal the packed message `packed` for the distro sync proof (RFed SPEC §17.13;
/// DISTRO-SYNC-PROOF-DESIGN.md §5.1), once, when the outbox owes it: encrypt it to
/// the distro D (`distro_handle`, which must hold D's private key) and sign the
/// sealed bytes with D's key. `packed` is the message as `retichat_message_pack`
/// returned it, from D to D. Returns heap bytes `sig(64) | sealed` (free with
/// `rns_free_bytes`): `sealed = D_hash | D.encrypt(packed[16..])`, LXMF's
/// `lxmf_data` before the stamp, and `sig` D's Ed25519 signature over
/// `"rfed.distro.sync" | 0x01 | D_hash | SHA-256(sealed)`. The outbox stores both
/// with the entry, in the write that owes it, and every upload of it carries the
/// same sealed bytes (`retichat_propagation_build_sealed_upload`). NULL with
/// `rns_last_error` when D has no private key, `packed` is not addressed to D, or
/// the encryption or the signature fails: the entry is then owed without them and
/// built the legacy way (`retichat_propagation_build_upload`). A thin wrapper over
/// `lxmf_rust::distro::seal_for_sync`, as Retichat-android's `nativeDistroSeal`.
#[no_mangle]
pub extern "C" fn retichat_distro_seal(
    distro_handle: u64,
    packed: *const u8,
    packed_len: u32,
    out_len: *mut u32,
) -> *mut u8 {
    let Some(distro) = distro_identity(distro_handle, "distro") else {
        unsafe { *out_len = 0; }
        return std::ptr::null_mut();
    };
    let packed = slice_from_raw(packed, packed_len);
    match lxmf_rust::distro::seal_for_sync(&distro, &packed) {
        Ok(sealed) => {
            let mut out = Vec::with_capacity(64 + sealed.sealed.len());
            out.extend_from_slice(&sealed.sig);
            out.extend_from_slice(&sealed.sealed);
            emit_buffer(out, out_len)
        }
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
///
/// RFed SPEC §17.14 (GROUPS-DISTRO-DESIGN.md §7): also hash (64 hex), has_group_id,
/// group_id, group_action, group_name, group_sync (null or an object), sender_key
/// (128 hex or null) and packed (base64 or null). This crate's group receipt
/// (`group_status::receipt_parts`) runs on the rebuilt message, so
/// signature_validated / unverified_reason are its verdict: an accept or leave
/// from a source whose key is not held is decided under the key it carries.
/// The JSON is `lxmf_rust::distro::DistroMessage::to_json_with_receipt`, the one
/// definition both bridges use. `hash` is LXMF.py's, over the payload bytes as
/// received (`DistroMessage::hash`): for a payload not in rmpv's form (the web's
/// G, at_ms as int 64) it is not what `LXMessage::unpack_from_bytes` computes
/// from the same bytes, so the app keys by it, never by unpacking `packed` again.
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

    match group_status::distro_unwrap_json(&mut distro, &data) {
        Ok(None) => emit_buffer(Vec::new(), out_len),
        Ok(Some(json)) => emit_buffer(json.into_bytes(), out_len),
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

// ---------------------------------------------------------------------------
// What a device owes its distro (RFed SPEC §17.12 "On the sending device", §17.11)
//
// The Swift outbox (Retichat/Services/DistroOutbox.swift) keeps what is owed
// and decides when to upload. These functions give it what it cannot make
// itself: C's fields, a message packed once, an upload built for a distro's key,
// the propagation link as it is now and as it changes, and an upload on the
// held link that says when the node proves it and when it is lost. The pure
// parts are in `distro_outbox.rs`. Nothing here sends on a timer or sends again.
// The same functions, one for one, as Retichat-android's JNI crate.
// ---------------------------------------------------------------------------

use app_links::{link_representation, AppLinks, LinkRepresentation, ResourceSilenceWatch};
use reticulum_rust::link::{LinkHandle, STATE_ACTIVE};

/// `retichat_upload_event_t`'s `event`: the node proved the upload, or it was lost, or (a
/// Resource whose first advertisement no interface could carry) it never left the device.
const UPLOAD_EVENT_PROVED: i32 = 1;
const UPLOAD_EVENT_LOST: i32 = 2;
const UPLOAD_EVENT_NEVER_LEFT: i32 = 3;

/// Write the membership message C's fields on the outbound message `msg`
/// (a `retichat_message_create` handle): 0x0C an empty bin, 0xFB
/// `"rfed.distro.channel"`, 0xFC the native array `[op, name, at_ms]`, 0xFD the
/// sending device's own address (RFed SPEC §17.12). 0 on success; -1 with
/// `rns_last_error` set and the message unchanged when `op` is not `join` or
/// `leave`, `name` is empty, `at_ms` is not 0..2^53-1 or `device_hex` is not
/// 32 hex characters.
#[no_mangle]
pub extern "C" fn retichat_message_set_distro_channel_sync(
    msg: u64,
    op: *const c_char,
    name: *const c_char,
    at_ms: i64,
    device_hex: *const c_char,
) -> i32 {
    let op = unsafe { cstr_to_string(op) };
    let name = unsafe { cstr_to_string(name) };
    let device = unsafe { cstr_to_string(device_hex) };
    if at_ms < 0 {
        rns::set_error(format!("at_ms {at_ms} is negative"));
        return -1;
    }
    let Some(message) = rns::get_handle::<Arc<Mutex<lxmf_rust::lx_message::LXMessage>>>(msg) else {
        rns::set_error("invalid message handle".to_string());
        return -1;
    };
    let result = match message.lock() {
        Ok(mut m) => distro_outbox::set_channel_sync_fields(&mut m, &op, &name, at_ms as u64, &device),
        Err(e) => Err(e.to_string()),
    };
    match result {
        Ok(()) => 0,
        Err(e) => {
            rns::set_error(e);
            -1
        }
    }
}

/// Write the group sync G's fields on the outbound message `msg` (a
/// `retichat_message_create` handle from D to D; RFed SPEC §17.14): 0x0C an
/// empty bin, 0xFB `"rfed.distro.group"`, 0xFC the native array of the op, 0xFD
/// the sending device's own address. `sync_json` is the `group_sync` object of
/// the unwrap JSON without `by` and `problem` (`lxmf_rust::distro::GroupSync::from_json`):
/// `op`, `group_id`, `at_ms`, `left`, and `name`, `members`, `keys` (create,
/// accept), `creator` (accept), `text` (post). `d_hex` is D's `lxmf.delivery`
/// address. 0 on success; -1 with `rns_last_error` set and the message unchanged
/// when the JSON does not parse or what it describes would fail a receiver's
/// form check (§11.1 rule 4), or the message is not one G can be written on
/// (`lxmf_rust::distro::set_group_sync_fields`).
#[no_mangle]
pub extern "C" fn retichat_message_set_distro_group_sync(
    msg: u64,
    sync_json: *const c_char,
    d_hex: *const c_char,
    device_hex: *const c_char,
) -> i32 {
    let sync_json = unsafe { cstr_to_string(sync_json) };
    let d_hex = unsafe { cstr_to_string(d_hex) };
    let device = unsafe { cstr_to_string(device_hex) };
    let Some(message) = rns::get_handle::<Arc<Mutex<lxmf_rust::lx_message::LXMessage>>>(msg) else {
        rns::set_error("invalid message handle".to_string());
        return -1;
    };
    let result = match message.lock() {
        Ok(mut m) => distro_outbox::set_group_sync_json(&mut m, &sync_json, &d_hex, &device),
        Err(e) => Err(e.to_string()),
    };
    match result {
        Ok(()) => 0,
        Err(e) => {
            rns::set_error(e);
            -1
        }
    }
}

/// Pack and sign the outbound message `msg` once and return its packed bytes
/// (`dest | src | signature | payload`), which the outbox keeps and uploads as
/// they are, never packed again: a message already packed returns the bytes it
/// was packed to. `lxmf_message_hash` is then its hash. Heap bytes (free with
/// `rns_free_bytes`), or NULL with `rns_last_error`.
#[no_mangle]
pub extern "C" fn retichat_message_pack(msg: u64, out_len: *mut u32) -> *mut u8 {
    let Some(message) = rns::get_handle::<Arc<Mutex<lxmf_rust::lx_message::LXMessage>>>(msg) else {
        return emit_error(out_len, "invalid message handle".to_string());
    };
    match distro_outbox::pack_message(&message) {
        Ok(bytes) => emit_buffer(bytes, out_len),
        Err(e) => emit_error(out_len, e),
    }
}

/// Build the propagation upload of the packed message `packed` for the node
/// `node` (16 bytes): encrypted to `distro_public_key` (64 bytes) and to no
/// other key, stamped for the node's cost (read from its announce; unknown is an
/// error, and the node's path is requested so its announce can be heard).
/// BLOCKS while the stamp is mined: never on the main thread. Heap bytes (free
/// with `rns_free_bytes`), or NULL with `rns_last_error` and nothing sent.
#[no_mangle]
pub extern "C" fn retichat_propagation_build_upload(
    distro_public_key: *const u8,
    key_len: u32,
    packed: *const u8,
    packed_len: u32,
    node: *const u8,
    node_len: u32,
    out_len: *mut u32,
) -> *mut u8 {
    let key = slice_from_raw(distro_public_key, key_len);
    let packed = slice_from_raw(packed, packed_len);
    let node = slice_from_raw(node, node_len);
    let cost = match propagation_node_stamp_cost(&node) {
        Ok(cost) => cost,
        Err(e) => return emit_error(out_len, e),
    };
    match distro_outbox::build_propagation_upload(&key, &packed, cost) {
        Ok(bytes) => emit_buffer(bytes, out_len),
        Err(e) => emit_error(out_len, e),
    }
}

/// The stamp cost the propagation node `node` (16 bytes) asks, read from its announce. Unknown is
/// an error, and then the node's path is requested, as the router does when it has no cost
/// (LXMRouter::get_outbound_propagation_cost): its announce carries the cost. The upload waits for
/// the next coming-up.
fn propagation_node_stamp_cost(node: &[u8]) -> Result<u32, String> {
    if node.len() != 16 {
        return Err(format!("a propagation node is 16 bytes, not {}", node.len()));
    }
    distro_outbox::node_stamp_cost(Identity::recall_app_data(node).as_deref()).map_err(|e| {
        Transport::request_path(node, None, None, None, None);
        e
    })
}

/// Build the propagation upload of an entry sealed when it was owed (`retichat_distro_seal`) for
/// the node `node` (16 bytes): `sealed` exactly as stored, never encrypted again, stamped for the
/// node's cost (read from its announce; unknown is an error, and the node's path is requested), with
/// the timebase now (RFed SPEC §17.13; DISTRO-SYNC-PROOF-DESIGN.md §5.2). With `with_claim` non-zero
/// it carries the distro sync proof `[id, distro_public_key, sig]`, so RFed delivers it to the
/// distro's devices without waking them; the caller sets it only when `node` is the configured
/// RFed's own `lxmf.propagation` (the gate, §5.4): any other node gets LXMF's two-element upload,
/// which every LXMF propagation node reads. A stored proof that does not hold for this message is
/// not sent: the upload goes without it, and that is logged as an error. BLOCKS while the stamp is
/// mined: never on the main thread. Heap bytes (free with `rns_free_bytes`), or NULL with
/// `rns_last_error` and nothing sent. As Retichat-android's `nativePropagationBuildSealedUpload`.
#[no_mangle]
pub extern "C" fn retichat_propagation_build_sealed_upload(
    distro_public_key: *const u8,
    key_len: u32,
    sealed: *const u8,
    sealed_len: u32,
    sig: *const u8,
    sig_len: u32,
    with_claim: i32,
    node: *const u8,
    node_len: u32,
    out_len: *mut u32,
) -> *mut u8 {
    let key = slice_from_raw(distro_public_key, key_len);
    let sealed = slice_from_raw(sealed, sealed_len);
    let sig = slice_from_raw(sig, sig_len);
    let node = slice_from_raw(node, node_len);
    let cost = match propagation_node_stamp_cost(&node) {
        Ok(cost) => cost,
        Err(e) => return emit_error(out_len, e),
    };
    match distro_outbox::build_sealed_propagation_upload(&key, &sealed, &sig, with_claim != 0, cost) {
        Ok(bytes) => emit_buffer(bytes, out_len),
        Err(e) => emit_error(out_len, e),
    }
}

/// The outbound link AppLinks holds for the propagation node `node`, as it is
/// now: `[state u8 | link id]`, where state is the link's own (0 pending, 1
/// handshake, 2 ACTIVE, 3 STALE, 4 closed). Heap bytes (free with
/// `rns_free_bytes`), or NULL when none is held. A read of the registry, never a
/// wait.
#[no_mangle]
pub extern "C" fn retichat_propagation_link(node: *const u8, node_len: u32, out_len: *mut u32) -> *mut u8 {
    let node = slice_from_raw(node, node_len);
    match AppLinks::get_handle(&node) {
        Some(link) => {
            let mut out = vec![link.status()];
            out.extend_from_slice(&link.link_id());
            emit_buffer(out, out_len)
        }
        None => {
            if !out_len.is_null() {
                unsafe { *out_len = 0 };
            }
            std::ptr::null_mut()
        }
    }
}

type UploadEventCallback = Option<extern "C" fn(*mut c_void, i32)>;
type UploadReleaseCallback = Option<extern "C" fn(*mut c_void)>;

/// What reports an upload to the host: each of proved, lost and never-left at most
/// once, from whatever thread the stack decides it on. A proof can follow a loss (the
/// receipt stays listed, and a late proof still concludes it): both are told, in the
/// order they happen. Never-left is told instead of either, never with them: AppLinks
/// decides a Resource's upload once (`send_on_held_link_owed`). The host's `context` is
/// released, once, when the last closure holding this report is dropped (or at once
/// when the upload did not leave this call).
struct UploadReport {
    event: UploadEventCallback,
    release: UploadReleaseCallback,
    context: usize,
    proved: AtomicBool,
    lost: AtomicBool,
    never_left: AtomicBool,
}

impl UploadReport {
    fn new(event: UploadEventCallback, release: UploadReleaseCallback, context: *mut c_void) -> Self {
        Self {
            event,
            release,
            context: context as usize,
            proved: AtomicBool::new(false),
            lost: AtomicBool::new(false),
            never_left: AtomicBool::new(false),
        }
    }

    fn tell(&self, event: i32) {
        if let Some(callback) = self.event {
            callback(self.context as *mut c_void, event);
        }
    }

    fn proved(&self) {
        if !self.proved.swap(true, Ordering::SeqCst) {
            self.tell(UPLOAD_EVENT_PROVED);
        }
    }

    fn lost(&self) {
        if !self.lost.swap(true, Ordering::SeqCst) {
            self.tell(UPLOAD_EVENT_LOST);
        }
    }

    /// The Resource's first advertisement went out on no interface: nothing was sent.
    fn never_left(&self) {
        if !self.never_left.swap(true, Ordering::SeqCst) {
            self.tell(UPLOAD_EVENT_NEVER_LEFT);
        }
    }
}

impl Drop for UploadReport {
    fn drop(&mut self) {
        if let Some(release) = self.release {
            release(self.context as *mut c_void);
        }
    }
}

/// The receipt's timeout tears the propagation link down (LXMF/LXMessage.py
/// `__link_packet_timed_out`: `packet_receipt.destination.teardown()`), and the
/// phones do the same (DESIGN_PRINCIPLES §3, what a device owes its distro).
/// It is the link the upload went on that is torn down. That link, while it is
/// still the one AppLinks holds, goes through `teardown_held_link`, which keeps
/// the registration so the persistent link re-opens under its normal
/// close-triggered policy: the new link's establishment is what carries what is
/// owed. A link already replaced by a newer one is torn down alone, and the
/// newer link, which did nothing wrong, is left up.
fn tear_down_link_of_upload(node: &[u8], link: &LinkHandle) {
    match AppLinks::get_handle(node) {
        Some(held) if held.same_link(link) => {
            AppLinks::teardown_held_link(node);
        }
        _ => link.teardown(),
    }
}

/// Hand `upload` (a `retichat_propagation_build_upload` or
/// `retichat_propagation_build_sealed_upload` result) to the link AppLinks holds for the
/// propagation node `node` (16 bytes), which must be ACTIVE: one packet, or a Resource over
/// the link MDU. Returns heap bytes (free with `rns_free_bytes`) `[how u8 | link id]` (how 1 a
/// packet, 2 a Resource; the link id the upload went on), or NULL with `rns_last_error` when it
/// did not leave (no active link held, or the packet could not be queued: no interface could
/// carry it): then `event` is never called.
///
/// Once handed over, `event(context, 1)` is called when the node proves the packet (or the
/// Resource completes) and `event(context, 2)` when the packet receipt times out or the Resource
/// fails, each at most once, from a stack thread: it must not block. Nothing here races, resends
/// or times anything: the stack's own receipt timeout is the clock. On a loss the link the upload
/// went on is torn down before `event(context, 2)` is called, so the close that follows is what the
/// loss is.
///
/// A Resource whose first advertisement no interface could carry never left the device
/// (DESIGN_PRINCIPLES §3, James 2026-10-06, for a Resource 2026-10-10; DISTRO-SYNC-PROOF-DESIGN.md
/// §5.3(a)): AppLinks cancels it here and keeps the link, and `event(context, 3)` is called once,
/// instead of 1 or 2 and with no teardown, like the NULL of a packet that could not be queued. The
/// host takes `retichat_interface_up_mark()` just before this call and, once it has recorded the
/// upload as owed, asks `retichat_interface_came_up_since(mark)` (AppLinks' `UpEdgeMark`): an
/// interface that came up meanwhile was this upload's up-edge, and it goes at once.
///
/// A Resource's progress feeds the §1 watch (DESIGN_PRINCIPLES §1, bulk transfers: progress at
/// least every 5 s from its advertisement on), which logs a silence as the violation it is and
/// decides nothing (AppLinks' `ResourceSilenceWatch`); its end point is the last thing each
/// outcome does here, after the host has been told.
///
/// `context` is owned by the library from this call on, whether or not the upload leaves:
/// `release(context)` is called exactly once when the library is done with it (after the last
/// event it can still give).
#[no_mangle]
pub extern "C" fn retichat_propagation_upload(
    node: *const u8,
    node_len: u32,
    upload: *const u8,
    upload_len: u32,
    event: UploadEventCallback,
    release: UploadReleaseCallback,
    context: *mut c_void,
    out_len: *mut u32,
) -> *mut u8 {
    // Made first, so that every way out of this function releases the context.
    let report = Arc::new(UploadReport::new(event, release, context));
    let node = slice_from_raw(node, node_len);
    let data = slice_from_raw(upload, upload_len);
    if node.len() != 16 || data.is_empty() {
        return emit_error(out_len, "an upload needs a 16-byte node and some bytes".to_string());
    }
    let Some(before) = AppLinks::get_handle(&node).filter(|link| link.status() == STATE_ACTIVE) else {
        return emit_error(out_len, "no active link is held for the propagation node".to_string());
    };
    let how: u8 = match link_representation(data.len()) {
        LinkRepresentation::Packet => 1,
        LinkRepresentation::Resource => 2,
    };

    // The link the upload goes on: `before`, unless the held link changed
    // between reading it and the send (a replacement is then the newer one).
    let used: Arc<Mutex<LinkHandle>> = Arc::new(Mutex::new(before.clone()));

    // DESIGN_PRINCIPLES §1, bulk transfers: a Resource's silence over 5 s is logged where it
    // is found and decides nothing. Its end point, `finish`, is the last call of whichever
    // outcome concludes the upload, once the host has been told (James, 2026-10-10, "Panic at
    // the end": in a debug build the logged violations panic then, on a thread of their own).
    let node_hex: String = node.iter().take(4).map(|b| format!("{b:02x}")).collect();
    let watch = ResourceSilenceWatch::new(format!("the distro outbox upload to {node_hex}"));

    let proved_report = report.clone();
    let proved_watch = watch.clone();
    let on_delivered: Arc<dyn Fn() + Send + Sync + 'static> = Arc::new(move || {
        proved_watch.delivered();
        proved_report.proved();
        // NEVER REMOVE EVER — see DESIGN_PRINCIPLES.md §1
        proved_watch.finish();
    });
    let lost_report = report.clone();
    let lost_node = node.clone();
    let lost_used = used.clone();
    let lost_watch = watch.clone();
    let on_failed: Arc<dyn Fn() + Send + Sync + 'static> = Arc::new(move || {
        let link = lost_used.lock().map(|l| l.clone());
        if let Ok(link) = link {
            tear_down_link_of_upload(&lost_node, &link);
        }
        lost_report.lost();
        // NEVER REMOVE EVER — see DESIGN_PRINCIPLES.md §1
        lost_watch.finish();
    });
    // Never left: nothing was sent, so this is no loss and the link did nothing wrong. No
    // teardown: the host keeps the upload owed and sends it at the next interface up-edge or
    // coming-up (DESIGN_PRINCIPLES §3, the distro exception).
    let never_left_report = report.clone();
    let never_left_watch = watch.clone();
    let on_never_left: Arc<dyn Fn() + Send + Sync + 'static> = Arc::new(move || {
        never_left_report.never_left();
        // NEVER REMOVE EVER — see DESIGN_PRINCIPLES.md §1
        never_left_watch.finish();
    });

    match AppLinks::send_on_held_link_owed(&node, data, true, on_delivered, on_failed, Some(watch.on_progress()), on_never_left) {
        Ok(()) => {
            let link = match AppLinks::get_handle(&node) {
                Some(after) if !after.same_link(&before) => after,
                _ => before,
            };
            if let Ok(mut slot) = used.lock() {
                *slot = link.clone();
            }
            let mut out = vec![how];
            out.extend_from_slice(&link.link_id());
            emit_buffer(out, out_len)
        }
        Err(e) => {
            // NEVER REMOVE EVER — see DESIGN_PRINCIPLES.md §1
            watch.finish();
            emit_error(out_len, e)
        }
    }
}

type LinkEventCallback = Option<extern "C" fn(*mut c_void, *const u8, u32, u8, *const u8, u32)>;

/// Register a second AppLinks status callback that also says which link an
/// event is about: `callback(context, dest, dest_len, status, link_id,
/// link_id_len)` for every status change of every app-link (0 none, 1 path
/// requested, 2 establishing, 3 ACTIVE, 4 disconnected, 5 recovered), with the
/// link's id for establishing, ACTIVE and recovered and an empty one (NULL, 0)
/// otherwise. A new propagation link's establishment is its ACTIVE event; a
/// STALE link's recovery (it heard from its peer again) is its RECOVERED event,
/// an event only (`AppLinks::status` never returns it), told once per recovery
/// and only for the link AppLinks still holds. The pointers are valid only
/// during the call. It runs on a stack thread and must not block. The existing
/// `lxmf_app_link_register_status_callback` is left as it is and is told the
/// same statuses. The stack's shutdown drops every callback, so register again
/// after each start. 0 on success, -1 with `rns_last_error`.
#[no_mangle]
pub extern "C" fn retichat_propagation_link_events_register(callback: LinkEventCallback, context: *mut c_void) -> i32 {
    let Some(callback) = callback else {
        rns::set_error("a link event callback is required".to_string());
        return -1;
    };
    let context = context as usize;
    AppLinks::register_status_callback(Arc::new(move |dest: &[u8], status: u8, link: Option<LinkHandle>| {
        let id = link.map(|l| l.link_id()).unwrap_or_default();
        deliver_link_event(callback, context, dest, status, &id);
    }));
    0
}

type InterfaceUpCallback = Option<extern "C" fn(*mut c_void, *const u8, u32)>;

/// The host's interface up-edge callback and its context, or none. Replaced by each
/// `retichat_interface_up_register` and dropped by `retichat_interface_up_clear`; the stack's
/// own listener below reads it and never holds this lock while it calls the host.
static INTERFACE_UP_HOST: Mutex<Option<(extern "C" fn(*mut c_void, *const u8, u32), usize)>> = Mutex::new(None);

/// `Transport::add_interface_up_listener` takes a listener that is never taken out again (the
/// stack's shutdown does not drop it, as it drops AppLinks' status callbacks), so ours is added
/// once for the process, whatever the number of starts, and reads the host callback above.
static INTERFACE_UP_HOOKED: std::sync::Once = std::sync::Once::new();

/// An interface came online (the stack's `Transport::set_interface_online(name, true)` on an
/// interface that was not): tell the host, if it is listening, the interface's name.
fn deliver_interface_up(name: &str) {
    let host = *INTERFACE_UP_HOST.lock().unwrap_or_else(|e| e.into_inner());
    if let Some((callback, context)) = host {
        callback(context as *mut c_void, name.as_ptr(), name.len() as u32);
    }
}

/// Tell the host, through `callback(context, name, name_len)`, each time a Reticulum interface
/// comes online: the stack's own up-edge (`Transport::set_interface_online`), not the operating
/// system's "the network is available". It is the event on which an owed distro upload that never
/// left the device, because no interface could carry its packet, goes (James, 2026-10-06,
/// DESIGN_PRINCIPLES §3, what a device owes its distro). `name` is the interface's name, a
/// pointer valid only during the call. Runs on a thread of its own and must not block. One host
/// callback at a time: a second register replaces the first. Nothing here repeats or times
/// anything. 0 on success, -1 with `rns_last_error` when `callback` is NULL.
#[no_mangle]
pub extern "C" fn retichat_interface_up_register(callback: InterfaceUpCallback, context: *mut c_void) -> i32 {
    let Some(callback) = callback else {
        rns::set_error("an interface up callback is required".to_string());
        return -1;
    };
    *INTERFACE_UP_HOST.lock().unwrap_or_else(|e| e.into_inner()) = Some((callback, context as usize));
    INTERFACE_UP_HOOKED.call_once(|| {
        Transport::add_interface_up_listener(Arc::new(|name: &str| deliver_interface_up(name)));
    });
    0
}

/// The host stops listening (the stack is stopping): an interface that comes online after this
/// reaches nobody, until the next register.
#[no_mangle]
pub extern "C" fn retichat_interface_up_clear() {
    *INTERFACE_UP_HOST.lock().unwrap_or_else(|e| e.into_inner()) = None;
}

/// AppLinks' `UpEdgeMark::now()`, for the host: the number of Reticulum interface up-edges
/// (`Transport::interface_up_edges`) so far. The host takes it just before each
/// `retichat_propagation_upload` (DISTRO-SYNC-PROOF-DESIGN.md §5.3(a); app-links
/// `send_on_held_link_owed`).
#[no_mangle]
pub extern "C" fn retichat_interface_up_mark() -> u64 {
    Transport::interface_up_edges()
}

/// AppLinks' `UpEdgeMark::came_up_since`, for the host: 1 when a Reticulum interface has come up
/// since `mark` (`retichat_interface_up_mark`), else 0. Asked only once an upload that never left
/// (the NULL of `retichat_propagation_upload` with the link up, or its event 3) is recorded as owed:
/// the up-edge it waits for may have reached the host's up-edge listener in between, while nothing
/// was owed yet, and the link stays up, so no coming-up would follow. When it is 1 the upload goes
/// at once, with a new mark. An ordering check at an event: no timer, no retry; each send answers
/// one up-edge.
#[no_mangle]
pub extern "C" fn retichat_interface_came_up_since(mark: u64) -> i32 {
    i32::from(Transport::interface_up_edges() != mark)
}

// ---------------------------------------------------------------------------
// Member statuses and keys (RFed-spec Group.md, "Member statuses and keys
// (2026-10-06)"; LXMF-rust/DISPLAY_NAMES.md §10 key 10)
//
// What Swift cannot make of an accept or leave and of a status: the key an
// accept or leave carries for its own sender, bound and checked where the
// router's message is still in hand (the delivery callback below); an element
// of a status unpacked and checked as if it had arrived directly; key 10 written
// as a native array of bin. The pure parts, and the shared vectors they run
// against, are in `group_status.rs`. The same functions, one for one, as
// Retichat-android's JNI crate.
// ---------------------------------------------------------------------------

type GroupDeliveryFn = extern "C" fn(
    context: *mut c_void,
    hash: *const u8, hash_len: u32,
    src_hash: *const u8, src_len: u32,
    dest_hash: *const u8, dest_len: u32,
    title: *const c_char,
    content: *const c_char,
    timestamp: f64,
    signature_valid: i32,
    unverified_reason: i32,
    fields_raw: *const u8, fields_len: u32,
    sender_key: *const u8, sender_key_len: u32,
    packed: *const u8, packed_len: u32,
);
type GroupDeliveryCallback = Option<GroupDeliveryFn>;

/// The host's context for the delivery callback; the router's callback holds it.
struct DeliveryContext(usize);

/// A byte slice as a pointer and a length, or NULL and 0 for none.
fn optional_bytes(data: Option<&[u8]>) -> (*const u8, u32) {
    match data {
        Some(bytes) => (bytes.as_ptr(), bytes.len() as u32),
        None => (std::ptr::null(), 0),
    }
}

/// Register the delivery callback of `client` (a `lxmf_client_start_*` handle) with what the
/// group follow-up needs of a message: it is `lxmf_client_set_delivery_callback`'s callback
/// with two arguments more. `lxmf_client_set_delivery_callback` hands over a `ReceivedMessage`
/// snapshot, which holds neither the packed bytes nor the signature, so this registers on the
/// router itself to be given the message (`LXMRouter::register_delivery_callback`, which that
/// wrapper calls too). It replaces any delivery callback the client had.
///
/// An accept or a leave of a group carries its sender's own key (RFed-spec Group.md, "The
/// sender's key"): `sender_key` is that key (64 bytes) when it binds to the message's source,
/// and a source the router held no key for is then checked under it, so `unverified_reason` is
/// 0 or 2 for it, as for any signature (`group_status::receipt`). `packed` is the whole message
/// as received (`destination | source | signature | payload`), for an accept or leave of at most
/// 2144 bytes: what a creator keeps. Both are NULL, 0 for every other message. Nothing is
/// remembered here: Swift remembers `sender_key` after the group rule has passed, never for a
/// message it drops. The callback runs on a background thread and its pointers are valid only
/// during the call. 0 on success, -1 with `rns_last_error`.
#[no_mangle]
pub extern "C" fn retichat_client_set_delivery_callback_receipt(
    client: u64,
    callback: GroupDeliveryCallback,
    context: *mut c_void,
) -> i32 {
    let Some(callback) = callback else {
        rns::set_error("a delivery callback is required".to_string());
        return -1;
    };
    let Some(client) = rns::get_handle::<Arc<Mutex<lxmf_rust::LxmfClient>>>(client) else {
        rns::set_error("invalid client handle".to_string());
        return -1;
    };
    let router_handle = match client.lock() {
        Ok(client) => client.router_handle,
        Err(e) => {
            rns::set_error(e.to_string());
            return -1;
        }
    };
    let Some(router) = rns::get_handle::<Arc<Mutex<lxmf_rust::LXMRouter>>>(router_handle) else {
        rns::set_error("invalid router handle".to_string());
        return -1;
    };
    let context = DeliveryContext(context as usize);
    let registered = match router.lock() {
        Ok(mut router) => {
            router.register_delivery_callback(Arc::new(move |message: &lxmf_rust::LXMessage| {
                deliver_with_receipt(callback, &context, message);
            }));
            Ok(())
        }
        Err(e) => Err(e.to_string()),
    };
    match registered {
        Ok(()) => 0,
        Err(e) => {
            rns::set_error(e);
            -1
        }
    }
}

/// The router's delivery callback: a received message to the host with its receipt.
fn deliver_with_receipt(callback: GroupDeliveryFn, context: &DeliveryContext, message: &lxmf_rust::LXMessage) {
    let snapshot = lxmf_rust::ffi::ReceivedMessage::from_lxmessage(message);
    // An accept or leave's carried key, checked here for a source the router holds no key for;
    // the key and the packed message for Swift.
    let receipt = group_status::receipt(message, snapshot.signature_validated, snapshot.unverified_reason);
    let title = std::ffi::CString::new(snapshot.title.as_str()).unwrap_or_default();
    let content = std::ffi::CString::new(snapshot.content.as_str()).unwrap_or_default();
    let (key, key_len) = optional_bytes(receipt.sender_key.as_deref());
    let (packed, packed_len) = optional_bytes(receipt.packed.as_deref());
    callback(
        context.0 as *mut c_void,
        snapshot.hash.as_ptr(), snapshot.hash.len() as u32,
        snapshot.source_hash.as_ptr(), snapshot.source_hash.len() as u32,
        snapshot.destination_hash.as_ptr(), snapshot.destination_hash.len() as u32,
        title.as_ptr(),
        content.as_ptr(),
        snapshot.timestamp,
        if receipt.validated { 1 } else { 0 },
        receipt.unverified_reason as i32,
        snapshot.fields_raw.as_ptr(), snapshot.fields_raw.len() as u32,
        key, key_len,
        packed, packed_len,
    );
}

/// An element of a `status` (a member's own packed accept or leave, as the creator received it)
/// or an entry held for its sender's key, unpacked and checked as if it had arrived directly:
/// the router's own unpack and signature check under the key held for the source, then the key
/// the message carries for its own sender when none is held (`group_status::unpack_element`).
/// Nothing is remembered. Returns heap bytes (free with `rns_free_bytes`): the buffer
/// `group_status::encode_element` documents (verdict, bound key flag, destination, source,
/// message hash, timestamp, the key, the fields), or NULL with `rns_last_error` when `packed`
/// is not an LXMF message of the size of an accept or leave (97..=2144 bytes). The bytes are
/// another member's: a panic is caught and reported as NULL.
#[no_mangle]
pub extern "C" fn retichat_group_unpack_packed(packed: *const u8, packed_len: u32, out_len: *mut u32) -> *mut u8 {
    let packed = slice_from_raw(packed, packed_len);
    let result = std::panic::catch_unwind(|| {
        group_status::unpack_element(&packed).map(|element| group_status::encode_element(&element))
    })
    .unwrap_or_else(|_| Err("unpacking the message panicked".to_string()));
    match result {
        Ok(bytes) => emit_buffer(bytes, out_len),
        Err(e) => emit_error(out_len, e),
    }
}

/// Write key 10 (`GROUP_STATUSES`) on the outbound message `msg` (a `retichat_message_create`
/// handle): a native array of bin, one for each element of `elements` (a member's own packed
/// accept or leave as the creator received it), always in the Retichat field 0xD1 (key 10 has
/// no old top-level field), beside the entries already there. An empty array is a creator's
/// valid answer. `elements` is `count u32 | (length u32 | bytes)*count`, big endian. Each
/// element is as it was received, never wrapped again (CHECK_THESE_THINGS_FIRST §11). 0 on
/// success; -1 with `rns_last_error` and the message unchanged for an element no receiver would
/// read (no payload, or over 2144 bytes) or a buffer that does not hold what it says.
#[no_mangle]
pub extern "C" fn retichat_message_set_retichat_statuses(msg: u64, elements: *const u8, elements_len: u32) -> i32 {
    let flat = slice_from_raw(elements, elements_len);
    let list = match group_status::decode_elements(&flat) {
        Ok(list) => list,
        Err(e) => {
            rns::set_error(e);
            return -1;
        }
    };
    let Some(message) = rns::get_handle::<Arc<Mutex<lxmf_rust::lx_message::LXMessage>>>(msg) else {
        rns::set_error("invalid message handle".to_string());
        return -1;
    };
    let result = match message.lock() {
        Ok(mut m) => group_status::set_statuses(&mut m, &list),
        Err(e) => Err(e.to_string()),
    };
    match result {
        Ok(()) => 0,
        Err(e) => {
            rns::set_error(e);
            -1
        }
    }
}

/// One status change to the host: the link id as a pointer and a length, or
/// NULL and 0 when the event is about no link.
fn deliver_link_event(
    callback: extern "C" fn(*mut c_void, *const u8, u32, u8, *const u8, u32),
    context: usize,
    dest: &[u8],
    status: u8,
    link_id: &[u8],
) {
    let id_ptr = if link_id.is_empty() { std::ptr::null() } else { link_id.as_ptr() };
    callback(context as *mut c_void, dest.as_ptr(), dest.len() as u32, status, id_ptr, link_id.len() as u32);
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

#[cfg(test)]
mod distro_outbox_bridge_tests {
    use super::*;
    use std::ffi::CString;
    use std::sync::atomic::AtomicUsize;

    const DEVICE: &str = "0123456789abcdef0123456789abcdef";

    /// The bytes of C's fields for join, `public.general`, 2026-01-01 00:00 UTC and `DEVICE`:
    /// the literal `distro_outbox.rs` pins for the writer and Retichat-android pins for the
    /// reader (and `tests/DistroChannelSyncTests.swift` for this app's reader).
    const C_FIELDS_HEX: &str = "840cc400ccfbb3726665642e64697374726f2e6368616e6e656cccfc93a46a6f696eae7075626c69632e67656e6572616ccf0000019b76daa800ccfdd9203031323334353637383961626364656630313233343536373839616263646566";

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    fn take(ptr: *mut u8, len: u32) -> Vec<u8> {
        assert!(!ptr.is_null(), "NULL result: {:?}", rns::take_error());
        let bytes = unsafe { std::slice::from_raw_parts(ptr, len as usize).to_vec() };
        rns_free_bytes(ptr, len);
        bytes
    }

    /// A distro identity handle, its `lxmf.delivery` hash and its public key.
    fn distro() -> (u64, [u8; 16], Vec<u8>) {
        let identity = Identity::new(true);
        let key = identity.get_public_key().unwrap();
        let handle = rns::store_handle(identity);
        let mut delivery = [0u8; 16];
        assert_eq!(retichat_distro_delivery_hash(handle, delivery.as_mut_ptr(), 16), 16);
        (handle, delivery, key)
    }

    /// A message from the distro to itself, as the outbox makes one: DIRECT only so that packing
    /// needs no destination object, never sent. C has empty content and always has its fields;
    /// `content` is for a message that is packed without them (LXMessage::pack underflows, in a
    /// debug build, on an empty title, empty content and no fields at all: LXMF-rust
    /// lx_message.rs `content_size`, which no message the outbox makes comes near).
    fn message_with(identity: u64, delivery: &[u8; 16], content: &str) -> u64 {
        let content = CString::new(content).unwrap();
        let empty = CString::new("").unwrap();
        let msg = retichat_message_create(
            delivery.as_ptr(), 16, delivery.as_ptr(), 16, content.as_ptr(), empty.as_ptr(), 0x02, identity,
        );
        assert_ne!(msg, 0, "message_create: {:?}", rns::take_error());
        msg
    }

    fn message_from(identity: u64, delivery: &[u8; 16]) -> u64 {
        message_with(identity, delivery, "")
    }

    fn set_c(msg: u64, op: &str, name: &str, at_ms: i64, device: &str) -> i32 {
        let (op, name, device) = (CString::new(op).unwrap(), CString::new(name).unwrap(), CString::new(device).unwrap());
        retichat_message_set_distro_channel_sync(msg, op.as_ptr(), name.as_ptr(), at_ms, device.as_ptr())
    }

    fn pack(msg: u64) -> Vec<u8> {
        let mut len = 0u32;
        let ptr = retichat_message_pack(msg, &mut len);
        take(ptr, len)
    }

    #[test]
    fn c_goes_through_the_c_api_as_the_spec_table_gives_it_and_is_packed_once() {
        let (identity, delivery, _key) = distro();
        let msg = message_from(identity, &delivery);
        assert_eq!(set_c(msg, "join", "public.general", 1_767_225_600_000, DEVICE), 0, "{:?}", rns::take_error());
        let packed = pack(msg);
        assert!(
            hex(&packed).contains(C_FIELDS_HEX),
            "0x0C an empty bin, 0xFB a str, 0xFC a NATIVE array of op, name and uint 64 at_ms, 0xFD a str"
        );
        // Never packed again: the same bytes, and the hash of those bytes.
        assert_eq!(pack(msg), packed);
        let mut hash = [0u8; 32];
        assert_eq!(lxmf_message_hash(msg, hash.as_mut_ptr(), 32), 32);
        let mut hashed = packed[..32].to_vec();
        hashed.extend_from_slice(&packed[16 + 16 + 64..]);
        assert_eq!(reticulum_rust::identity::full_hash(&hashed), hash);
        assert_eq!(lxmf_message_destroy(msg), 0);
    }

    #[test]
    fn c_is_refused_at_the_c_boundary_when_it_is_malformed() {
        let (identity, delivery, _key) = distro();
        let msg = message_with(identity, &delivery, "x");
        for (op, name, at, device, why) in [
            ("Join", "public.x", 1i64, DEVICE, "join"),
            ("join", "", 1, DEVICE, "names its channel"),
            ("join", "public.x", -1, DEVICE, "negative"),
            ("join", "public.x", (1i64 << 53), DEVICE, "2^53"),
            ("join", "public.x", 1, "xyz", "32 hex"),
        ] {
            assert_eq!(set_c(msg, op, name, at, device), -1, "{op:?} {name:?} {at}");
            let error = rns::take_error().unwrap_or_default();
            assert!(error.contains(why), "{error}");
        }
        // A handle that is none, and a null string, are errors too, never a crash.
        assert_eq!(set_c(0, "join", "public.x", 1, DEVICE), -1);
        assert_eq!(
            retichat_message_set_distro_channel_sync(msg, std::ptr::null(), std::ptr::null(), 1, std::ptr::null()),
            -1
        );
        // A refused call wrote nothing: the packed message has no membership marker.
        assert!(!hex(&pack(msg)).contains("b3726665642e64697374726f2e6368616e6e656c"));
        // 2^53 - 1 is the last at_ms there is.
        let ok = message_from(identity, &delivery);
        assert_eq!(set_c(ok, "join", "public.x", (1i64 << 53) - 1, DEVICE), 0);
        let mut len = 0u32;
        assert!(retichat_message_pack(0, &mut len).is_null());
        assert_eq!(len, 0);
        assert!(rns::take_error().unwrap_or_default().contains("invalid message handle"));
    }

    #[test]
    fn a_node_that_is_not_held_has_no_link_and_no_upload_and_the_context_is_released_once() {
        let node = [0x5au8; 16];
        let mut len = 7u32;
        assert!(retichat_propagation_link(node.as_ptr(), 16, &mut len).is_null());
        assert_eq!(len, 0);

        static EVENTS: AtomicUsize = AtomicUsize::new(0);
        static RELEASES: AtomicUsize = AtomicUsize::new(0);
        extern "C" fn event(_context: *mut c_void, _event: i32) {
            EVENTS.fetch_add(1, Ordering::SeqCst);
        }
        extern "C" fn release(_context: *mut c_void) {
            RELEASES.fetch_add(1, Ordering::SeqCst);
        }
        let upload = [1u8, 2, 3];
        let ptr = retichat_propagation_upload(
            node.as_ptr(), 16, upload.as_ptr(), 3, Some(event), Some(release), 1 as *mut c_void, &mut len,
        );
        assert!(ptr.is_null());
        assert!(rns::take_error().unwrap_or_default().contains("no active link"));
        assert_eq!(EVENTS.load(Ordering::SeqCst), 0, "an upload that never left reports nothing");
        assert_eq!(RELEASES.load(Ordering::SeqCst), 1, "its context is released, once");

        // A node that is not 16 bytes, or no bytes, never leaves either, and releases too.
        let ptr = retichat_propagation_upload(node.as_ptr(), 15, upload.as_ptr(), 3, Some(event), Some(release), 2 as *mut c_void, &mut len);
        assert!(ptr.is_null());
        let ptr = retichat_propagation_upload(node.as_ptr(), 16, std::ptr::null(), 0, Some(event), Some(release), 3 as *mut c_void, &mut len);
        assert!(ptr.is_null());
        assert_eq!(RELEASES.load(Ordering::SeqCst), 3);
        assert_eq!(EVENTS.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn an_upload_report_tells_each_event_once_in_order_and_releases_its_context_with_the_last_holder() {
        static LOG: Mutex<Vec<(usize, i32)>> = Mutex::new(Vec::new());
        static RELEASED: Mutex<Vec<usize>> = Mutex::new(Vec::new());
        extern "C" fn event(context: *mut c_void, event: i32) {
            LOG.lock().unwrap().push((context as usize, event));
        }
        extern "C" fn release(context: *mut c_void) {
            RELEASED.lock().unwrap().push(context as usize);
        }
        let report = Arc::new(UploadReport::new(Some(event), Some(release), 0xC0FFEE as *mut c_void));
        let on_delivered = report.clone();
        let on_failed = report.clone();
        // The packet's receipt times out, the host hears the loss once; then the node proves it
        // after all (a late proof): both are told, in the order they happen, each once.
        on_failed.lost();
        on_failed.lost();
        on_delivered.proved();
        on_delivered.proved();
        let told: Vec<i32> = LOG.lock().unwrap().iter().filter(|(c, _)| *c == 0xC0FFEE).map(|(_, e)| *e).collect();
        assert_eq!(told, vec![UPLOAD_EVENT_LOST, UPLOAD_EVENT_PROVED]);
        // The context outlives a late proof: it goes only with the last closure.
        drop(on_failed);
        drop(report);
        assert!(!RELEASED.lock().unwrap().contains(&0xC0FFEE));
        drop(on_delivered);
        assert_eq!(RELEASED.lock().unwrap().iter().filter(|c| **c == 0xC0FFEE).count(), 1);
    }

    /// A Resource upload whose first advertisement no interface carried never left the device
    /// (DISTRO-SYNC-PROOF-DESIGN.md §5.3(a)): the host hears event 3, once, and nothing else, and the
    /// context goes with the last holder as for any other outcome.
    #[test]
    fn a_never_left_upload_is_told_once_as_event_3_and_releases_its_context_with_the_last_holder() {
        static LOG: Mutex<Vec<(usize, i32)>> = Mutex::new(Vec::new());
        static RELEASED: Mutex<Vec<usize>> = Mutex::new(Vec::new());
        extern "C" fn event(context: *mut c_void, event: i32) {
            LOG.lock().unwrap().push((context as usize, event));
        }
        extern "C" fn release(context: *mut c_void) {
            RELEASED.lock().unwrap().push(context as usize);
        }
        assert_eq!((UPLOAD_EVENT_PROVED, UPLOAD_EVENT_LOST, UPLOAD_EVENT_NEVER_LEFT), (1, 2, 3), "the numbers Swift's trampoline reads");
        let report = Arc::new(UploadReport::new(Some(event), Some(release), 0xBEEF as *mut c_void));
        let on_never_left = report.clone();
        on_never_left.never_left();
        on_never_left.never_left();
        let told: Vec<i32> = LOG.lock().unwrap().iter().filter(|(c, _)| *c == 0xBEEF).map(|(_, e)| *e).collect();
        assert_eq!(told, vec![UPLOAD_EVENT_NEVER_LEFT], "told once");
        drop(report);
        assert!(!RELEASED.lock().unwrap().contains(&0xBEEF));
        drop(on_never_left);
        assert_eq!(RELEASED.lock().unwrap().iter().filter(|c| **c == 0xBEEF).count(), 1);
        // Swift's trampoline maps each number to its sink call.
        let swift = include_str!("../../../Retichat/Bridge/RetichatBridge.swift");
        for case in ["case 1: box.sink.proved()", "case 2: box.sink.lost()", "case 3: box.sink.neverLeft()"] {
            assert!(swift.contains(case), "RetichatBridge.swift lacks: {case}");
        }
    }

    #[test]
    fn a_link_event_hands_over_the_link_id_or_null_and_zero() {
        static SEEN: Mutex<Vec<(usize, Vec<u8>, u8, Option<Vec<u8>>)>> = Mutex::new(Vec::new());
        extern "C" fn callback(context: *mut c_void, dest: *const u8, dest_len: u32, status: u8, id: *const u8, id_len: u32) {
            let dest = unsafe { std::slice::from_raw_parts(dest, dest_len as usize) }.to_vec();
            let id = if id.is_null() {
                assert_eq!(id_len, 0);
                None
            } else {
                Some(unsafe { std::slice::from_raw_parts(id, id_len as usize) }.to_vec())
            };
            SEEN.lock().unwrap().push((context as usize, dest, status, id));
        }
        deliver_link_event(callback, 0xFEED, &[7u8; 16], 3, &[9u8; 16]);
        deliver_link_event(callback, 0xFEED, &[7u8; 16], 4, &[]);
        let seen: Vec<_> = SEEN.lock().unwrap().iter().filter(|e| e.0 == 0xFEED).cloned().collect();
        assert_eq!(seen[0], (0xFEED, vec![7u8; 16], 3, Some(vec![9u8; 16])), "an ACTIVE event carries its link");
        assert_eq!(seen[1], (0xFEED, vec![7u8; 16], 4, None), "a disconnection carries none");
        assert_eq!(retichat_propagation_link_events_register(None, std::ptr::null_mut()), -1);
        assert!(rns::take_error().unwrap_or_default().contains("callback"));
        assert_eq!(retichat_propagation_link_events_register(Some(callback), 0xFEEE as *mut c_void), 0);
    }

    /// A STALE link's recovery is told as every other status is: AppLinks' own code and the link's id,
    /// unchanged, so Swift can hand the link to the outbox as a coming-up.
    #[test]
    fn a_recovered_event_hands_over_its_link_like_an_active_one() {
        static SEEN: Mutex<Vec<(usize, Vec<u8>, u8, Option<Vec<u8>>)>> = Mutex::new(Vec::new());
        extern "C" fn callback(context: *mut c_void, dest: *const u8, dest_len: u32, status: u8, id: *const u8, id_len: u32) {
            let dest = unsafe { std::slice::from_raw_parts(dest, dest_len as usize) }.to_vec();
            let id = if id.is_null() {
                assert_eq!(id_len, 0);
                None
            } else {
                Some(unsafe { std::slice::from_raw_parts(id, id_len as usize) }.to_vec())
            };
            SEEN.lock().unwrap().push((context as usize, dest, status, id));
        }
        deliver_link_event(callback, 0xFEEF, &[7u8; 16], app_links::APP_LINK_RECOVERED, &[9u8; 16]);
        let seen: Vec<_> = SEEN.lock().unwrap().iter().filter(|e| e.0 == 0xFEEF).cloned().collect();
        assert_eq!(seen, vec![(0xFEEF, vec![7u8; 16], 5, Some(vec![9u8; 16]))], "a RECOVERED event carries its link");
    }

    /// The glue relays AppLinks' status byte unchanged, and Swift's `RetichatBridge` must be the same
    /// numbers: ACTIVE (a new link's establishment) and RECOVERED (a STALE link's recovery), which are
    /// the two ways the propagation link comes up for the outbox.
    #[test]
    fn swifts_link_statuses_are_app_links_own() {
        let swift = include_str!("../../../Retichat/Bridge/RetichatBridge.swift");
        assert_eq!(app_links::APP_LINK_ACTIVE, 3);
        assert_eq!(app_links::APP_LINK_RECOVERED, 5);
        assert!(swift.contains(&format!("static let appLinkActive: UInt8 = {}", app_links::APP_LINK_ACTIVE)));
        assert!(swift.contains(&format!("static let appLinkRecovered: UInt8 = {}", app_links::APP_LINK_RECOVERED)));
    }

    /// The interface up-edge reaches the host with the interface's name, once per edge, from the
    /// stack's own `Transport::set_interface_online`: not on a repeat of "online", not on a down-edge,
    /// and not after the host cleared it. (One test: the host callback is process-wide.)
    #[test]
    fn an_interface_up_edge_reaches_the_host_once_with_its_name_until_it_is_cleared() {
        use reticulum_rust::transport::{InterfaceStub, InterfaceStubConfig};
        use std::sync::mpsc;
        use std::time::Duration;

        static SEEN: Mutex<Option<mpsc::Sender<(usize, String)>>> = Mutex::new(None);
        extern "C" fn callback(context: *mut c_void, name: *const u8, name_len: u32) {
            let name = String::from_utf8(unsafe { std::slice::from_raw_parts(name, name_len as usize) }.to_vec()).unwrap();
            if let Some(tx) = SEEN.lock().unwrap().as_ref() {
                let _ = tx.send((context as usize, name));
            }
        }
        let (tx, rx) = mpsc::channel();
        *SEEN.lock().unwrap() = Some(tx);

        // No host yet: an edge reaches nobody.
        deliver_interface_up("nobody-listens");
        assert!(rx.recv_timeout(Duration::from_millis(100)).is_err(), "no host, nothing delivered");

        assert_eq!(retichat_interface_up_register(None, std::ptr::null_mut()), -1);
        assert!(rns::take_error().unwrap_or_default().contains("callback"));
        assert_eq!(retichat_interface_up_register(Some(callback), 0xFACE as *mut c_void), 0);
        // Registering again (a restart of the stack) replaces the host callback and adds no listener.
        assert_eq!(retichat_interface_up_register(Some(callback), 0xFACE as *mut c_void), 0);

        deliver_interface_up("tcp-direct");
        assert_eq!(rx.recv_timeout(Duration::from_secs(1)).unwrap(), (0xFACE, "tcp-direct".to_string()), "the name and the context");

        // Through the stack: an interface registered offline, brought online, offline and online again.
        let name = "retichat-ffi-up-edge-test";
        let mut config = InterfaceStubConfig::default();
        config.name = name.to_string();
        config.online = Some(false);
        config.out = true;
        config.mode = InterfaceStub::MODE_FULL;
        Transport::register_interface_stub_config(config);
        // AppLinks' UpEdgeMark for the host: a mark taken now hears of the up-edge below, and a mark
        // taken after it does not. (Only this test brings an interface up in this crate's tests.)
        let mark = retichat_interface_up_mark();
        assert_eq!(retichat_interface_came_up_since(mark), 0, "no edge since the mark");
        let wait_for_name = |expected: &str, within: Duration| -> bool {
            let end = std::time::Instant::now() + within;
            while let Some(left) = end.checked_duration_since(std::time::Instant::now()) {
                match rx.recv_timeout(left) {
                    Ok((_, got)) if got == expected => return true,
                    Ok(_) => continue,
                    Err(_) => return false,
                }
            }
            false
        };
        Transport::set_interface_online(name, true);
        assert_eq!(retichat_interface_came_up_since(mark), 1, "counted before the listeners run");
        assert!(wait_for_name(name, Duration::from_secs(5)), "the stack's up-edge reaches the host, with the interface's name");
        let after = retichat_interface_up_mark();
        assert_eq!(after, mark + 1, "one edge");
        assert_eq!(retichat_interface_came_up_since(after), 0, "a mark taken after the edge has not seen one since");
        Transport::set_interface_online(name, true);    // already online: no edge
        Transport::set_interface_online(name, false);   // a down-edge: told to nobody
        assert!(!wait_for_name(name, Duration::from_millis(300)), "a repeat and a down-edge are no up-edge");
        assert_eq!(retichat_interface_came_up_since(after), 0, "nor do they move the mark");
        Transport::set_interface_online(name, true);
        assert!(wait_for_name(name, Duration::from_secs(5)), "each up-edge is told");

        retichat_interface_up_clear();
        Transport::set_interface_online(name, false);
        Transport::set_interface_online(name, true);
        assert!(!wait_for_name(name, Duration::from_millis(300)), "after clear nobody hears it");
        Transport::deregister_interface_stub(name);
    }

    /// A propagation node's announce `app_data`: `[name, timebase, active, limit, sync limit, [cost, ...], {}]`.
    fn node_app_data(cost: i64) -> Vec<u8> {
        let value = rmpv::Value::Array(vec![
            rmpv::Value::Nil,
            rmpv::Value::from(1_767_225_600),
            rmpv::Value::Boolean(true),
            rmpv::Value::from(256),
            rmpv::Value::from(10_240),
            rmpv::Value::Array(vec![rmpv::Value::from(cost), rmpv::Value::from(3), rmpv::Value::from(18)]),
            rmpv::Value::Map(Vec::new()),
        ]);
        let mut out = Vec::new();
        rmpv::encode::write_value(&mut out, &value).unwrap();
        out
    }

    #[test]
    fn an_upload_is_built_for_the_node_from_its_announce_and_a_node_not_heard_is_an_error() {
        let (identity, delivery, key) = distro();
        let msg = message_from(identity, &delivery);
        assert_eq!(set_c(msg, "leave", "public.general", 1_767_225_600_000, DEVICE), 0);
        let packed = pack(msg);

        let build = |node: &[u8; 16]| {
            let mut len = 0u32;
            let ptr = retichat_propagation_build_upload(
                key.as_ptr(), key.len() as u32, packed.as_ptr(), packed.len() as u32, node.as_ptr(), 16, &mut len,
            );
            if ptr.is_null() { None } else { Some(take(ptr, len)) }
        };

        // A node whose announce has not been heard has no known stamp cost: an error, nothing sent.
        let unheard = [0x6bu8; 16];
        assert!(build(&unheard).is_none());
        assert!(rns::take_error().unwrap_or_default().contains("not known"));

        // Once heard (cost 0, a free node), the upload is the packed message encrypted to the
        // distro and stamped; a sibling unwraps it with the distro key.
        let heard = [0x6cu8; 16];
        let node_identity = Identity::new(true);
        Identity::remember_destination(&heard, &node_identity.get_public_key().unwrap(), Some(node_app_data(0))).unwrap();
        let upload = build(&heard).expect("an upload");
        assert_eq!(&upload[..2], &[0x92, 0xcb], "a native array of an f64 timestamp and the blob array");
        assert_eq!(upload[10], 0x91);
        let data_start = match upload[11] { 0xc4 => 13, 0xc5 => 14, other => panic!("bin header {other:#x}") };
        let data = &upload[data_start..];
        assert_eq!(&data[..16], &delivery[..], "the node reads dest in the clear at offset 0");
        let mut holder = rns::get_handle::<Identity>(identity).unwrap();
        let unwrapped = lxmf_rust::distro::unwrap_blob(&mut holder, &data[..data.len() - 32]).unwrap().expect("addressed to the distro");
        assert!(unwrapped.signature_validated);
        assert!(unwrapped.is_delivery_notification, "an older client drops it");

        // Another distro's key is refused: the key must produce the message's destination.
        let other = Identity::new(true).get_public_key().unwrap();
        let mut len = 0u32;
        let ptr = retichat_propagation_build_upload(
            other.as_ptr(), other.len() as u32, packed.as_ptr(), packed.len() as u32, heard.as_ptr(), 16, &mut len,
        );
        assert!(ptr.is_null());
        assert!(rns::take_error().unwrap_or_default().contains("does not produce"));
        // A node that is not 16 bytes is an error too.
        let ptr = retichat_propagation_build_upload(
            key.as_ptr(), key.len() as u32, packed.as_ptr(), packed.len() as u32, heard.as_ptr(), 15, &mut len,
        );
        assert!(ptr.is_null());
    }

    /// `sig(64) | sealed` from `retichat_distro_seal`.
    fn seal(identity: u64, packed: &[u8]) -> Option<(Vec<u8>, Vec<u8>)> {
        let mut len = 0u32;
        let ptr = retichat_distro_seal(identity, packed.as_ptr(), packed.len() as u32, &mut len);
        if ptr.is_null() {
            return None;
        }
        let out = take(ptr, len);
        assert!(out.len() > 64 + 16);
        Some((out[..64].to_vec(), out[64..].to_vec()))
    }

    /// The seal goes through the C API as `lxmf_rust::distro::seal_for_sync` makes it (RFed SPEC
    /// §17.13; DISTRO-SYNC-PROOF-DESIGN.md §5.1): addressed to D in the clear, the message packed when
    /// the user acted inside it, and D's signature over the 65 signed bytes; a message not addressed to
    /// the distro, or a distro handle that is not one, is refused at the C boundary.
    #[test]
    fn a_message_is_sealed_once_through_the_c_api_and_signed_by_its_distro() {
        let (identity, delivery, key) = distro();
        let msg = message_from(identity, &delivery);
        assert_eq!(set_c(msg, "join", "public.general", 1_767_225_600_000, DEVICE), 0);
        let packed = pack(msg);
        let (sig, sealed) = seal(identity, &packed).expect("sealed");
        assert_eq!(&sealed[..16], &delivery[..], "D_hash in the clear: what the node and RFed read");
        let transient_id = lxmf_rust::distro::sync_transient_id(&sealed);
        let signed = lxmf_rust::distro::sync_signed_bytes(&delivery, &transient_id);
        assert_eq!(&signed[..17], b"rfed.distro.sync\x01", "the tag and the version");
        let d = Identity::from_public_key(&key).unwrap();
        assert!(d.validate(&sig, &signed), "D's Ed25519 signature over tag | 01 | D_hash | SHA-256(sealed)");
        let mut holder = rns::get_handle::<Identity>(identity).unwrap();
        let m = lxmf_rust::distro::unwrap_blob(&mut holder, &sealed).unwrap().expect("addressed to the distro");
        assert!(m.signature_validated);
        assert!(m.is_delivery_notification, "C still passes for a delivery notification with an older client");
        // A second seal is another encryption (a fresh ephemeral key): the outbox seals once, when it owes.
        let (_, again) = seal(identity, &packed).unwrap();
        assert_ne!(again, sealed);

        // Another distro's message, a handle that is not one, nothing at all: refused, with the reason.
        let (other, _other_delivery, _) = distro();
        assert!(seal(other, &packed).is_none());
        assert!(rns::take_error().unwrap_or_default().contains("not addressed to the distro"));
        assert!(seal(0xdead_beef, &packed).is_none());
        assert!(rns::take_error().unwrap_or_default().contains("invalid distro identity handle"));
        assert!(seal(identity, &[]).is_none());
    }

    /// The sealed build through the C API: a node not heard is an error (and its path is asked for),
    /// as the legacy build; once heard, `with_claim` 1 gives the three-element upload whose claim RFed
    /// accepts and 0 the two-element one, both carrying the stored sealed bytes unchanged.
    #[test]
    fn a_sealed_upload_carries_the_claim_only_when_asked_and_a_node_not_heard_is_an_error() {
        let (identity, delivery, key) = distro();
        let msg = message_with(identity, &delivery, "a sent copy");
        let packed = pack(msg);
        let (sig, sealed) = seal(identity, &packed).unwrap();

        let build = |node: &[u8; 16], with_claim: i32| {
            let mut len = 0u32;
            let ptr = retichat_propagation_build_sealed_upload(
                key.as_ptr(), key.len() as u32, sealed.as_ptr(), sealed.len() as u32, sig.as_ptr(), sig.len() as u32,
                with_claim, node.as_ptr(), 16, &mut len,
            );
            if ptr.is_null() { None } else { Some(take(ptr, len)) }
        };
        let unheard = [0x7bu8; 16];
        assert!(build(&unheard, 1).is_none());
        assert!(rns::take_error().unwrap_or_default().contains("not known"));

        let heard = [0x7cu8; 16];
        let node_identity = Identity::new(true);
        Identity::remember_destination(&heard, &node_identity.get_public_key().unwrap(), Some(node_app_data(0))).unwrap();
        for (with_claim, elements) in [(1, 3usize), (0, 2)] {
            let upload = build(&heard, with_claim).expect("an upload");
            let rmpv::Value::Array(items) = rmpv::decode::read_value(&mut &upload[..]).unwrap() else { panic!("an array") };
            assert_eq!(items.len(), elements, "with_claim {with_claim}");
            let rmpv::Value::Array(ref messages) = items[1] else { panic!("messages") };
            let rmpv::Value::Binary(ref data) = messages[0] else { panic!("a bin") };
            assert_eq!(&data[..data.len() - 32], &sealed[..], "the stored sealed bytes, never encrypted again");
            if elements == 3 {
                let claims = lxmf_rust::distro::decode_sync_extension(&items[2], 1);
                assert_eq!(claims.by_id.len(), 1);
                let claim = claims.by_id.values().next().unwrap();
                let transient_id = lxmf_rust::distro::sync_transient_id(&sealed);
                assert!(lxmf_rust::distro::verify_sync_claim(claim, &transient_id, &sealed).is_ok(), "RFed accepts the claim");
            }
        }
        // A node that is not 16 bytes is an error too.
        let mut len = 0u32;
        let ptr = retichat_propagation_build_sealed_upload(
            key.as_ptr(), key.len() as u32, sealed.as_ptr(), sealed.len() as u32, sig.as_ptr(), sig.len() as u32,
            1, heard.as_ptr(), 15, &mut len,
        );
        assert!(ptr.is_null());
        assert_eq!(len, 0);
    }

    /// The Swift header must say what the Rust library does: the six functions and the two callback
    /// typedefs of the distro outbox, with the signatures the library exports.
    #[test]
    fn the_header_declares_the_distro_outbox_exports() {
        let header = include_str!("../../../Retichat/Bridge/CRetichatFFI.h");
        let flat: String = header.split_whitespace().collect::<Vec<_>>().join(" ");
        for declaration in [
            "int32_t retichat_message_set_distro_channel_sync(uint64_t msg, const char *op, const char *name, int64_t at_ms, const char *device_hex);",
            "uint8_t *retichat_message_pack(uint64_t msg, uint32_t *out_len);",
            "uint8_t *retichat_propagation_build_upload(const uint8_t *distro_public_key, uint32_t key_len, const uint8_t *packed, uint32_t packed_len, const uint8_t *node, uint32_t node_len, uint32_t *out_len);",
            "uint8_t *retichat_propagation_link(const uint8_t *node, uint32_t node_len, uint32_t *out_len);",
            "typedef void (*retichat_upload_event_t)(void *context, int32_t event);",
            "typedef void (*retichat_upload_release_t)(void *context);",
            "uint8_t *retichat_propagation_upload(const uint8_t *node, uint32_t node_len, const uint8_t *upload, uint32_t upload_len, retichat_upload_event_t event, retichat_upload_release_t release, void *context, uint32_t *out_len);",
            "typedef void (*retichat_link_event_t)(void *context, const uint8_t *dest, uint32_t dest_len, uint8_t status, const uint8_t *link_id, uint32_t link_id_len);",
            "int32_t retichat_propagation_link_events_register(retichat_link_event_t callback, void *context);",
            "typedef void (*retichat_interface_up_t)(void *context, const uint8_t *name, uint32_t name_len);",
            "int32_t retichat_interface_up_register(retichat_interface_up_t callback, void *context);",
            "void retichat_interface_up_clear(void);",
            "typedef void (*retichat_group_delivery_callback_t)(void *context, const uint8_t *hash, uint32_t hash_len, const uint8_t *src_hash, uint32_t src_len, const uint8_t *dest_hash, uint32_t dest_len, const char *title, const char *content, double timestamp, int32_t signature_valid, int32_t unverified_reason, const uint8_t *fields_raw, uint32_t fields_len, const uint8_t *sender_key, uint32_t sender_key_len, const uint8_t *packed, uint32_t packed_len);",
            "int32_t retichat_client_set_delivery_callback_receipt(uint64_t client, retichat_group_delivery_callback_t callback, void *context);",
            "uint8_t *retichat_group_unpack_packed(const uint8_t *packed, uint32_t packed_len, uint32_t *out_len);",
            "int32_t retichat_message_set_retichat_statuses(uint64_t msg, const uint8_t *elements, uint32_t elements_len);",
            "uint8_t *retichat_distro_seal(uint64_t distro_handle, const uint8_t *packed, uint32_t packed_len, uint32_t *out_len);",
            "uint8_t *retichat_propagation_build_sealed_upload(const uint8_t *distro_public_key, uint32_t key_len, const uint8_t *sealed, uint32_t sealed_len, const uint8_t *sig, uint32_t sig_len, int32_t with_claim, const uint8_t *node, uint32_t node_len, uint32_t *out_len);",
            "uint64_t retichat_interface_up_mark(void);",
            "int32_t retichat_interface_came_up_since(uint64_t mark);",
            "int32_t retichat_message_set_distro_group_sync(uint64_t msg, const char *sync_json, const char *d_hex, const char *device_hex);",
        ] {
            assert!(flat.contains(declaration), "the header lacks: {declaration}");
        }
        let _: extern "C" fn(u64, *const u8, u32, *mut u32) -> *mut u8 = retichat_distro_seal;
        let _: extern "C" fn(*const u8, u32, *const u8, u32, *const u8, u32, i32, *const u8, u32, *mut u32) -> *mut u8 =
            retichat_propagation_build_sealed_upload;
        let _: extern "C" fn() -> u64 = retichat_interface_up_mark;
        let _: extern "C" fn(u64) -> i32 = retichat_interface_came_up_since;
        let _: extern "C" fn(u64, *const c_char, *const c_char, i64, *const c_char) -> i32 = retichat_message_set_distro_channel_sync;
        let _: extern "C" fn(u64, *const c_char, *const c_char, *const c_char) -> i32 = retichat_message_set_distro_group_sync;
        let _: extern "C" fn(u64, *mut u32) -> *mut u8 = retichat_message_pack;
        let _: extern "C" fn(*const u8, u32, *const u8, u32, *const u8, u32, *mut u32) -> *mut u8 = retichat_propagation_build_upload;
        let _: extern "C" fn(*const u8, u32, *mut u32) -> *mut u8 = retichat_propagation_link;
        let _: extern "C" fn(
            *const u8, u32, *const u8, u32,
            Option<extern "C" fn(*mut c_void, i32)>, Option<extern "C" fn(*mut c_void)>,
            *mut c_void, *mut u32,
        ) -> *mut u8 = retichat_propagation_upload;
        let _: extern "C" fn(Option<extern "C" fn(*mut c_void, *const u8, u32, u8, *const u8, u32)>, *mut c_void) -> i32 =
            retichat_propagation_link_events_register;
        let _: extern "C" fn(Option<extern "C" fn(*mut c_void, *const u8, u32)>, *mut c_void) -> i32 = retichat_interface_up_register;
        let _: extern "C" fn() = retichat_interface_up_clear;
        let _: extern "C" fn(*const u8, u32, *mut u32) -> *mut u8 = retichat_group_unpack_packed;
        let _: extern "C" fn(u64, *const u8, u32) -> i32 = retichat_message_set_retichat_statuses;
        let _: extern "C" fn(u64, GroupDeliveryCallback, *mut c_void) -> i32 = retichat_client_set_delivery_callback_receipt;
    }

    /// LXMF-rust's group sync vectors (GROUPS-DISTRO-DESIGN.md §17.1), the copy `group_status.rs`
    /// checks against LXMF-rust's own.
    const GROUP_SYNC_VECTORS: &str = include_str!("../tests/data/distro_group_sync_vectors.json");

    fn group_vectors() -> serde_json::Value {
        serde_json::from_str(GROUP_SYNC_VECTORS).expect("the group sync vectors are JSON")
    }

    fn unhex(s: &str) -> Vec<u8> {
        (0..s.len() / 2).map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap()).collect()
    }

    /// The vectors' distro D as a handle, its `lxmf.delivery` hash and that hash in hex.
    fn vector_distro(v: &serde_json::Value) -> (u64, [u8; 16], String) {
        let identity = Identity::from_bytes(&unhex(v["distro"]["private_key_hex"].as_str().unwrap())).unwrap();
        let handle = rns::store_handle(identity);
        let mut delivery = [0u8; 16];
        assert_eq!(retichat_distro_delivery_hash(handle, delivery.as_mut_ptr(), 16), 16);
        assert_eq!(hex(&delivery), v["distro"]["lxmf_delivery_hash_hex"].as_str().unwrap());
        (handle, delivery, hex(&delivery))
    }

    fn unwrap_json(handle: u64, blob: &[u8]) -> serde_json::Value {
        let mut len = 0u32;
        let ptr = retichat_distro_unwrap(handle, blob.as_ptr(), blob.len() as u32, &mut len);
        serde_json::from_slice(&take(ptr, len)).expect("the unwrap JSON")
    }

    /// GROUPS-DISTRO-DESIGN.md §7, §17.2, §19.1: the C unwrap runs this crate's group receipt. M's
    /// accept to D, M unknown here, carrying M's key, is validated under it, with M's key and the
    /// packed copy; the same accept signed by another key is invalid (2); a plain post has neither.
    #[test]
    fn the_distro_unwrap_through_the_c_api_runs_the_group_receipt() {
        let v = group_vectors();
        let (handle, _, _) = vector_distro(&v);
        let member_key = v["member"]["public_key_hex"].as_str().unwrap();
        for (name, key, packed, verdict) in [
            ("member_accept_legacy", Some(member_key), true, (true, 0)),
            ("member_accept_forged", Some(member_key), true, (false, 2)),
            ("member_post_legacy", None, false, (false, 1)),
            ("member_invite_retichat_field", None, false, (false, 1)),
        ] {
            let vector = v["sealed"].as_array().unwrap().iter().find(|s| s["name"] == name).unwrap();
            let out = unwrap_json(handle, &unhex(vector["blob_hex"].as_str().unwrap()));
            assert_eq!(out["sender_key"].as_str(), key, "{name}: sender_key");
            if packed {
                let b64 = out["packed"].as_str().unwrap_or_else(|| panic!("{name}: packed is null"));
                use base64::Engine as _;
                let bytes = base64::engine::general_purpose::STANDARD.decode(b64).unwrap();
                assert_eq!(hex(&bytes), vector["packed_hex"].as_str().unwrap(), "{name}: packed");
            } else {
                assert!(out["packed"].is_null(), "{name}: packed");
            }
            assert_eq!(
                (out["signature_validated"].as_bool().unwrap(), out["unverified_reason"].as_u64().unwrap()),
                verdict,
                "{name}: the receipt's verdict"
            );
            assert_eq!(out["hash"], vector["hash_hex"], "{name}");
            assert_eq!(out["group_id"], vector["expected"]["group_id"], "{name}");
        }
    }

    fn set_g(msg: u64, sync_json: &str, d_hex: &str, device: &str) -> i32 {
        let (json, d, device) = (CString::new(sync_json).unwrap(), CString::new(d_hex).unwrap(), CString::new(device).unwrap());
        retichat_message_set_distro_group_sync(msg, json.as_ptr(), d.as_ptr(), device.as_ptr())
    }

    /// RFed SPEC §17.14: each op of the vectors, written through the C function on a message from
    /// D to D, packs to the fields Python packed (the timestamp is the clock's, so only the fields
    /// are compared; LXMF-rust compares whole messages).
    #[test]
    fn g_goes_through_the_c_api_as_the_vectors_give_it() {
        let v = group_vectors();
        let (identity, delivery, d_hex) = vector_distro(&v);
        let device = v["device_hex"].as_str().unwrap();
        for op in v["ops"].as_array().unwrap() {
            let msg = message_from(identity, &delivery);
            assert_eq!(set_g(msg, &op["sync"].to_string(), &d_hex, device), 0, "{}: {:?}", op["name"], rns::take_error());
            let packed = pack(msg);
            assert!(hex(&packed).ends_with(op["fields_hex"].as_str().unwrap()), "{}: the fields Python packed", op["name"]);
            assert_eq!(lxmf_message_destroy(msg), 0);
        }
    }

    #[test]
    fn g_is_refused_at_the_c_boundary_and_the_message_is_unchanged() {
        let v = group_vectors();
        let (identity, delivery, d_hex) = vector_distro(&v);
        let leave = r#"{"op":"leave","group_id":"9f8e7d6c5b4a39281706f5e4d3c2b1a0","at_ms":5,"left":[]}"#;
        let stranger = r#"{"op":"create","group_id":"9f8e7d6c5b4a39281706f5e4d3c2b1a0","at_ms":5,"name":"n","members":"abababababababababababababababab","keys":[],"left":[]}"#;
        let msg = message_from(identity, &delivery);
        for (json, d, device, why) in [
            ("{", d_hex.as_str(), DEVICE, "not JSON"),
            (r#"{"op":"leave","group_id":"9f8e7d6c5b4a39281706f5e4d3c2b1a0","at_ms":5}"#, d_hex.as_str(), DEVICE, "left is missing"),
            (stranger, d_hex.as_str(), DEVICE, "does not name D"),
            (leave, "xyz", DEVICE, "d_hex"),
            (leave, d_hex.as_str(), "xyz", "0xFD"),
        ] {
            assert_eq!(set_g(msg, json, d, device), -1, "{why}");
            let error = rns::take_error().unwrap_or_default();
            assert!(error.contains(why), "{why}: {error}");
        }
        assert_eq!(set_g(0, leave, &d_hex, DEVICE), -1);
        assert!(rns::take_error().unwrap_or_default().contains("invalid message handle"));
        assert_eq!(retichat_message_set_distro_group_sync(msg, std::ptr::null(), std::ptr::null(), std::ptr::null()), -1);
        // A refused call wrote nothing. (Not packed here: an empty message with no fields cannot be,
        // see message_with.)
        let message = rns::get_handle::<Arc<Mutex<lxmf_rust::lx_message::LXMessage>>>(msg).unwrap();
        assert_eq!(message.lock().unwrap().fields, rmpv::Value::Map(Vec::new()));
        // A message that is not from D to D is refused too.
        let (other, other_delivery, _) = distro();
        let not_d = message_from(other, &other_delivery);
        assert_eq!(set_g(not_d, leave, &d_hex, DEVICE), -1);
        assert!(rns::take_error().unwrap_or_default().contains("from D to D"));
    }

    /// The statuses reach a real outbound message through the C function: key 10 in the Retichat field,
    /// an array of bin, in the form the receiver's reader takes, and a list the buffer cannot hold changes nothing.
    #[test]
    fn the_c_function_writes_key_10_as_an_array_of_bin_and_refuses_a_bad_list() {
        let (identity, delivery, _key) = distro();
        let msg = message_from(identity, &delivery);
        assert_ne!(msg, 0);
        let element = vec![7u8; 97];
        let flat = group_status::encode_elements(&[element.clone()]);
        assert_eq!(retichat_message_set_retichat_statuses(msg, flat.as_ptr(), flat.len() as u32), 0);
        let message = rns::get_handle::<Arc<Mutex<lxmf_rust::lx_message::LXMessage>>>(msg).unwrap();
        let fields = message.lock().unwrap().fields.clone();
        let rf = lxmf_rust::retichat_field::read_entry(&fields, group_status::RF_GROUP_STATUSES).cloned();
        assert_eq!(rf, Some(rmpv::Value::Array(vec![rmpv::Value::Binary(element)])), "an array of bin, never a bin of packed msgpack");
        // A list that does not hold what it says, and an element too short to be a message, change nothing.
        assert_eq!(retichat_message_set_retichat_statuses(msg, [0u8, 0, 0, 2, 0, 0, 0, 1].as_ptr(), 8), -1);
        assert!(rns::take_error().unwrap_or_default().contains("element"));
        let tiny = group_status::encode_elements(&[vec![1u8; 96]]);
        assert_eq!(retichat_message_set_retichat_statuses(msg, tiny.as_ptr(), tiny.len() as u32), -1);
        assert_eq!(retichat_message_set_retichat_statuses(0xdead_beef, flat.as_ptr(), flat.len() as u32), -1);
        // An empty list is a creator's valid answer.
        let none = group_status::encode_elements(&[]);
        assert_eq!(retichat_message_set_retichat_statuses(msg, none.as_ptr(), none.len() as u32), 0);
        let fields = message.lock().unwrap().fields.clone();
        let rf = lxmf_rust::retichat_field::read_entry(&fields, group_status::RF_GROUP_STATUSES).cloned();
        assert_eq!(rf, Some(rmpv::Value::Array(vec![])));
    }
}

/// RFed SPEC §17.14 "Repeated keys", "Unhashable keys" and "Nesting" (James, 2026-10-11, and
/// decided 2026-10-11: parity), at the C API the app calls: a message whose payload repeats a key,
/// has a key Python cannot hash or nests past depth 493 is refused whole by the distro unwrap and
/// by the group receipt's unpack, with an error the Swift callers know as a refusal (already
/// logged once, by LXMF-rust), so they say nothing more.
#[cfg(test)]
mod repeated_keys_bridge_tests {
    use super::*;

    const GROUP_SYNC_VECTORS: &str = include_str!("../tests/data/distro_group_sync_vectors.json");

    fn unhex(s: &str) -> Vec<u8> {
        (0..s.len() / 2).map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap()).collect()
    }

    /// The Swift side tells a refusal by this prefix (`RepeatedKeys.refusedWhole`, LxmfFields.swift).
    #[test]
    fn the_swift_refusal_prefix_is_lxmf_rusts() {
        let swift = include_str!("../../../Retichat/Bridge/LxmfFields.swift");
        let line = format!("static let refusedWhole = \"{}\"", lxmf_rust::msgpack_keys::REFUSED_WHOLE);
        assert!(swift.contains(&line), "LxmfFields.swift lacks: {line}");
    }

    /// Every `refused` vector and every refused `key_equality` pair and `nesting` vector, sealed
    /// for D: the C unwrap returns NULL with an error that starts with the refusal prefix and names
    /// the reference's reason, and the C group unpack returns NULL too; every pair and nesting
    /// vector the reference reads is unwrapped and unpacked. On a 64 MiB stack: a debug build's
    /// rmpv reader spends about 4.9 KB a level (about 260 B in release), and the nesting vectors
    /// are read to depth 493.
    #[test]
    fn the_c_unwrap_and_the_c_group_unpack_refuse_what_python_refuses() {
        std::thread::Builder::new().stack_size(64 << 20).spawn(c_refusals).unwrap().join().unwrap();
    }

    fn c_refusals() {
        let v: serde_json::Value = serde_json::from_str(GROUP_SYNC_VECTORS).unwrap();
        let key = unhex(v["distro"]["private_key_hex"].as_str().unwrap());
        let d = Identity::from_bytes(&key).unwrap();
        let handle = rns::store_handle(Identity::from_bytes(&key).unwrap());
        let refused = v["refused"].as_array().unwrap();
        let pairs = v["key_equality"].as_array().unwrap();
        let nesting = v["nesting"].as_array().unwrap();
        assert_eq!((refused.len(), pairs.len(), nesting.len()), (22, 24, 11));
        let mut refusals = 0;
        for vector in refused.iter().chain(pairs).chain(nesting) {
            let name = vector["name"].as_str().unwrap();
            let refuse = vector.get("refused").map_or(true, |r| r.as_bool().unwrap());
            let why = match vector["reason"].as_str().unwrap_or("repeated_key") {
                "repeated_key" => "repeats a key",
                "unhashable_key" => "cannot hash",
                "too_deep" => "nested past depth",
                other => panic!("{name}: unknown reason {other}"),
            };
            let packed = unhex(vector["packed_hex"].as_str().unwrap());
            let blob = [packed[..16].to_vec(), d.encrypt(&packed[16..]).unwrap()].concat();
            let mut len = 0u32;
            let unwrapped = retichat_distro_unwrap(handle, blob.as_ptr(), blob.len() as u32, &mut len);
            let unwrap_error = rns::take_error();
            let mut element_len = 0u32;
            let element = retichat_group_unpack_packed(packed.as_ptr(), packed.len() as u32, &mut element_len);
            let element_error = rns::take_error();
            if refuse {
                refusals += 1;
                assert!(unwrapped.is_null(), "{name}: the unwrap must refuse it");
                let error = unwrap_error.unwrap_or_default();
                assert!(lxmf_rust::msgpack_keys::is_refusal(&error) && error.contains(why), "{name}: {error}");
                assert!(element.is_null(), "{name}: the group unpack must refuse it");
                assert!(element_error.unwrap_or_default().contains(why), "{name}: the group unpack's error");
            } else {
                assert!(!unwrapped.is_null() && len > 0, "{name}: unwrapped ({unwrap_error:?})");
                rns_free_bytes(unwrapped, len);
                assert!(!element.is_null(), "{name}: unpacked ({element_error:?})");
                rns_free_bytes(element, element_len);
            }
        }
        assert_eq!(refusals, 22 + 15 + 6);
    }
}
