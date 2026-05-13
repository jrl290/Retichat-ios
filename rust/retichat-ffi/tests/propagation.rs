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
//! ### test_propagation_sync_tracks_async_state
//! Rust client calls `lxmf_client_sync`; assert the router leaves IDLE and
//! starts the AppLinks-owned propagation path/link flow. An empty propagation
//! node is not required to fire sync-complete; completion belongs to an actual
//! message-list/get exchange.
//!
//! ### test_propagation_receive_after_sync
//! Full round-trip:
//! 1. Rust client announces → Python prop-sender sends a propagated message
//!    to the Rust dest.
//! 2. Python sender waits for "SENT" (prop node accepted).
//! 3. Rust client calls sync.
//! 4. Rust delivery callback fires with the expected content.
//! This is ignored by default because it depends on live propagation-node
//! stamp policy and may spend longer than the test budget generating PoW on
//! macOS. Run it explicitly with `cargo test --test propagation -- --ignored`.

mod helpers;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

const TEST_CONTENT: &str = "prop-receive-e2e-test";

const PR_IDLE: i32 = 0x00;
const PR_NO_PATH: i32 = 0xf0;
const PR_LINK_FAILED: i32 = 0xf1;
const PR_TRANSFER_FAILED: i32 = 0xf2;
const PR_NO_IDENTITY_RCVD: i32 = 0xf3;
const PR_NO_ACCESS: i32 = 0xf4;
const PR_FAILED: i32 = 0xfe;

fn propagation_state(client: u64) -> i32 {
    retichat_ffi::lxmf_client_propagation_state(client)
}

fn is_terminal_failure(state: i32) -> bool {
    matches!(
        state,
        PR_NO_PATH
            | PR_LINK_FAILED
            | PR_TRANSFER_FAILED
            | PR_NO_IDENTITY_RCVD
            | PR_NO_ACCESS
            | PR_FAILED
    )
}

fn wait_for_non_idle_propagation_state(client: u64, budget: Duration) -> i32 {
    let deadline = Instant::now() + budget;
    loop {
        let state = propagation_state(client);
        if state != PR_IDLE {
            return state;
        }
        assert!(
            Instant::now() < deadline,
            "propagation state stayed IDLE after sync request"
        );
        std::thread::yield_now();
    }
}

// ---------------------------------------------------------------------------
// test_propagation_sync_tracks_async_state
// ---------------------------------------------------------------------------

/// Sync from the propagation node and assert the async AppLinks flow starts.
#[test]
fn test_propagation_sync_tracks_async_state() {
    helpers::test_banner("test_propagation_sync_tracks_async_state");
    let _guard = helpers::TEST_MUTEX
        .lock()
        .unwrap_or_else(|e| e.into_inner());

    if !helpers::can_reach_rnsd(1500) {
        eprintln!(
            "  skipping propagation integration test: rnsd unreachable at {}:{}",
            helpers::rnsd_host(),
            helpers::rnsd_port()
        );
        return;
    }

    let s = "Start Rust LXMF client";
    helpers::step(s);
    let dir = tempfile::tempdir().expect("tempdir");
    helpers::write_rns_config(dir.path(), &helpers::rnsd_host(), helpers::rnsd_port());
    let _client_guard =
        helpers::ClientGuard::new(helpers::start_test_client(dir.path(), "PropSyncComplete"));
    let client = _client_guard.handle();
    helpers::done(s);

    let s = "Announce Rust client";
    helpers::step(s);
    let rc = retichat_ffi::lxmf_client_announce(client);
    assert_eq!(
        rc,
        0,
        "lxmf_client_announce failed: {:?}",
        helpers::last_error_str()
    );
    helpers::done(s);

    let prop_hash = helpers::prop_node_hash_bytes();
    let sync_label = format!("Request sync from prop node ({})", hex::encode(&prop_hash));
    helpers::step(&sync_label);
    let rc = retichat_ffi::lxmf_client_sync(client, prop_hash.as_ptr(), prop_hash.len() as u32);
    assert_eq!(
        rc,
        0,
        "lxmf_client_sync failed: {:?} — is prop node {} reachable?",
        helpers::last_error_str(),
        hex::encode(&prop_hash)
    );
    helpers::done(&sync_label);

    let s = "Wait for propagation state to leave IDLE";
    helpers::step(s);
    let state = wait_for_non_idle_propagation_state(client, Duration::from_secs(5));
    assert!(
        !is_terminal_failure(state),
        "propagation sync entered terminal failure state 0x{state:02x}; check live prop node {}",
        hex::encode(&prop_hash)
    );
    eprintln!("    propagation state: 0x{state:02x}");
    helpers::done(s);

    let s = "Shut down Rust client";
    helpers::step(s);
    helpers::shutdown_client(client);
    helpers::done(s);
}

// ---------------------------------------------------------------------------
// test_propagation_receive_after_sync
// ---------------------------------------------------------------------------

/// Full end-to-end propagation round-trip using a Python sender.
///
/// Python subprocess sends a propagated message → Rust client syncs →
/// Rust delivery callback fires.
#[test]
#[ignore = "requires live propagation node acceptance and propagation-stamp generation"]
fn test_propagation_receive_after_sync() {
    helpers::test_banner("test_propagation_receive_after_sync");
    let _guard = helpers::TEST_MUTEX
        .lock()
        .unwrap_or_else(|e| e.into_inner());

    if !helpers::can_reach_rnsd(1500) {
        eprintln!(
            "  skipping propagation integration test: rnsd unreachable at {}:{}",
            helpers::rnsd_host(),
            helpers::rnsd_port()
        );
        return;
    }

    let s = "Start Rust LXMF client and register delivery + sync callbacks";
    helpers::step(s);
    let dir = tempfile::tempdir().expect("tempdir");
    helpers::write_rns_config(dir.path(), &helpers::rnsd_host(), helpers::rnsd_port());
    let _client_guard =
        helpers::ClientGuard::new(helpers::start_test_client(dir.path(), "PropReceive"));
    let client = _client_guard.handle();

    let delivery_capture = helpers::new_capture::<helpers::DeliveredMsg>();
    let delivery_ctx = helpers::capture_ctx_ptr(&delivery_capture);
    let rc = retichat_ffi::lxmf_client_set_delivery_callback(
        client,
        helpers::delivery_trampoline,
        delivery_ctx,
    );
    assert_eq!(
        rc,
        0,
        "set_delivery_callback failed: {:?}",
        helpers::last_error_str()
    );

    let sync_capture = helpers::new_capture::<helpers::SyncCompleteEvent>();
    let sync_ctx = helpers::capture_ctx_ptr(&sync_capture);
    let rc = retichat_ffi::lxmf_client_set_sync_complete_callback(
        client,
        helpers::sync_trampoline,
        sync_ctx,
    );
    assert_eq!(
        rc,
        0,
        "set_sync_complete_callback failed: {:?}",
        helpers::last_error_str()
    );
    helpers::done(s);

    let s = "Announce Rust client";
    helpers::step(s);
    let rc = retichat_ffi::lxmf_client_announce(client);
    assert_eq!(
        rc,
        0,
        "lxmf_client_announce failed: {:?}",
        helpers::last_error_str()
    );
    let our_dest = helpers::client_dest_hash(client);
    eprintln!("    rust dest: {}", hex::encode(&our_dest));
    helpers::done(s);

    let stop = Arc::new(AtomicBool::new(false));
    let driver = helpers::process_outbound_driver(client, Arc::clone(&stop));

    let prop_hash = helpers::prop_node_hash_bytes();
    let sync_label = format!(
        "Start AppLinks propagation sync ({})",
        hex::encode(&prop_hash)
    );
    helpers::step(&sync_label);
    let rc = retichat_ffi::lxmf_client_sync(client, prop_hash.as_ptr(), prop_hash.len() as u32);
    assert_eq!(
        rc,
        0,
        "lxmf_client_sync failed: {:?}",
        helpers::last_error_str()
    );
    let sync_state = wait_for_non_idle_propagation_state(client, Duration::from_secs(5));
    assert!(
        !is_terminal_failure(sync_state),
        "propagation sync entered terminal failure state 0x{sync_state:02x}; check live prop node {}",
        hex::encode(&prop_hash)
    );
    eprintln!("    propagation state: 0x{sync_state:02x}");
    helpers::done(&sync_label);

    let spawn_label = format!(
        "Spawn Python propagation sender \u{2192} dest {}",
        hex::encode(&our_dest)
    );
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
    assert_eq!(
        py_exit, 0,
        "Python prop-sender failed (exit {py_exit}): {py_last}"
    );
    helpers::done(s);

    let sync_label = format!(
        "Request message sync from prop node ({})",
        hex::encode(&prop_hash)
    );
    helpers::step(&sync_label);
    let rc = retichat_ffi::lxmf_client_sync(client, prop_hash.as_ptr(), prop_hash.len() as u32);
    assert_eq!(
        rc,
        0,
        "lxmf_client_sync failed: {:?}",
        helpers::last_error_str()
    );
    helpers::done(&sync_label);

    let s = "Wait (\u{2264}60 s) for Rust delivery callback";
    helpers::step(s);
    let received = helpers::wait_for_one(&delivery_capture, Duration::from_secs(60));
    let synced = helpers::wait_for_one(&sync_capture, Duration::from_secs(5));
    stop.store(true, Ordering::Relaxed);
    driver.join().unwrap();
    if received.is_some() {
        helpers::done(s);
    }

    let s = "Shut down Rust client";
    helpers::step(s);
    helpers::shutdown_client(client);
    unsafe {
        helpers::release_ctx_ptr::<helpers::DeliveredMsg>(delivery_ctx);
    }
    unsafe {
        helpers::release_ctx_ptr::<helpers::SyncCompleteEvent>(sync_ctx);
    }
    helpers::done(s);

    if let Some(sync_ev) = synced {
        eprintln!("    sync-complete: {} message(s)", sync_ev.count);
    }

    let msg = received.expect(
        "delivery callback never fired within 60 s after sync; \
         check that the propagation node is online and accepting messages",
    );
    assert_eq!(
        msg.content, TEST_CONTENT,
        "delivered content mismatch: got {:?}",
        msg.content
    );
}
