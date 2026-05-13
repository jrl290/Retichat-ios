//! Tests for standalone identity FFI functions.
//!
//! These tests do NOT require a running Reticulum transport or rnsd connection.
//! They call the identity functions directly with invalid inputs and verify
//! correct error handling.

mod helpers;

use retichat_ffi::{retichat_identity_destroy, retichat_identity_public_key};

#[test]
fn test_destroy_invalid_handle() {
    helpers::test_banner("test_destroy_invalid_handle");
    let s = "retichat_identity_destroy(0) → expect -1";
    helpers::step(s);
    let rc = retichat_identity_destroy(0);
    assert_eq!(rc, -1, "expected -1 for handle 0, got {rc}");
    let err = helpers::last_error_str();
    assert!(
        err.is_some(),
        "expected an error string after invalid handle destroy"
    );
    eprintln!("    error: {:?}", err.as_deref().unwrap_or("none"));
    helpers::done(s);
}

#[test]
fn test_pubkey_invalid_handle() {
    helpers::test_banner("test_pubkey_invalid_handle");
    let s = "retichat_identity_public_key(0, buf, 64) → expect -1";
    helpers::step(s);
    let mut buf = vec![0u8; 64];
    let rc = retichat_identity_public_key(0, buf.as_mut_ptr(), 64);
    assert_eq!(rc, -1, "expected -1 for handle 0, got {rc}");
    let err = helpers::last_error_str();
    assert!(
        err.is_some(),
        "expected an error string after invalid handle pubkey query"
    );
    eprintln!("    error: {:?}", err.as_deref().unwrap_or("none"));
    helpers::done(s);
}

#[test]
fn test_pubkey_null_buf_returns_error() {
    helpers::test_banner("test_pubkey_null_buf_returns_error");
    let s = "retichat_identity_public_key(0, null, 64) → invalid-handle fires first, expect -1";
    helpers::step(s);
    let rc = retichat_identity_public_key(0, std::ptr::null_mut(), 64);
    assert_eq!(rc, -1);
    helpers::last_error_str(); // consume pending error
    helpers::done(s);
}

#[test]
fn test_destroy_returns_minus_one_on_second_call() {
    helpers::test_banner("test_destroy_returns_minus_one_on_second_call");
    let s = "retichat_identity_destroy(0) twice → both return -1";
    helpers::step(s);
    // Handle 0 is always invalid; two consecutive calls both return -1.
    let rc1 = retichat_identity_destroy(0);
    helpers::last_error_str();
    let rc2 = retichat_identity_destroy(0);
    helpers::last_error_str();
    assert_eq!(rc1, -1);
    assert_eq!(rc2, -1);
    helpers::done(s);
}
