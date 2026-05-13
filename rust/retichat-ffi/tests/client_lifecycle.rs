//! Tests for the LXMF client lifecycle FFI: start, hash queries, shutdown.
//!
//! Requires: rnsd reachable at RNS_HOST:RNS_PORT (default 192.168.2.107:4242).
//!
//! ## Serialisation
//!
//! The Reticulum transport is a process-global singleton.  Every test that
//! touches the transport acquires `helpers::TEST_MUTEX` before starting a
//! client and holds it until after shutdown.  This ensures tests run
//! sequentially even when cargo uses multiple test threads.

mod helpers;

use tempfile::TempDir;

// Helper: create a temp dir and write the RNS config into it.
fn make_client_dir() -> TempDir {
    let dir = tempfile::tempdir().expect("tempdir creation failed");
    helpers::write_rns_config(dir.path(), &helpers::rnsd_host(), helpers::rnsd_port());
    dir
}

// ---------------------------------------------------------------------------
// Pre-start / invalid-handle tests (no transport required)
// ---------------------------------------------------------------------------

#[test]
fn test_shutdown_invalid_handle_returns_error() {
    let _guard = helpers::TEST_MUTEX
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    helpers::test_banner("test_shutdown_invalid_handle_returns_error");
    let s = "lxmf_client_shutdown(0) → expect -1";
    helpers::step(s);
    let rc = retichat_ffi::lxmf_client_shutdown(0);
    assert_eq!(rc, -1, "expected -1 for handle 0, got {rc}");
    let err = helpers::last_error_str();
    assert!(
        err.is_some(),
        "expected an error string for invalid handle shutdown"
    );
    eprintln!("    error: {:?}", err.as_deref().unwrap_or("none"));
    helpers::done(s);
}

#[test]
fn test_identity_handle_query_invalid_handle() {
    let _guard = helpers::TEST_MUTEX
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    helpers::test_banner("test_identity_handle_query_invalid_handle");
    let s = "lxmf_client_identity_handle(0) → expect 0";
    helpers::step(s);
    let h = retichat_ffi::lxmf_client_identity_handle(0);
    assert_eq!(h, 0, "expected 0 for invalid client handle, got {h}");
    helpers::last_error_str(); // consume error
    helpers::done(s);
}

// ---------------------------------------------------------------------------
// Live transport tests
// ---------------------------------------------------------------------------

#[test]
fn test_start_gives_nonzero_handle() {
    let _guard = helpers::TEST_MUTEX
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    helpers::test_banner("test_start_gives_nonzero_handle");
    let dir = make_client_dir();

    let s = "lxmf_client_start → expect non-zero handle";
    helpers::step(s);
    let client = helpers::start_test_client(dir.path(), "Lifecycle-Start");
    assert_ne!(client, 0, "client handle must be non-zero");
    helpers::done(s);

    let s = "lxmf_client_shutdown";
    helpers::step(s);
    helpers::shutdown_client(client);
    helpers::done(s);
}

#[test]
fn test_identity_hash_is_16_bytes_and_nonzero() {
    let _guard = helpers::TEST_MUTEX
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    helpers::test_banner("test_identity_hash_is_16_bytes_and_nonzero");
    let dir = make_client_dir();
    let client = helpers::start_test_client(dir.path(), "Lifecycle-IdHash");

    let s = "lxmf_client_identity_hash → expect 16 non-zero bytes";
    helpers::step(s);
    let hash = helpers::client_identity_hash(client);
    assert_eq!(hash.len(), 16, "identity hash must be 16 bytes");
    assert!(
        !hash.iter().all(|&b| b == 0),
        "identity hash must not be all zeros"
    );
    eprintln!("    identity hash: {}", hex::encode(&hash));
    helpers::done(s);

    let s = "lxmf_client_shutdown";
    helpers::step(s);
    helpers::shutdown_client(client);
    helpers::done(s);
}

#[test]
fn test_dest_hash_is_16_bytes_and_nonzero() {
    let _guard = helpers::TEST_MUTEX
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    helpers::test_banner("test_dest_hash_is_16_bytes_and_nonzero");
    let dir = make_client_dir();
    let client = helpers::start_test_client(dir.path(), "Lifecycle-DestHash");

    let s = "lxmf_client_dest_hash → expect 16 non-zero bytes";
    helpers::step(s);
    let hash = helpers::client_dest_hash(client);
    assert_eq!(hash.len(), 16, "dest hash must be 16 bytes");
    assert!(
        !hash.iter().all(|&b| b == 0),
        "dest hash must not be all zeros"
    );
    eprintln!("    dest hash: {}", hex::encode(&hash));
    helpers::done(s);

    let s = "lxmf_client_shutdown";
    helpers::step(s);
    helpers::shutdown_client(client);
    helpers::done(s);
}

#[test]
fn test_identity_handle_nonzero_after_start() {
    let _guard = helpers::TEST_MUTEX
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    helpers::test_banner("test_identity_handle_nonzero_after_start");
    let dir = make_client_dir();
    let client = helpers::start_test_client(dir.path(), "Lifecycle-IdHandle");

    let s = "lxmf_client_identity_handle → expect non-zero";
    helpers::step(s);
    let id_handle = retichat_ffi::lxmf_client_identity_handle(client);
    assert_ne!(id_handle, 0, "identity handle must be non-zero after start");
    helpers::done(s);

    let s = "lxmf_client_shutdown";
    helpers::step(s);
    helpers::shutdown_client(client);
    helpers::done(s);
}

#[test]
fn test_double_shutdown_second_returns_error() {
    let _guard = helpers::TEST_MUTEX
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    helpers::test_banner("test_double_shutdown_second_returns_error");
    let dir = make_client_dir();
    let client = helpers::start_test_client(dir.path(), "Lifecycle-DblShutdown");

    let s = "First shutdown (valid handle) → expect 0";
    helpers::step(s);
    helpers::shutdown_client(client);
    helpers::done(s);

    let s = "Second shutdown (stale handle) → expect -1";
    helpers::step(s);
    let rc = retichat_ffi::lxmf_client_shutdown(client);
    assert_eq!(rc, -1, "expected -1 on double shutdown, got {rc}");
    helpers::last_error_str(); // consume error
    helpers::done(s);
}

#[test]
fn test_identity_and_dest_hash_differ() {
    let _guard = helpers::TEST_MUTEX
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    helpers::test_banner("test_identity_and_dest_hash_differ");
    let dir = make_client_dir();
    let client = helpers::start_test_client(dir.path(), "Lifecycle-HashDiff");

    let s = "identity hash ≠ LXMF dest hash";
    helpers::step(s);
    let id_hash = helpers::client_identity_hash(client);
    let dest_hash = helpers::client_dest_hash(client);
    assert_ne!(
        id_hash, dest_hash,
        "identity hash and LXMF dest hash must differ"
    );
    eprintln!("    identity: {}", hex::encode(&id_hash));
    eprintln!("    dest:     {}", hex::encode(&dest_hash));
    helpers::done(s);

    let s = "lxmf_client_shutdown";
    helpers::step(s);
    helpers::shutdown_client(client);
    helpers::done(s);
}
