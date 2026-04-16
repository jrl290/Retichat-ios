//! Shared helpers for all retichat-ffi integration tests.
//!
//! ## Transport singleton constraint
//!
//! The Reticulum transport is a process-global singleton.  Only one instance
//! can be live at a time.  All tests that touch the transport MUST acquire
//! `TEST_MUTEX` at the top of the test function *before* calling
//! `start_test_client` or any FFI function that touches the transport.
//! `shutdown_client` (and the transport teardown it triggers) allows later
//! tests to call `start_test_client` again.

// Each test binary only uses a subset of helpers; suppress unused-item warnings.
#![allow(dead_code)]

use std::ffi::{CStr, CString};
use std::io::{BufRead, BufReader};
use std::os::raw::{c_char, c_void};
use std::path::Path;
use std::process::{Child, ChildStdout, Command, Stdio};
use std::sync::{Arc, Condvar, Mutex};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

// ---------------------------------------------------------------------------
// Step-print helper
//
// Prints a clearly delimited step banner to stderr so test progress is
// immediately visible when running with --nocapture.
// ---------------------------------------------------------------------------

/// Print a test name banner.  Call once at the very start of each test function.
pub fn test_banner(name: &str) {
    let line = "─".repeat(60);
    eprintln!("\n{line}");
    eprintln!("  TEST  {name}");
    eprintln!("{line}");
}

/// Announce a step is about to begin.
pub fn step(label: &str) {
    eprintln!("  → {label}...");
}

/// Mark a step as complete.
pub fn done(label: &str) {
    eprintln!("  ✓ {label}");
}

// ---------------------------------------------------------------------------
// Environment helpers
// ---------------------------------------------------------------------------

pub fn rnsd_host() -> String {
    std::env::var("RNS_HOST").unwrap_or_else(|_| "192.168.2.107".to_string())
}

pub fn rnsd_port() -> u16 {
    std::env::var("RNS_PORT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(4242)
}

/// 16-byte propagation node destination hash.
/// Override with `PROP_NODE_HASH` env var (hex, 32 chars).
pub fn prop_node_hash_bytes() -> Vec<u8> {
    let hex_str = std::env::var("PROP_NODE_HASH")
        .unwrap_or_else(|_| "90c650419e3a991a0bbe4cb3123724a4".to_string());
    hex::decode(&hex_str).expect("PROP_NODE_HASH must be a 32-char hex string")
}

/// 16-byte rfed.node destination hash.
/// Override with `RFED_NODE_HASH` env var (hex, 32 chars).
pub fn rfed_node_hash_bytes() -> Vec<u8> {
    let hex_str = std::env::var("RFED_NODE_HASH")
        .unwrap_or_else(|_| "8c7ca26f7b4f640cc05a9f55494b3392".to_string());
    hex::decode(&hex_str).expect("RFED_NODE_HASH must be a 32-char hex string")
}

// ---------------------------------------------------------------------------
// RNS config writer
// ---------------------------------------------------------------------------

/// Write a minimal Reticulum `config` file inside `dir` that connects to
/// `host:port` via a TCPClientInterface.
pub fn write_rns_config(dir: &Path, host: &str, port: u16) {
    let config = format!(
        "[reticulum]\n\
         enable_transport = no\n\
         share_instance = no\n\
         \n\
         [interfaces]\n\
         \n\
           [[RNS TCP Client]]\n\
             type = TCPClientInterface\n\
             enabled = yes\n\
             target_host = {host}\n\
             target_port = {port}\n\
             ingress_control = false\n"
    );
    std::fs::write(dir.join("config"), config).expect("write_rns_config: write failed");
}

// ---------------------------------------------------------------------------
// Transport serialization
// ---------------------------------------------------------------------------

/// Global mutex that serialises transport start/shutdown across tests in one
/// binary.  Each test that starts a client must hold this lock for its entire
/// duration.
pub static TEST_MUTEX: Mutex<()> = Mutex::new(());

// ---------------------------------------------------------------------------
// Client lifecycle helpers
// ---------------------------------------------------------------------------

/// Start an LXMF client using `dir` as config, storage, and identity root.
/// `dir` must already contain a valid `config` file (see [`write_rns_config`]).
///
/// Creates a fresh identity file inside `dir`.  Panics on failure.
pub fn start_test_client(dir: &Path, display_name: &str) -> u64 {
    let dir_str = dir.to_str().expect("non-UTF8 temp path");
    let identity_path = dir.join("identity");

    let config_c = CString::new(dir_str).unwrap();
    let storage_c = CString::new(dir_str).unwrap();
    let identity_c = CString::new(identity_path.to_str().unwrap()).unwrap();
    let name_c = CString::new(display_name).unwrap();

    let handle = retichat_ffi::lxmf_client_start(
        config_c.as_ptr(),
        storage_c.as_ptr(),
        identity_c.as_ptr(),
        1,              // create_identity = true
        name_c.as_ptr(),
        0,              // log_level
        -1,             // stamp_cost = none
    );

    if handle == 0 {
        let err = last_error_str().unwrap_or_else(|| "<no error>".to_string());
        panic!("lxmf_client_start failed: {err}");
    }
    handle
}

/// Fetch and consume the last error string (if any).
pub fn last_error_str() -> Option<String> {
    let ptr = retichat_ffi::lxmf_last_error();
    if ptr.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(ptr).to_string_lossy().into_owned() };
    retichat_ffi::lxmf_free_string(ptr);
    Some(s)
}

/// Get the 16-byte LXMF delivery destination hash for a client.
pub fn client_dest_hash(client: u64) -> Vec<u8> {
    let mut buf = vec![0u8; 16];
    let n = retichat_ffi::lxmf_client_dest_hash(client, buf.as_mut_ptr(), 16);
    assert_eq!(n, 16, "lxmf_client_dest_hash returned {n}");
    buf
}

/// Get the 16-byte identity hash for a client.
pub fn client_identity_hash(client: u64) -> Vec<u8> {
    let mut buf = vec![0u8; 16];
    let n = retichat_ffi::lxmf_client_identity_hash(client, buf.as_mut_ptr(), 16);
    assert_eq!(n, 16, "lxmf_client_identity_hash returned {n}");
    buf
}

/// Shut down a client.  Panics if shutdown fails.
pub fn shutdown_client(client: u64) {
    let rc = retichat_ffi::lxmf_client_shutdown(client);
    if rc != 0 {
        let err = last_error_str().unwrap_or_else(|| "<no error>".to_string());
        panic!("lxmf_client_shutdown failed: {err}");
    }
}

/// RAII guard: calls `shutdown_client` when dropped.
///
/// Guarantees that the Reticulum transport singleton is torn down even when a
/// test panics mid-way, preventing subsequent tests from failing with
/// "Reticulum is already initialised".
pub struct ClientGuard(u64);

impl ClientGuard {
    pub fn new(handle: u64) -> Self {
        Self(handle)
    }
    pub fn handle(&self) -> u64 {
        self.0
    }
}

impl Drop for ClientGuard {
    fn drop(&mut self) {
        if self.0 != 0 {
            let _ = retichat_ffi::lxmf_client_shutdown(self.0);
        }
    }
}

// ---------------------------------------------------------------------------
// Python subprocess helpers
// ---------------------------------------------------------------------------

/// Path to a Python helper script relative to the `tests/python/` directory in
/// this crate.  The scripts directory is located relative to the crate root
/// (CARGO_MANIFEST_DIR) at compile time.
fn python_script(name: &str) -> std::path::PathBuf {
    let manifest_dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir.join("tests").join("python").join(name)
}

/// Find the python3 executable.
fn python_bin() -> String {
    std::env::var("PYTHON").unwrap_or_else(|_| "python3".to_string())
}

/// A running Python helper subprocess.  Kill on drop.
pub struct PyProcess {
    pub child: Child,
    pub name: String,
    /// Remaining stdout reader when spawn already consumed the first line.
    pub piped_stdout: Option<BufReader<ChildStdout>>,
}

impl Drop for PyProcess {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Spawn `rns_receiver.py <config_dir>` and block until it prints "READY:<hex>"
/// or "ERROR:…" on stdout.
///
/// Returns `(PyProcess, dest_hash_bytes)`.  The caller drives the process to
/// completion by calling [`wait_python`].
pub fn spawn_python_receiver(config_dir: &Path) -> (PyProcess, Vec<u8>) {
    let script = python_script("rns_receiver.py");
    let mut child = Command::new(python_bin())
        .arg(&script)
        .arg(config_dir.to_str().unwrap())
        .env("RNS_HOST", rnsd_host())
        .env("RNS_PORT", rnsd_port().to_string())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap_or_else(|e| panic!("failed to spawn rns_receiver.py: {e}"));

    let stdout = child.stdout.take().unwrap();
    let mut reader = BufReader::new(stdout);
    let dest_hash_hex = loop {
        let mut line = String::new();
        reader.read_line(&mut line).expect("read from rns_receiver.py");
        let line = line.trim().to_string();
        eprintln!("  [py-recv] {line}");
        if let Some(hex) = line.strip_prefix("READY:") {
            break hex.to_string();
        }
        if line.starts_with("ERROR") || line.starts_with("TIMEOUT") {
            panic!("rns_receiver.py failed to start: {line}");
        }
    };

    let dest_bytes = hex::decode(&dest_hash_hex)
        .unwrap_or_else(|_| panic!("invalid dest hash hex from receiver: {dest_hash_hex}"));

    // Keep the reader in the struct so wait_python can drain the RECEIVED: line.
    let proc = PyProcess { child, name: "rns_receiver".to_string(), piped_stdout: Some(reader) };
    (proc, dest_bytes)
}

/// Spawn `rns_announcer.py <config_dir>` and block until it prints "ANNOUNCED:<hex>".
///
/// Returns `(PyProcess, dest_hash_bytes)`.
pub fn spawn_python_announcer(config_dir: &Path) -> (PyProcess, Vec<u8>) {
    let script = python_script("rns_announcer.py");
    let mut child = Command::new(python_bin())
        .arg(&script)
        .arg(config_dir.to_str().unwrap())
        .env("RNS_HOST", rnsd_host())
        .env("RNS_PORT", rnsd_port().to_string())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap_or_else(|e| panic!("failed to spawn rns_announcer.py: {e}"));

    let stdout = child.stdout.take().unwrap();
    let mut reader = BufReader::new(stdout);
    let dest_hash_hex = loop {
        let mut line = String::new();
        reader.read_line(&mut line).expect("read from rns_announcer.py");
        let line = line.trim().to_string();
        eprintln!("  [py-announce] {line}");
        if let Some(hex) = line.strip_prefix("ANNOUNCED:") {
            break hex.to_string();
        }
        if line.starts_with("ERROR") {
            panic!("rns_announcer.py failed to start: {line}");
        }
    };

    let dest_bytes = hex::decode(&dest_hash_hex)
        .unwrap_or_else(|_| panic!("invalid dest hash hex from announcer: {dest_hash_hex}"));

    let proc = PyProcess { child, name: "rns_announcer".to_string(), piped_stdout: Some(reader) };
    (proc, dest_bytes)
}

/// Spawn `rns_sender.py <config_dir> <dest_hex> <content> <method>`.
/// Returns the process; caller must call [`wait_python`] to assert success.
pub fn spawn_python_sender(
    config_dir: &Path,
    dest_hash: &[u8],
    content: &str,
    method: &str,
) -> PyProcess {
    let script = python_script("rns_sender.py");
    let dest_hex = hex::encode(dest_hash);
    let child = Command::new(python_bin())
        .arg(&script)
        .arg(config_dir.to_str().unwrap())
        .arg(&dest_hex)
        .arg(content)
        .arg(method)
        .env("RNS_HOST", rnsd_host())
        .env("RNS_PORT", rnsd_port().to_string())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap_or_else(|e| panic!("failed to spawn rns_sender.py: {e}"));

    PyProcess { child, name: "rns_sender".to_string(), piped_stdout: None }
}

/// Spawn `rns_prop_sender.py <config_dir> <dest_hex> <content>`.
pub fn spawn_python_prop_sender(
    config_dir: &Path,
    dest_hash: &[u8],
    content: &str,
) -> PyProcess {
    let script = python_script("rns_prop_sender.py");
    let dest_hex = hex::encode(dest_hash);
    let child = Command::new(python_bin())
        .arg(&script)
        .arg(config_dir.to_str().unwrap())
        .arg(&dest_hex)
        .arg(content)
        .env("RNS_HOST", rnsd_host())
        .env("RNS_PORT", rnsd_port().to_string())
        .env("PROP_NODE_HASH", hex::encode(prop_node_hash_bytes()))
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap_or_else(|e| panic!("failed to spawn rns_prop_sender.py: {e}"));

    PyProcess { child, name: "rns_prop_sender".to_string(), piped_stdout: None }
}

/// Wait for a Python process to exit, draining its stdout.
/// Returns `(exit_code, last_stdout_line)`.
pub fn wait_python(mut proc: PyProcess) -> (i32, String) {
    let name = proc.name.clone();
    let mut last_line = String::new();

    // Use pre-consumed reader if available (e.g. spawn_python_receiver already
    // read the READY: line), otherwise fall back to the raw child stdout.
    if let Some(reader) = proc.piped_stdout.take() {
        for line in reader.lines() {
            if let Ok(line) = line {
                eprintln!("  [{name}] {line}");
                last_line = line;
            }
        }
    } else if let Some(stdout) = proc.child.stdout.take() {
        let reader = BufReader::new(stdout);
        for line in reader.lines() {
            if let Ok(line) = line {
                eprintln!("  [{name}] {line}");
                last_line = line;
            }
        }
    }

    let status = proc.child.wait().expect("wait on python subprocess");
    let code = status.code().unwrap_or(-1);
    eprintln!("  [{name}] exited with code {code}");
    (code, last_line)
}

// ---------------------------------------------------------------------------
// Outbound processing driver
// ---------------------------------------------------------------------------

/// Spawn a background thread that calls `lxmf_client_process_outbound` every
/// 500 ms until `stop` is set to `true`.
pub fn process_outbound_driver(client: u64, stop: Arc<AtomicBool>) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        while !stop.load(Ordering::Relaxed) {
            retichat_ffi::lxmf_client_process_outbound(client);
            std::thread::sleep(Duration::from_millis(500));
        }
    })
}

// ---------------------------------------------------------------------------
// Callback capture infrastructure
// ---------------------------------------------------------------------------

/// A thread-safe queue + condvar pair used to capture callback events.
pub type Capture<T> = Arc<(Mutex<Vec<T>>, Condvar)>;

pub fn new_capture<T>() -> Capture<T> {
    Arc::new((Mutex::new(vec![]), Condvar::new()))
}

/// Block until at least one item is in the capture or `timeout` elapses.
/// Returns the first captured item, or `None` on timeout.
pub fn wait_for_one<T: Clone>(capture: &Capture<T>, timeout: Duration) -> Option<T> {
    let (lock, cvar) = &**capture;
    let guard = lock.lock().unwrap();
    let (guard, timed_out) = cvar
        .wait_timeout_while(guard, timeout, |v| v.is_empty())
        .unwrap();
    if timed_out.timed_out() {
        None
    } else {
        guard.first().cloned()
    }
}

/// Block until `pred` returns `true` on the captured items or `timeout` elapses.
pub fn wait_until<T, F>(capture: &Capture<T>, timeout: Duration, pred: F) -> bool
where
    T: Clone,
    F: Fn(&[T]) -> bool,
{
    let (lock, cvar) = &**capture;
    let guard = lock.lock().unwrap();
    let (guard, timed_out) = cvar
        .wait_timeout_while(guard, timeout, |v| !pred(v))
        .unwrap();
    !timed_out.timed_out() || pred(&guard)
}

// ---------------------------------------------------------------------------
// Context pointer helpers (for passing a Capture<T> as a *mut c_void)
// ---------------------------------------------------------------------------

/// Create a context pointer for passing to an FFI callback registration.
///
/// Boxes a clone of the Arc so the actual capture data is kept alive even
/// if the original Arc goes out of scope.  Release with [`release_ctx_ptr`]
/// once callbacks are guaranteed to have finished (i.e. after `shutdown_client`).
pub fn capture_ctx_ptr<T>(capture: &Capture<T>) -> *mut c_void {
    Box::into_raw(Box::new(Arc::clone(capture))) as *mut c_void
}

/// Release a context pointer that was created with [`capture_ctx_ptr`].
///
/// # Safety
///
/// * Must be called exactly once per `capture_ctx_ptr` call.
/// * Must be called only after all callbacks that might fire with this context
///   have ceased (e.g. after `shutdown_client`).
/// * `T` must be the same type used in the matching `capture_ctx_ptr` call.
pub unsafe fn release_ctx_ptr<T>(ctx_ptr: *mut c_void) {
    drop(Box::from_raw(ctx_ptr as *mut Capture<T>));
}

// ---------------------------------------------------------------------------
// Captured event types
// ---------------------------------------------------------------------------

#[derive(Clone, Debug)]
pub struct DeliveredMsg {
    pub hash: Vec<u8>,
    pub src_hash: Vec<u8>,
    pub dest_hash: Vec<u8>,
    pub content: String,
    pub sig_valid: bool,
}

#[derive(Clone, Debug)]
pub struct AnnounceEvent {
    pub dest_hash: Vec<u8>,
    pub display_name: Option<String>,
}

#[derive(Clone, Debug)]
pub struct StateEvent {
    pub msg_hash: Vec<u8>,
    pub state: u8,
}

#[derive(Clone, Debug)]
pub struct SyncCompleteEvent {
    pub count: u32,
}

// ---------------------------------------------------------------------------
// Callback trampolines
//
// Each trampoline casts `ctx` back to `*const Capture<EventType>` (which is
// really `*mut Box<Arc<...>>`) and pushes one event, then signals the condvar.
// ---------------------------------------------------------------------------

pub extern "C" fn delivery_trampoline(
    ctx: *mut c_void,
    hash: *const u8,
    hash_len: u32,
    src_hash: *const u8,
    src_len: u32,
    dest_hash: *const u8,
    dest_len: u32,
    _title: *const c_char,
    content: *const c_char,
    _timestamp: f64,
    sig_valid: i32,
    _fields: *const u8,
    _fields_len: u32,
) {
    let capture = unsafe { &*(ctx as *const Capture<DeliveredMsg>) };
    let msg = DeliveredMsg {
        hash: unsafe { std::slice::from_raw_parts(hash, hash_len as usize).to_vec() },
        src_hash: unsafe { std::slice::from_raw_parts(src_hash, src_len as usize).to_vec() },
        dest_hash: unsafe { std::slice::from_raw_parts(dest_hash, dest_len as usize).to_vec() },
        content: unsafe {
            if content.is_null() {
                String::new()
            } else {
                CStr::from_ptr(content).to_string_lossy().into_owned()
            }
        },
        sig_valid: sig_valid != 0,
    };
    let (lock, cvar) = &**capture;
    lock.lock().unwrap().push(msg);
    cvar.notify_one();
}

pub extern "C" fn announce_trampoline(
    ctx: *mut c_void,
    dest_hash: *const u8,
    dest_len: u32,
    display_name: *const c_char,
) {
    let capture = unsafe { &*(ctx as *const Capture<AnnounceEvent>) };
    let display_name = if display_name.is_null() {
        None
    } else {
        Some(unsafe { CStr::from_ptr(display_name).to_string_lossy().into_owned() })
    };
    let event = AnnounceEvent {
        dest_hash: unsafe { std::slice::from_raw_parts(dest_hash, dest_len as usize).to_vec() },
        display_name,
    };
    let (lock, cvar) = &**capture;
    lock.lock().unwrap().push(event);
    cvar.notify_one();
}

pub extern "C" fn state_trampoline(
    ctx: *mut c_void,
    msg_hash: *const u8,
    hash_len: u32,
    state: u8,
) {
    let capture = unsafe { &*(ctx as *const Capture<StateEvent>) };
    let event = StateEvent {
        msg_hash: unsafe { std::slice::from_raw_parts(msg_hash, hash_len as usize).to_vec() },
        state,
    };
    let (lock, cvar) = &**capture;
    lock.lock().unwrap().push(event);
    cvar.notify_one();
}

pub extern "C" fn sync_trampoline(ctx: *mut c_void, message_count: u32) {
    let capture = unsafe { &*(ctx as *const Capture<SyncCompleteEvent>) };
    let event = SyncCompleteEvent { count: message_count };
    let (lock, cvar) = &**capture;
    lock.lock().unwrap().push(event);
    cvar.notify_one();
}
