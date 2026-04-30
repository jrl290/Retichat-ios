//! Tests for announce callback registration and delivery.
//!
//! Requires: rnsd reachable at RNS_HOST:RNS_PORT (default 192.168.2.107:4242).
//!
//! ## What is tested
//!
//! * `lxmf_client_announce` — our Rust client announces without error.
//! * `lxmf_client_watch` — registers a destination to watch (returns 0).
//! * Announce callback — a Python LXMF peer announces on the network; the Rust
//!   announce callback fires with that peer's exact dest hash within 30 s.
//!   (Using a Python subprocess guarantees real LXMF traffic, making this a
//!   hard assertion rather than a best-effort network check.)

mod helpers;

use std::time::Duration;

/// Verify the announce callback fires when a Python LXMF peer appears on the
/// network.
#[test]
fn test_announce_callback_fires_for_python_peer() {
    let _guard = helpers::TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
    helpers::test_banner("test_announce_callback_fires_for_python_peer");

    if !helpers::can_reach_rnsd(1500) {
        eprintln!(
            "  ⚠ skipping announce integration test: rnsd unreachable at {}:{}",
            helpers::rnsd_host(),
            helpers::rnsd_port()
        );
        return;
    }

    let s = "Start Rust LXMF client";
    helpers::step(s);
    let dir = tempfile::tempdir().expect("tempdir");
    helpers::write_rns_config(dir.path(), &helpers::rnsd_host(), helpers::rnsd_port());
    let _client_guard = helpers::ClientGuard::new(helpers::start_test_client(dir.path(), "AnnounceTest"));
    let client = _client_guard.handle();
    helpers::done(s);

    let s = "Register announce callback";
    helpers::step(s);
    let capture = helpers::new_capture::<helpers::AnnounceEvent>();
    let ctx_ptr = helpers::capture_ctx_ptr(&capture);
    let rc = retichat_ffi::lxmf_client_set_announce_callback(
        client,
        helpers::announce_trampoline,
        ctx_ptr,
    );
    assert_eq!(rc, 0, "set_announce_callback failed: {:?}", helpers::last_error_str());
    helpers::done(s);

    let s = "Announce Rust client and register dest watch";
    helpers::step(s);
    // Integration tests depend on hearing remote announces from the network.
    // Ensure global announce filtering is disabled for this process.
    retichat_ffi::retichat_set_drop_announces(0);
    let rc = retichat_ffi::lxmf_client_announce(client);
    assert_eq!(rc, 0, "lxmf_client_announce failed: {:?}", helpers::last_error_str());
    let our_dest = helpers::client_dest_hash(client);
    let rc = retichat_ffi::lxmf_client_watch(client, our_dest.as_ptr(), our_dest.len() as u32);
    assert_eq!(rc, 0, "lxmf_client_watch failed: {:?}", helpers::last_error_str());
    eprintln!("    rust dest: {}", hex::encode(&our_dest));
    helpers::done(s);

    let s = "Spawn Python LXMF announcer subprocess";
    helpers::step(s);
    let py_dir = tempfile::tempdir().expect("py config tempdir");
    helpers::write_rns_config(py_dir.path(), &helpers::rnsd_host(), helpers::rnsd_port());
    let (_py_proc, py_dest_hash) = helpers::spawn_python_announcer(py_dir.path());
    eprintln!("    python dest: {}", hex::encode(&py_dest_hash));
    // Also watch the exact Python destination so callback delivery still
    // works even if announce filtering is enabled elsewhere in process state.
    let rc = retichat_ffi::lxmf_client_watch(client, py_dest_hash.as_ptr(), py_dest_hash.len() as u32);
    assert_eq!(rc, 0, "lxmf_client_watch(py) failed: {:?}", helpers::last_error_str());
    helpers::done(s);

    let wait_label = format!(
        "Wait (≤30 s) for announce from Python peer ({})",
        hex::encode(&py_dest_hash)
    );
    helpers::step(&wait_label);
    let got = helpers::wait_until(
        &capture,
        Duration::from_secs(30),
        |events| events.iter().any(|e| e.dest_hash == py_dest_hash),
    );
    {
        let (lock, _) = &*capture;
        for ev in lock.lock().unwrap().iter() {
            eprintln!(
                "    received: dest={} name={:?}",
                hex::encode(&ev.dest_hash),
                ev.display_name
            );
        }
    }
    if got { helpers::done(&wait_label); }

    let s = "Shut down Rust client";
    helpers::step(s);
    helpers::shutdown_client(client);
    unsafe { helpers::release_ctx_ptr::<helpers::AnnounceEvent>(ctx_ptr); }
    helpers::done(s);

    assert!(
        got,
        "announce callback never fired for Python peer ({}) within 30 s",
        hex::encode(&py_dest_hash)
    );
}

