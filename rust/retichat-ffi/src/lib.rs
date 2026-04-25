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
pub use reticulum_rust::cffi::*;
pub use lxmf_rust::cffi::*;

use std::ffi::CStr;
use std::os::raw::c_char;
use std::sync::{Arc, Mutex, OnceLock};

use sha2::{Digest, Sha256};
use reticulum_rust::ffi as rns;
use reticulum_rust::destination::{Destination, DestinationType};
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
pub extern "C" fn retichat_identity_public_key(
    handle: u64,
    out_buf: *mut u8,
    buf_len: u32,
) -> i32 {
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
            unsafe { std::ptr::copy_nonoverlapping(sig.as_ptr(), out_sig, 64); }
            64
        }
        Err(e) => {
            rns::set_error(e);
            -1
        }
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
    if rns::transport_has_path(&h) { 1 } else { 0 }
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
    let asp_vec: Vec<String> = asp_str
        .split(',')
        .map(|s| s.trim().to_string())
        .collect();
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

    match rns::packet_send(packet_handle) {
        Ok(_) => 0,
        Err(e) => {
            rns::set_error(e);
            -1
        }
    }
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
    let asp_vec: Vec<String> = asp_str
        .split(',')
        .map(|s| s.trim().to_string())
        .collect();
    let p = unsafe { cstr_to_string(path) };
    let data = slice_from_raw(payload, payload_len);

    match rns::link_request(&hash, &app, asp_vec, identity_handle, &p, &data, timeout_secs) {
        Ok(response) => {
            let len = response.len() as u32;
            let boxed = response.into_boxed_slice();
            let raw = Box::into_raw(boxed);
            if !out_len.is_null() {
                unsafe { *out_len = len; }
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
// RFed Delivery — inbound channel blob endpoint
// ---------------------------------------------------------------------------

/// C callback fired when a blob arrives at the local rfed.delivery destination.
///
/// `data`/`len` — raw inner blob bytes.
/// `ctx`        — pointer passed to `retichat_rfed_delivery_start`.
pub type RfedBlobCallback = extern "C" fn(data: *const u8, len: u32, ctx: *mut std::ffi::c_void);

/// Wraps a raw `*mut c_void` so it can be sent across threads.
/// The C caller is responsible for lifetime management of the pointed object.
struct SendableCtx(usize);
unsafe impl Send for SendableCtx {}
unsafe impl Sync for SendableCtx {}

struct RfedDeliveryState {
    dest: Destination,
    callback: Option<RfedBlobCallback>,
    ctx: SendableCtx,
}

static RFED_DELIVERY: OnceLock<Mutex<Option<RfedDeliveryState>>> = OnceLock::new();

fn rfed_delivery_storage() -> &'static Mutex<Option<RfedDeliveryState>> {
    RFED_DELIVERY.get_or_init(|| Mutex::new(None))
}

/// Register an inbound `rfed.delivery` destination so the rfed server can
/// push channel blobs to this device.
///
/// * `identity_handle` — LXMF client identity handle (from `lxmf_client_identity_handle`).
/// * `callback`        — called on a background thread whenever a blob arrives.
/// * `ctx`             — opaque context pointer forwarded to every `callback` call.
///
/// Returns 0 on success, -1 on error (check `lxmf_last_error`).
/// Call `retichat_rfed_delivery_announce` afterwards to flush deferred blobs.
#[no_mangle]
pub extern "C" fn retichat_rfed_delivery_start(
    identity_handle: u64,
    callback: Option<RfedBlobCallback>,
    ctx: *mut std::ffi::c_void,
) -> i32 {
    let identity: Identity = match rns::get_handle(identity_handle) {
        Some(id) => id,
        None => {
            rns::set_error("invalid identity handle".into());
            return -1;
        }
    };

    // Build inbound rfed.delivery destination from this identity.
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

    // Register packet callback — fires on the Reticulum worker thread.
    let cb = callback;
    let ctx_usize = ctx as usize;
    let packet_cb: Arc<dyn Fn(&[u8], &Packet) + Send + Sync> =
        Arc::new(move |data: &[u8], _pkt: &Packet| {
            if let Some(f) = cb {
                f(data.as_ptr(), data.len() as u32, ctx_usize as *mut std::ffi::c_void);
            }
        });
    dest.set_packet_callback(Some(packet_cb));
    Transport::register_destination(dest.clone());

    let mut guard = rfed_delivery_storage().lock().unwrap();
    *guard = Some(RfedDeliveryState {
        dest,
        callback: cb,
        ctx: SendableCtx(ctx_usize),
    });
    0
}

/// Announce the local `rfed.delivery` destination so the rfed server flushes
/// any deferred blobs queued for this subscriber.
///
/// Call this at startup, on foreground transitions, and after reconnecting.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn retichat_rfed_delivery_announce() -> i32 {
    let mut guard = rfed_delivery_storage().lock().unwrap();
    if let Some(ref mut state) = *guard {
        if let Err(e) = state.dest.announce(None, false, None, None, true) {
            rns::set_error(e);
            return -1;
        }
        return 0;
    }
    rns::set_error("rfed delivery not started — call retichat_rfed_delivery_start first".into());
    -1
}

/// Tear down the local `rfed.delivery` endpoint.
/// The destination is deregistered from the Reticulum transport.
/// Returns 0 always.
#[no_mangle]
pub extern "C" fn retichat_rfed_delivery_stop() -> i32 {
    let mut guard = rfed_delivery_storage().lock().unwrap();
    if let Some(state) = guard.take() {
        Transport::deregister_destination(&state.dest.hash);
    }
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
    let seed: [u8; 32] = Sha256::digest(name.as_bytes()).into();
    // Same seed used for both X25519 (encryption) and Ed25519 (signing),
    // mirroring ChannelKeypair::from_name in RFed-rust/rfed/src/channel.rs.
    let mut prv = [0u8; 64];
    prv[..32].copy_from_slice(&seed);
    prv[32..].copy_from_slice(&seed);
    prv
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
            unsafe { *out_len = 0; }
            return std::ptr::null_mut();
        }
    };
    match identity.encrypt(&pt) {
        Ok(ct) => {
            let len = ct.len() as u32;
            let mut boxed = ct.into_boxed_slice();
            let ptr = boxed.as_mut_ptr();
            std::mem::forget(boxed);
            unsafe { *out_len = len; }
            ptr
        }
        Err(e) => {
            rns::set_error(e);
            unsafe { *out_len = 0; }
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
            unsafe { *out_len = 0; }
            return std::ptr::null_mut();
        }
    };
    match identity.decrypt(&ct) {
        Ok(pt) => {
            let len = pt.len() as u32;
            let mut boxed = pt.into_boxed_slice();
            let ptr = boxed.as_mut_ptr();
            std::mem::forget(boxed);
            unsafe { *out_len = len; }
            ptr
        }
        Err(e) => {
            rns::set_error(e);
            unsafe { *out_len = 0; }
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
        unsafe { *out_len = 0; }
        return std::ptr::null_mut();
    }
    let data = slice_from_raw(payload, payload_len);
    let transient_id = reticulum_rust::identity::full_hash(&data);
    let workblock = LXStamper::stamp_workblock(&transient_id, 16);
    let (stamp, value) = LXStamper::generate_stamp(&transient_id, cost, 16);
    // generate_stamp may silently return a sub-cost stamp if it exhausts
    // its internal iteration cap.  Verify against the SAME workblock the
    // rfed node uses, so we never ship a stamp that will be rejected.
    if value < cost || !LXStamper::stamp_valid(&stamp, cost, &workblock) {
        rns::set_error(format!(
            "stamp PoW failed: required cost={} but achieved value={} (payload_len={}). \
             Either iteration cap exceeded or workblock mismatch.",
            cost, value, data.len()
        ));
        unsafe { *out_len = 0; }
        return std::ptr::null_mut();
    }
    let len = stamp.len() as u32;
    let mut boxed = stamp.into_boxed_slice();
    let ptr = boxed.as_mut_ptr();
    std::mem::forget(boxed);
    unsafe { *out_len = len; }
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

use lxmf_rust::lx_message::LXMessage;

const LXMF_APP_NAME: &str = "lxmf";
const LXMF_DELIVERY_ASPECT: &str = "delivery";

fn channel_identity(name: &str) -> Result<Identity, String> {
    let prv = channel_private_key_bytes(name);
    Identity::from_bytes(&prv)
}

fn channel_destination(name: &str) -> Result<Destination, String> {
    let id = channel_identity(name)?;
    Destination::new_outbound(
        Some(id),
        DestinationType::Single,
        LXMF_APP_NAME.to_string(),
        vec![LXMF_DELIVERY_ASPECT.to_string()],
    )
}

/// Build an LXMF message addressed to the channel destination and pack it
/// into the on-wire payload.  The caller is responsible for appending the
/// optional PoW stamp suffix and sending the result as the `rfed.channel`
/// SEND payload.
///
/// Inputs:
///   * `name_ptr`           — channel name (UTF-8 C string), e.g. "public.general"
///   * `sender_handle`      — identity handle of the local user (the *source*)
///   * `content_ptr/_len`   — message body bytes (UTF-8)
///   * `title_ptr/_len`     — optional title bytes (UTF-8); pass NULL/0 for none
///
/// Returns a heap-allocated buffer (free with `lxmf_free_bytes`) in the
/// following layout, or NULL on error (call `lxmf_last_error`):
///
///     offset  size  field
///     ------  ----  -----
///     0       8     timestamp_ms_be    (u64 BE) — the LXMF timestamp the
///                                       sender baked into the signed
///                                       payload, returned out-of-band so
///                                       the caller can match it against
///                                       the echo for local-persist dedup.
///     8       16    channel_id_hash    (the routing label for RFed)
///     24      *     EC_encrypted(source_hash || signature || msgpack_payload)
///
/// The wire payload is `output[8..]` — the 8-byte timestamp prefix is
/// stripped before sending.
#[no_mangle]
pub extern "C" fn retichat_channel_lxm_pack(
    name_ptr: *const c_char,
    sender_handle: u64,
    content_ptr: *const u8,
    content_len: u32,
    title_ptr: *const u8,
    title_len: u32,
    out_len: *mut u32,
) -> *mut u8 {
    let name = unsafe { cstr_to_string(name_ptr) };
    if name.is_empty() {
        rns::set_error("channel name is empty".into());
        unsafe { *out_len = 0; }
        return std::ptr::null_mut();
    }
    let content = slice_from_raw(content_ptr, content_len);
    let title = slice_from_raw(title_ptr, title_len);

    let sender_identity: Identity = match rns::get_handle::<Identity>(sender_handle) {
        Some(id) => id,
        None => {
            rns::set_error("invalid sender identity handle".into());
            unsafe { *out_len = 0; }
            return std::ptr::null_mut();
        }
    };

    let mut channel_dest = match channel_destination(&name) {
        Ok(d) => d,
        Err(e) => {
            rns::set_error(format!("channel destination: {}", e));
            unsafe { *out_len = 0; }
            return std::ptr::null_mut();
        }
    };
    let sender_dest = match Destination::new_outbound(
        Some(sender_identity),
        DestinationType::Single,
        LXMF_APP_NAME.to_string(),
        vec![LXMF_DELIVERY_ASPECT.to_string()],
    ) {
        Ok(d) => d,
        Err(e) => {
            rns::set_error(format!("sender destination: {}", e));
            unsafe { *out_len = 0; }
            return std::ptr::null_mut();
        }
    };

    let mut msg = match LXMessage::new(
        Some(channel_dest.clone()),
        Some(sender_dest),
        Some(content),
        Some(title),
        None,                              // fields = empty map (default)
        Some(LXMessage::PROPAGATED),       // desired_method
        None,
        None,
        None,                              // stamp_cost (PoW is at the RFed wrapper, not LXMF)
        false,                             // include_ticket
    ) {
        Ok(m) => m,
        Err(e) => {
            rns::set_error(format!("LXMessage::new: {}", e));
            unsafe { *out_len = 0; }
            return std::ptr::null_mut();
        }
    };

    if let Err(e) = msg.pack(false) {
        rns::set_error(format!("LXMessage::pack: {}", e));
        unsafe { *out_len = 0; }
        return std::ptr::null_mut();
    }

    // Build wire payload = [ channel_id_hash(16) | EC_encrypted(packed[16..]) ].
    //
    // packed[..16] is the LXMF `lxmf.delivery` destination_hash, used by
    // pack() when computing the signature.  We replace it on the wire with
    // the channel IDENTITY hash so RFed's `subscription_table` lookup
    // (which is keyed by the identity hash subscribers registered with
    // /rfed/subscribe) finds the right subscribers.  The receiver
    // reconstructs the canonical LXMF block by deriving the same
    // `lxmf.delivery` destination hash from the channel name before
    // calling LXMessage::unpack_from_bytes — so the signature still
    // validates against the original signed dest_hash.
    let packed = match msg.packed.as_ref() {
        Some(p) => p,
        None => {
            rns::set_error("LXMessage missing packed buffer after pack".into());
            unsafe { *out_len = 0; }
            return std::ptr::null_mut();
        }
    };
    if packed.len() < LXMessage::DESTINATION_LENGTH {
        rns::set_error("packed buffer too short".into());
        unsafe { *out_len = 0; }
        return std::ptr::null_mut();
    }
    let pn_enc = match channel_dest.encrypt(&packed[LXMessage::DESTINATION_LENGTH..]) {
        Ok(d) => d,
        Err(e) => {
            rns::set_error(format!("channel encrypt: {}", e));
            unsafe { *out_len = 0; }
            return std::ptr::null_mut();
        }
    };

    // The channel identity hash is the routing label RFed expects.
    let id_hash: Vec<u8> = match channel_identity(&name) {
        Ok(id) => match id.hash.clone() {
            Some(h) => h,
            None => {
                rns::set_error("channel identity has no hash".into());
                unsafe { *out_len = 0; }
                return std::ptr::null_mut();
            }
        },
        Err(e) => {
            rns::set_error(format!("channel identity: {}", e));
            unsafe { *out_len = 0; }
            return std::ptr::null_mut();
        }
    };
    if id_hash.len() != LXMessage::DESTINATION_LENGTH {
        rns::set_error("channel identity hash wrong length".into());
        unsafe { *out_len = 0; }
        return std::ptr::null_mut();
    }

    let mut wire = Vec::with_capacity(8 + LXMessage::DESTINATION_LENGTH + pn_enc.len());
    // Out-of-band: 8-byte LXMF timestamp prefix so the caller can use the
    // same tsMs for local persistence and echo dedup.
    let ts_ms: u64 = (msg.timestamp.unwrap_or(0.0) * 1000.0) as u64;
    wire.extend_from_slice(&ts_ms.to_be_bytes());
    wire.extend_from_slice(&id_hash);
    wire.extend_from_slice(&pn_enc);

    let len = wire.len() as u32;
    let mut boxed = wire.into_boxed_slice();
    let ptr = boxed.as_mut_ptr();
    std::mem::forget(boxed);
    unsafe { *out_len = len; }
    ptr
}

/// Unpack an LXMF channel message received via RFed.
///
/// Input is the wire payload as defined in `retichat_channel_lxm_pack`:
///     [ channel_id_hash(16) | EC_encrypted(source_hash || signature || payload) ]
/// (channel_id_hash = channel identity hash, the routing label RFed uses;
///  the EC-encrypted tail carries the LXMF authentication payload.)
///
/// Returns a heap-allocated buffer (free with `lxmf_free_bytes`) containing
/// a flat parsed-message struct in the following layout, or NULL on error:
///
///     offset  size  field
///     ------  ----  -----
///     0       16    source_hash
///     16      8     timestamp_ms_be      (u64, big-endian, milliseconds)
///     24      1     signature_validated  (1 = OK, 0 = NOT verified)
///     25      1     unverified_reason    (0 = ok, 1 = SOURCE_UNKNOWN,
///                                          2 = SIGNATURE_INVALID)
///     26      2     title_len_be         (u16, big-endian)
///     28      4     content_len_be       (u32, big-endian)
///     32      title_len    title bytes (UTF-8)
///     32+t    content_len  content bytes (UTF-8)
///
/// Total = 32 + title_len + content_len bytes.
#[no_mangle]
pub extern "C" fn retichat_channel_lxm_unpack(
    name_ptr: *const c_char,
    lxmf_data: *const u8,
    lxmf_data_len: u32,
    out_len: *mut u32,
) -> *mut u8 {
    let name = unsafe { cstr_to_string(name_ptr) };
    if name.is_empty() {
        rns::set_error("channel name is empty".into());
        unsafe { *out_len = 0; }
        return std::ptr::null_mut();
    }
    let data = slice_from_raw(lxmf_data, lxmf_data_len);
    if data.len() < LXMessage::DESTINATION_LENGTH + 32 {
        rns::set_error("lxmf_data too short".into());
        unsafe { *out_len = 0; }
        return std::ptr::null_mut();
    }

    // EC-decrypt the tail using the channel's deterministic identity.
    let mut id = match channel_identity(&name) {
        Ok(id) => id,
        Err(e) => {
            rns::set_error(format!("channel identity: {}", e));
            unsafe { *out_len = 0; }
            return std::ptr::null_mut();
        }
    };
    let encrypted = &data[LXMessage::DESTINATION_LENGTH..];
    let decrypted = match id.decrypt(encrypted) {
        Ok(p) => p,
        Err(e) => {
            rns::set_error(format!("channel decrypt: {}", e));
            unsafe { *out_len = 0; }
            return std::ptr::null_mut();
        }
    };

    // Reconstruct the LXMF canonical block [lxmf_dest | source | sig | payload]
    // using the lxmf.delivery destination_hash for the channel identity —
    // i.e. the same dest_hash the sender used inside LXMessage::pack when
    // it computed the signature.  (The wire prefix `data[..16]` is the
    // channel identity hash for RFed routing; it is NOT what the LXMF
    // signature was computed over.)
    let lxmf_dest = match channel_destination(&name) {
        Ok(d) => d.hash.clone(),
        Err(e) => {
            rns::set_error(format!("channel destination: {}", e));
            unsafe { *out_len = 0; }
            return std::ptr::null_mut();
        }
    };
    if lxmf_dest.len() != LXMessage::DESTINATION_LENGTH {
        rns::set_error("lxmf dest hash wrong length".into());
        unsafe { *out_len = 0; }
        return std::ptr::null_mut();
    }

    let mut full = Vec::with_capacity(lxmf_dest.len() + decrypted.len());
    full.extend_from_slice(&lxmf_dest);
    full.extend_from_slice(&decrypted);

    let msg = match LXMessage::unpack_from_bytes(&full, Some(LXMessage::PROPAGATED)) {
        Ok(m) => m,
        Err(e) => {
            rns::set_error(format!("LXMessage::unpack: {}", e));
            unsafe { *out_len = 0; }
            return std::ptr::null_mut();
        }
    };

    let source_hash = msg.source_hash.clone();
    if source_hash.len() != LXMessage::DESTINATION_LENGTH {
        rns::set_error("source_hash wrong length".into());
        unsafe { *out_len = 0; }
        return std::ptr::null_mut();
    }
    let timestamp_ms: u64 = (msg.timestamp.unwrap_or(0.0) * 1000.0) as u64;
    let sig_ok: u8 = if msg.signature_validated { 1 } else { 0 };
    let reason: u8 = match msg.unverified_reason {
        Some(LXMessage::SOURCE_UNKNOWN) => 1,
        Some(LXMessage::SIGNATURE_INVALID) => 2,
        Some(other) => other,
        None => 0,
    };
    let title = msg.title.clone();
    let content = msg.content.clone();
    if title.len() > u16::MAX as usize {
        rns::set_error("title too large".into());
        unsafe { *out_len = 0; }
        return std::ptr::null_mut();
    }
    if content.len() > u32::MAX as usize {
        rns::set_error("content too large".into());
        unsafe { *out_len = 0; }
        return std::ptr::null_mut();
    }

    let mut out = Vec::with_capacity(32 + title.len() + content.len());
    out.extend_from_slice(&source_hash);                           // [0..16]
    out.extend_from_slice(&timestamp_ms.to_be_bytes());            // [16..24]
    out.push(sig_ok);                                              // [24]
    out.push(reason);                                              // [25]
    out.extend_from_slice(&(title.len() as u16).to_be_bytes());    // [26..28]
    out.extend_from_slice(&(content.len() as u32).to_be_bytes());  // [28..32]
    out.extend_from_slice(&title);                                 // [32..32+t]
    out.extend_from_slice(&content);                               // [32+t..]

    let len = out.len() as u32;
    let mut boxed = out.into_boxed_slice();
    let ptr = boxed.as_mut_ptr();
    std::mem::forget(boxed);
    unsafe { *out_len = len; }
    ptr
}