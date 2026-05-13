//! Tests for the one-shot blocking link-request FFI.
//!
//! Requires: rnsd at RNS_HOST:RNS_PORT and rfed.node reachable at
//! RFED_NODE_HASH (defaults: 192.168.2.107:4242 / 8c7ca26f7b4f640cc05a9f55494b3392).
//!
//! ## What is tested
//!
//! `retichat_link_request` opens an RNS Link to a remote destination,
//! identifies, sends a request payload, waits for the response, then tears the
//! link down — all blocking, in one call.  This exercises the full link
//! establishment protocol at the RNS layer.
//!
//! The test makes a request to the rfed.node destination (which handles the
//! "rfed.node" app/aspect pair) and asserts:
//!   * non-null response pointer
//!   * non-zero response length
//!   * the response pointer can be freed without memory errors
//!
//! Ignored by default: this is a live-infrastructure probe and depends on the
//! configured RFED_NODE_HASH being online and answering path/link requests.

mod helpers;

use std::ffi::CString;
use std::time::Duration;
/// Open a link to rfed.node, send an empty request on the "/" path,
/// receive a response, and free the buffer.
#[test]
#[ignore = "requires a live rfed.node responder configured by RFED_NODE_HASH"]
fn test_link_request_to_rfed_node() {
    helpers::test_banner("test_link_request_to_rfed_node");
    let _guard = helpers::TEST_MUTEX
        .lock()
        .unwrap_or_else(|e| e.into_inner());

    let s = "Start Rust LXMF client";
    helpers::step(s);
    let dir = tempfile::tempdir().expect("tempdir");
    helpers::write_rns_config(dir.path(), &helpers::rnsd_host(), helpers::rnsd_port());
    let _client_guard =
        helpers::ClientGuard::new(helpers::start_test_client(dir.path(), "LinkReqTest"));
    let client = _client_guard.handle();
    let identity_handle = retichat_ffi::lxmf_client_identity_handle(client);
    assert_ne!(identity_handle, 0);
    helpers::done(s);

    let rfed_hash = helpers::rfed_node_hash_bytes();

    let path_label = format!(
        "Request path to rfed.node ({}) and wait \u{2264}15 s",
        hex::encode(&rfed_hash)
    );
    helpers::step(&path_label);
    retichat_ffi::retichat_transport_request_path(rfed_hash.as_ptr(), rfed_hash.len() as u32);
    let path_deadline = std::time::Instant::now() + Duration::from_secs(15);
    loop {
        if retichat_ffi::retichat_transport_has_path(rfed_hash.as_ptr(), rfed_hash.len() as u32)
            != 0
        {
            break;
        }
        assert!(
            std::time::Instant::now() < path_deadline,
            "no path to rfed.node ({}) after 15 s — is it online?",
            hex::encode(&rfed_hash)
        );
        std::thread::sleep(Duration::from_millis(300));
    }
    helpers::done(&path_label);

    let req_label = format!(
        "retichat_link_request \u{2192} rfed.node ({}) path=\"/rfed/capabilities\" timeout=15s",
        hex::encode(&rfed_hash)
    );
    helpers::step(&req_label);

    let app_c = CString::new("rfed").unwrap();
    let aspects_c = CString::new("node").unwrap();
    let path_c = CString::new("/rfed/capabilities").unwrap();

    let mut out_len: u32 = 0;
    let response_ptr = retichat_ffi::retichat_link_request(
        rfed_hash.as_ptr(),
        rfed_hash.len() as u32,
        app_c.as_ptr(),
        aspects_c.as_ptr(),
        identity_handle,
        path_c.as_ptr(),
        std::ptr::null(), // no payload
        0,
        15.0, // 15 s timeout
        &mut out_len,
    );

    if response_ptr.is_null() {
        let err = helpers::last_error_str().unwrap_or_else(|| "<no error>".to_string());
        helpers::shutdown_client(client);
        panic!(
            "retichat_link_request returned NULL — err={err}\n\
             Check that rfed.node is reachable (RFED_NODE_HASH={})",
            hex::encode(rfed_hash)
        );
    }
    helpers::done(&req_label);

    let s = format!("Assert response non-empty ({out_len} bytes) and free buffer");
    helpers::step(&s);
    assert!(
        out_len > 0,
        "expected non-empty response from rfed.node, got {out_len} bytes"
    );
    retichat_ffi::lxmf_free_bytes(response_ptr, out_len);
    helpers::done(&s);

    let s = "Shut down Rust client";
    helpers::step(s);
    helpers::shutdown_client(client);
    helpers::done(s);
}
