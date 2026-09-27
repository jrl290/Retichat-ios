//! The delivery ratchets' mirror and freeze through the C API the app and its
//! Notification Service Extension use (Reticulum-rust PARITY-AUDIT-1.5.2.md
//! A29).
//!
//! No network: every client here runs with a config that has no interfaces.
//! The transport is a process singleton, so each test holds `TEST_MUTEX`.

mod helpers;

use std::ffi::CString;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use lxmf_rust::client::LxmfClient;
use reticulum_rust::destination::Destination;

/// A Reticulum config with no interfaces: nothing leaves this process.
fn write_offline_config(dir: &Path) {
    std::fs::write(
        dir.join("config"),
        "[reticulum]\nenable_transport = no\nshare_instance = no\n\n[interfaces]\n",
    )
    .expect("write config");
}

fn start(dir: &Path, mirror_dir: Option<&Path>, frozen: bool) -> helpers::ClientGuard {
    write_offline_config(dir);
    let dir_c = CString::new(dir.to_str().unwrap()).unwrap();
    let storage_c = CString::new(dir.join("lxmf_storage").to_str().unwrap()).unwrap();
    let identity_c = CString::new(dir.join("identity").to_str().unwrap()).unwrap();
    let name_c = CString::new("").unwrap();
    let mirror_c = mirror_dir.map(|m| CString::new(m.to_str().unwrap()).unwrap());
    let handle = retichat_ffi::lxmf_client_start_with_ratchets(
        dir_c.as_ptr(),
        storage_c.as_ptr(),
        identity_c.as_ptr(),
        1,
        name_c.as_ptr(),
        0,
        -1,
        mirror_c.as_ref().map_or(std::ptr::null(), |m| m.as_ptr()),
        if frozen { 1 } else { 0 },
    );
    if handle == 0 {
        panic!("lxmf_client_start_with_ratchets failed: {:?}", helpers::last_error_str());
    }
    helpers::ClientGuard::new(handle)
}

fn primary_file(dir: &Path, dest_hash: &[u8]) -> PathBuf {
    dir.join("lxmf_storage/lxmf/ratchets").join(format!("{}.ratchets", hex::encode(dest_hash)))
}

/// The client's handle copy of the delivery destination (`dest_handle`).
fn handle_copy(client: u64) -> Destination {
    let arc: Arc<Mutex<LxmfClient>> = reticulum_rust::ffi::get_handle(client).expect("client handle");
    let dest_handle = arc.lock().unwrap().dest_handle;
    reticulum_rust::ffi::get_handle::<Destination>(dest_handle).expect("delivery destination handle")
}

#[test]
fn the_app_start_mirrors_the_ratchet_file_from_the_first_write_and_every_rotation() {
    let _guard = helpers::TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
    let app = tempfile::tempdir().unwrap();
    let nse_ratchets = tempfile::tempdir().unwrap();
    let client = start(app.path(), Some(nse_ratchets.path()), false);
    let hash = helpers::client_dest_hash(client.handle());
    let primary = primary_file(app.path(), &hash);
    let mirror = nse_ratchets.path().join(format!("{}.ratchets", hex::encode(&hash)));

    assert_eq!(
        std::fs::read(&mirror).expect("the ratchet file created at start is mirrored"),
        std::fs::read(&primary).expect("primary ratchet file"),
    );
    assert_eq!(handle_copy(client.handle()).ratchets_mirror_path.as_deref(), mirror.to_str());

    // The first announce of the run rotates (no interface to send on; the
    // rotation happens while the announce is built).
    let _ = retichat_ffi::lxmf_client_announce(client.handle());
    let before = std::fs::read(&mirror).unwrap();
    assert_eq!(before, std::fs::read(&primary).unwrap(), "the rotation reached the mirror");
    let mut reader = Destination::new_inbound(
        handle_copy(client.handle()).identity.clone(),
        reticulum_rust::destination::DestinationType::Single,
        "lxmf".to_string(),
        vec!["delivery".to_string()],
    )
    .unwrap();
    reader.set_ratchets_frozen(true);
    reader.enable_ratchets(mirror.to_str().unwrap().to_string()).unwrap();
    assert_eq!(reader.ratchets.as_ref().map(|r| r.len()), Some(1), "the NSE's file holds the ratchet just announced");

    // Stopping the mirror at runtime reaches every copy.
    let none: *const std::os::raw::c_char = std::ptr::null();
    assert_eq!(retichat_ffi::lxmf_client_set_ratchets_mirror_dir(client.handle(), none), 0);
    assert_eq!(handle_copy(client.handle()).ratchets_mirror_path, None);
    assert_eq!(reticulum_rust::transport::Transport::registered_ratchet_settings(&hash), Some((None, false)));
}

#[test]
fn the_nse_start_is_frozen_before_the_ratchets_load_and_never_writes() {
    let _guard = helpers::TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
    let nse = tempfile::tempdir().unwrap();
    let client = start(nse.path(), None, true);
    let hash = helpers::client_dest_hash(client.handle());
    let primary = primary_file(nse.path(), &hash);

    assert!(!primary.exists(), "frozen at start: the NSE does not create the ratchet file");
    assert!(handle_copy(client.handle()).ratchets_frozen, "the client's handle copy is frozen");
    assert_eq!(reticulum_rust::transport::Transport::registered_ratchet_settings(&hash), Some((None, true)));
    let _ = retichat_ffi::lxmf_client_announce(client.handle());
    assert!(!primary.exists(), "an announce by a frozen client writes no ratchet file");

    // Unfreezing at runtime reaches every copy.
    assert_eq!(retichat_ffi::lxmf_client_set_ratchets_frozen(client.handle(), 0), 0);
    assert!(!handle_copy(client.handle()).ratchets_frozen);
    assert_eq!(reticulum_rust::transport::Transport::registered_ratchet_settings(&hash), Some((None, false)));
    assert_eq!(retichat_ffi::lxmf_client_set_ratchets_frozen(client.handle(), 1), 0);
    assert!(handle_copy(client.handle()).ratchets_frozen);
}
