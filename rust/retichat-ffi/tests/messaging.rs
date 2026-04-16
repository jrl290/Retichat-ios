//! Tests for LXMF message send and receive, and message state callbacks.
//!
//! Requires: rnsd at RNS_HOST:RNS_PORT (default 192.168.2.107:4242).
//!
//! ## Strategy
//!
//! Because the Reticulum transport is a process-global singleton, only one
//! Rust LXMF client can run per process.  The "other side" of each message
//! exchange is a Python subprocess that runs its own RNS instance.
//!
//! ### test_rust_sends_to_python_receiver
//! 1. Start a Python LXMF receiver subprocess.
//! 2. Read its dest hash from stdout ("READY:<hex>").
//! 3. Rust client sends a direct LXMF message to that hash.
//! 4. Assert the Python subprocess exits 0 (printed "RECEIVED:…").
//!
//! ### test_python_sender_delivers_to_rust
//! 1. Start the Rust LXMF client; register a delivery callback.
//! 2. Announce the Rust client so the Python sender can resolve its path.
//! 3. Spawn a Python LXMF sender subprocess targeting the Rust dest hash.
//! 4. Assert the Rust delivery callback fires with the expected content.

mod helpers;

use std::ffi::CString;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::time::Duration;

const TEST_CONTENT: &str = "retichat-ffi-messaging-test";

// ---------------------------------------------------------------------------
// test_rust_sends_to_python_receiver
// ---------------------------------------------------------------------------

/// Rust FFI client sends a direct LXMF message; a Python subprocess receives it.
#[test]
fn test_rust_sends_to_python_receiver() {
    helpers::test_banner("test_rust_sends_to_python_receiver");
    let _guard = helpers::TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());

    let s = "Start Rust LXMF client";
    helpers::step(s);
    let rust_dir = tempfile::tempdir().expect("rust config tempdir");
    helpers::write_rns_config(rust_dir.path(), &helpers::rnsd_host(), helpers::rnsd_port());
    let _client_guard = helpers::ClientGuard::new(helpers::start_test_client(rust_dir.path(), "MsgSendTest"));
    let client = _client_guard.handle();
    helpers::done(s);

    let s = "Register message-state callback";
    helpers::step(s);
    let state_capture = helpers::new_capture::<helpers::StateEvent>();
    let state_ctx = helpers::capture_ctx_ptr(&state_capture);
    let rc = retichat_ffi::lxmf_client_set_message_state_callback(
        client,
        helpers::state_trampoline,
        state_ctx,
    );
    assert_eq!(rc, 0, "set_message_state_callback failed: {:?}", helpers::last_error_str());
    helpers::done(s);

    let s = "Announce Rust client";
    helpers::step(s);
    retichat_ffi::lxmf_client_announce(client);
    helpers::done(s);

    let s = "Spawn Python LXMF receiver subprocess";
    helpers::step(s);
    let py_dir = tempfile::tempdir().expect("py config tempdir");
    helpers::write_rns_config(py_dir.path(), &helpers::rnsd_host(), helpers::rnsd_port());
    let (py_proc, py_dest_hash) = helpers::spawn_python_receiver(py_dir.path());
    eprintln!("    python receiver dest: {}", hex::encode(&py_dest_hash));
    helpers::done(s);

    let send_label = format!(
        "Send direct LXMF message to Python receiver ({})",
        hex::encode(&py_dest_hash)
    );
    helpers::step(&send_label);

    let content_c = CString::new(TEST_CONTENT).unwrap();
    let msg = retichat_ffi::lxmf_message_new(
        client,
        py_dest_hash.as_ptr(),
        py_dest_hash.len() as u32,
        content_c.as_ptr(),
        std::ptr::null(), // no title
        2,                // direct
    );
    assert_ne!(msg, 0, "lxmf_message_new failed: {:?}", helpers::last_error_str());

    let rc = retichat_ffi::lxmf_message_send(client, msg);
    assert_eq!(rc, 0, "lxmf_message_send failed: {:?}", helpers::last_error_str());
    helpers::done(&send_label);

    let stop = Arc::new(AtomicBool::new(false));
    let driver = helpers::process_outbound_driver(client, Arc::clone(&stop));

    let s = "Wait (\u{2264}60 s) for Python receiver to confirm receipt";
    helpers::step(s);
    let (exit_code, last_line) = helpers::wait_python(py_proc);

    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    driver.join().unwrap();

    {
        let (lock, _) = &*state_capture;
        for ev in lock.lock().unwrap().iter() {
            eprintln!("    state: 0x{:02X} for msg={}", ev.state, hex::encode(&ev.msg_hash));
        }
    }

    retichat_ffi::lxmf_message_destroy(msg);
    if exit_code == 0 && last_line.starts_with("RECEIVED:") { helpers::done(s); }

    let s = "Shut down Rust client";
    helpers::step(s);
    helpers::shutdown_client(client);
    unsafe { helpers::release_ctx_ptr::<helpers::StateEvent>(state_ctx); }
    helpers::done(s);

    assert_eq!(exit_code, 0, "Python receiver exited with {exit_code}; last line: {last_line:?}");
    assert!(
        last_line.starts_with("RECEIVED:"),
        "expected Python receiver to print 'RECEIVED:\u{2026}', got: {last_line:?}"
    );
}

// ---------------------------------------------------------------------------
// test_python_sender_delivers_to_rust
// ---------------------------------------------------------------------------

/// A Python LXMF sender sends a direct message; the Rust FFI delivery callback
/// fires.
#[test]
fn test_python_sender_delivers_to_rust() {
    helpers::test_banner("test_python_sender_delivers_to_rust");
    let _guard = helpers::TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());

    let s = "Start Rust LXMF client and register delivery callback";
    helpers::step(s);
    let rust_dir = tempfile::tempdir().expect("rust config tempdir");
    helpers::write_rns_config(rust_dir.path(), &helpers::rnsd_host(), helpers::rnsd_port());
    let _client_guard = helpers::ClientGuard::new(helpers::start_test_client(rust_dir.path(), "MsgRecvTest"));
    let client = _client_guard.handle();
    let delivery_capture = helpers::new_capture::<helpers::DeliveredMsg>();
    let delivery_ctx = helpers::capture_ctx_ptr(&delivery_capture);
    let rc = retichat_ffi::lxmf_client_set_delivery_callback(
        client,
        helpers::delivery_trampoline,
        delivery_ctx,
    );
    assert_eq!(rc, 0, "set_delivery_callback failed: {:?}", helpers::last_error_str());
    helpers::done(s);

    let s = "Announce Rust client";
    helpers::step(s);
    retichat_ffi::lxmf_client_announce(client);
    let our_dest = helpers::client_dest_hash(client);
    eprintln!("    rust dest: {}", hex::encode(&our_dest));
    std::thread::sleep(Duration::from_secs(3)); // let announce propagate through rnsd
    helpers::done(s);

    let spawn_label = format!(
        "Spawn Python LXMF sender targeting Rust dest ({})",
        hex::encode(&our_dest)
    );
    helpers::step(&spawn_label);
    let py_dir = tempfile::tempdir().expect("py config tempdir");
    helpers::write_rns_config(py_dir.path(), &helpers::rnsd_host(), helpers::rnsd_port());
    let py_proc = helpers::spawn_python_sender(py_dir.path(), &our_dest, TEST_CONTENT, "direct");
    helpers::done(&spawn_label);

    // Give Python time to establish its TCP connection to rnsd BEFORE re-announcing.
    // If we re-announce before Python is connected, rnsd relays it to nobody and
    // Python must rely on PATH_REQUEST, which can fail for non-transport nodes.
    std::thread::sleep(Duration::from_secs(2));

    // Re-announce so the now-connected Python sender sees a fresh announce
    // from rnsd, giving it the path to our dest without needing a PATH_REQUEST
    // round-trip (which can fail if the original announce has aged out).
    let s = "Re-announce Rust client";
    helpers::step(s);
    retichat_ffi::lxmf_client_announce(client);
    helpers::done(s);

    let s = "Wait (\u{2264}60 s) for Rust delivery callback";
    helpers::step(s);
    let received = helpers::wait_for_one(&delivery_capture, Duration::from_secs(60));
    let (py_exit, py_last) = helpers::wait_python(py_proc);
    eprintln!("    python sender exited {py_exit}: {py_last:?}");
    if received.is_some() { helpers::done(s); }

    let s = "Shut down Rust client";
    helpers::step(s);
    helpers::shutdown_client(client);
    unsafe { helpers::release_ctx_ptr::<helpers::DeliveredMsg>(delivery_ctx); }
    helpers::done(s);

    let msg = received.expect(
        "Rust delivery callback never fired within 60 s; \
         check that rnsd is reachable and the Python sender succeeded"
    );
    assert_eq!(
        msg.content, TEST_CONTENT,
        "delivered content mismatch: expected {:?} got {:?}",
        TEST_CONTENT, msg.content
    );
}

