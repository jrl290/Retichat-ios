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
