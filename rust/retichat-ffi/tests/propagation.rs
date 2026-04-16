//! End-to-end propagation tests: send → prop node → sync → receive.
//!
//! Requires: rnsd at RNS_HOST:RNS_PORT and a propagation node reachable at
//! PROP_NODE_HASH (defaults: 192.168.2.107:4242 / 90c650419e3a991a0bbe4cb3123724a4).
//!
//! ## Strategy
//!
//! The "other side" is a Python subprocess so the Rust transport singleton is
//! not duplicated.
//!
//! ### test_propagation_sync_complete_fires
//! Rust client calls `lxmf_client_sync`; assert the sync-complete callback
//! fires.  The prop node may have 0 messages for us — what matters is that
//! the callback fires within the timeout.
//!
//! ### test_propagation_receive_after_sync
//! Full round-trip:
//! 1. Rust client announces → Python prop-sender sends a propagated message
//!    to the Rust dest.
//! 2. Python sender waits for "SENT" (prop node accepted).
//! 3. Rust client calls sync.
//! 4. Rust delivery callback fires with the expected content.

mod helpers;

use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::time::Duration;

const TEST_CONTENT: &str = "prop-receive-e2e-test";

// ---------------------------------------------------------------------------
// test_propagation_sync_complete_fires
// ---------------------------------------------------------------------------

/// Sync from the propagation node and assert the sync-complete callback fires.
#[test]
fn test_propagation_sync_complete_fires() {
    helpers::test_banner("test_propagation_sync_complete_fires");
    let _guard = helpers::TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());

    let s = "Start Rust LXMF client";
    helpers::step(s);
    let dir = tempfile::tempdir().expect("tempdir");
    helpers::write_rns_config(dir.path(), &helpers::rnsd_host(), helpers::rnsd_port());
    let _client_guard = helpers::ClientGuard::new(helpers::start_test_client(dir.path(), "PropSyncComplete"));
    let client = _client_guard.handle();
    helpers::done(s);

    let s = "Register sync-complete callback";
    helpers::step(s);
    let sync_capture = helpers::new_capture::<helpers::SyncCompleteEvent>();
    let sync_ctx = helpers::capture_ctx_ptr(&sync_capture);
    let rc = retichat_ffi::lxmf_client_set_sync_complete_callback(
        client,
        helpers::sync_trampoline,
        sync_ctx,
    );
    assert_eq!(rc, 0, "set_sync_complete_callback failed: {:?}", helpers::last_error_str());
    helpers::done(s);

    let s = "Announce Rust client";
    helpers::step(s);
    let rc = retichat_ffi::lxmf_client_announce(client);
    assert_eq!(rc, 0, "lxmf_client_announce failed: {:?}", helpers::last_error_str());
    helpers::done(s);

    let prop_hash = helpers::prop_node_hash_bytes();
    let sync_label = format!("Request sync from prop node ({})", hex::encode(&prop_hash));
    helpers::step(&sync_label);
    let rc = retichat_ffi::lxmf_client_sync(
        client,
        prop_hash.as_ptr(),
        prop_hash.len() as u32,
    );
    assert_eq!(
        rc, 0,
        "lxmf_client_sync failed: {:?} — is prop node {} reachable?",
        helpers::last_error_str(),
        hex::encode(&prop_hash)
    );
    helpers::done(&sync_label);

    let stop = Arc::new(AtomicBool::new(false));
    let driver = helpers::process_outbound_driver(client, Arc::clone(&stop));

    let s = "Wait (\u{2264}45 s) for sync-complete callback";
    helpers::step(s);
    let sync_event = helpers::wait_for_one(&sync_capture, Duration::from_secs(45));
    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    driver.join().unwrap();
    if sync_event.is_some() { helpers::done(s); }

    let s = "Shut down Rust client";
    helpers::step(s);
    helpers::shutdown_client(client);
    unsafe { helpers::release_ctx_ptr::<helpers::SyncCompleteEvent>(sync_ctx); }
    helpers::done(s);

    let event = sync_event.expect(
        "sync-complete callback never fired within 45 s; \
         check that the prop node is reachable"
    );
    eprintln!("    sync-complete: {} message(s) received", event.count);
}

// ---------------------------------------------------------------------------
// test_propagation_receive_after_sync
// ---------------------------------------------------------------------------

/// Full end-to-end propagation round-trip using a Python sender.
///
/// Python subprocess sends a propagated message → Rust client syncs →
/// Rust delivery callback fires.
#[test]
fn test_propagation_receive_after_sync() {
    helpers::test_banner("test_propagation_receive_after_sync");
    let _guard = helpers::TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());

    let s = "Start Rust LXMF client and register delivery + sync callbacks";
    helpers::step(s);
    let dir = tempfile::tempdir().expect("tempdir");
    helpers::write_rns_config(dir.path(), &helpers::rnsd_host(), helpers::rnsd_port());
    let _client_guard = helpers::ClientGuard::new(helpers::start_test_client(dir.path(), "PropReceive"));
    let client = _client_guard.handle();

    let delivery_capture = helpers::new_capture::<helpers::DeliveredMsg>();
    let delivery_ctx = helpers::capture_ctx_ptr(&delivery_capture);
    let rc = retichat_ffi::lxmf_client_set_delivery_callback(
        client,
        helpers::delivery_trampoline,
        delivery_ctx,
    );
    assert_eq!(rc, 0, "set_delivery_callback failed: {:?}", helpers::last_error_str());

    let sync_capture = helpers::new_capture::<helpers::SyncCompleteEvent>();
    let sync_ctx = helpers::capture_ctx_ptr(&sync_capture);
    let rc = retichat_ffi::lxmf_client_set_sync_complete_callback(
        client,
        helpers::sync_trampoline,
        sync_ctx,
    );
    assert_eq!(rc, 0, "set_sync_complete_callback failed: {:?}", helpers::last_error_str());
    helpers::done(s);

    let s = "Announce Rust client";
    helpers::step(s);
    let rc = retichat_ffi::lxmf_client_announce(client);
    assert_eq!(rc, 0, "lxmf_client_announce failed: {:?}", helpers::last_error_str());
    let our_dest = helpers::client_dest_hash(client);
    eprintln!("    rust dest: {}", hex::encode(&our_dest));
    helpers::done(s);

    let stop = Arc::new(AtomicBool::new(false));
    let driver = helpers::process_outbound_driver(client, Arc::clone(&stop));

    // Verify the prop node is reachable before spawning Python (which also needs it).
    let prop_hash = helpers::prop_node_hash_bytes();
    let path_label = format!(
        "Wait \u{2264}30 s for path to prop node ({})",
        hex::encode(&prop_hash)
    );
    helpers::step(&path_label);
    retichat_ffi::retichat_transport_request_path(prop_hash.as_ptr(), prop_hash.len() as u32);
    let path_deadline = std::time::Instant::now() + Duration::from_secs(30);
    loop {
        if retichat_ffi::retichat_transport_has_path(prop_hash.as_ptr(), prop_hash.len() as u32) != 0 {
            break;
        }
        assert!(
            std::time::Instant::now() < path_deadline,
            "no path to prop node ({}) after 30 s — is rfed running?",
            hex::encode(&prop_hash)
        );
        std::thread::sleep(Duration::from_millis(300));
    }
    helpers::done(&path_label);

    let spawn_label = format!("Spawn Python propagation sender \u{2192} dest {}", hex::encode(&our_dest));
    helpers::step(&spawn_label);
    let py_dir = tempfile::tempdir().expect("py config tempdir");
    helpers::write_rns_config(py_dir.path(), &helpers::rnsd_host(), helpers::rnsd_port());
    let py_proc = helpers::spawn_python_prop_sender(py_dir.path(), &our_dest, TEST_CONTENT);
    helpers::done(&spawn_label);

    // Background re-announce loop: keep re-announcing every 3 s so Python
    // can pick up our identity regardless of connection timing.
    let announce_stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let announce_stop2 = Arc::clone(&announce_stop);
    let announce_thread = std::thread::spawn(move || {
        // Initial delay to let Python establish its TCP connection to rnsd.
        std::thread::sleep(Duration::from_secs(2));
        while !announce_stop2.load(std::sync::atomic::Ordering::Relaxed) {
            let _rc = retichat_ffi::lxmf_client_announce(client);
            for _ in 0..30 {
                if announce_stop2.load(std::sync::atomic::Ordering::Relaxed) {
                    return;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
        }
    });

    let s = "Wait (\u{2264}60 s) for Python sender to print SENT";
    helpers::step(s);
    let (py_exit, py_last) = helpers::wait_python(py_proc);
    // Stop the background re-announce thread now that Python is done.
    announce_stop.store(true, std::sync::atomic::Ordering::Relaxed);
    let _ = announce_thread.join();
    eprintln!("    python prop-sender exited {py_exit}: {py_last:?}");
    assert_eq!(py_exit, 0, "Python prop-sender failed (exit {py_exit}): {py_last}");
    helpers::done(s);

    let prop_hash = helpers::prop_node_hash_bytes();
    let sync_label = format!("Request sync from prop node ({})", hex::encode(&prop_hash));
    helpers::step(&sync_label);
    let rc = retichat_ffi::lxmf_client_sync(
        client,
        prop_hash.as_ptr(),
        prop_hash.len() as u32,
    );
    assert_eq!(rc, 0, "lxmf_client_sync failed: {:?}", helpers::last_error_str());
    helpers::done(&sync_label);

    let s = "Wait (\u{2264}60 s) for Rust delivery callback";
    helpers::step(s);
    let received = helpers::wait_for_one(&delivery_capture, Duration::from_secs(60));
    let synced = helpers::wait_for_one(&sync_capture, Duration::from_secs(5));
    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    driver.join().unwrap();
    if received.is_some() { helpers::done(s); }

    let s = "Shut down Rust client";
    helpers::step(s);
    helpers::shutdown_client(client);
    unsafe { helpers::release_ctx_ptr::<helpers::DeliveredMsg>(delivery_ctx); }
    unsafe { helpers::release_ctx_ptr::<helpers::SyncCompleteEvent>(sync_ctx); }
    helpers::done(s);

    if let Some(sync_ev) = synced {
        eprintln!("    sync-complete: {} message(s)", sync_ev.count);
    }

    let msg = received.expect(
        "delivery callback never fired within 60 s after sync; \
         check that the propagation node is online and accepting messages"
    );
    assert_eq!(msg.content, TEST_CONTENT, "delivered content mismatch: got {:?}", msg.content);
}

