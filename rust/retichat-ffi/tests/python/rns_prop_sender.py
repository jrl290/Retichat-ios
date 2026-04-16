#!/usr/bin/env python3
"""
LXMF Propagation Sender for retichat-ffi integration tests.

Sends a PROPAGATED message to a target dest hash via the configured
propagation node.  Used to test that the Rust LXMF client receives a
message via sync.

Behaviour:
  1. Connect to rnsd.
  2. Create a fresh ephemeral sender identity.
  3. Send a PROPAGATED message to the given dest hash.
  4. Wait for state SENT (accepted by prop node) OR DELIVERED.
  5. Print "SENT" and exit 0 on success.
  6. Print "FAILED:<reason>" and exit 1 on failure.
  7. Does NOT wait for DELIVERED — propagated delivery happens when the
     receiver syncs, which is the Rust client's job.

Usage:
  rns_prop_sender.py <config_dir> <dest_hash_hex> <message_content>

Environment variables:
  RNS_HOST     default 192.168.2.107
  RNS_PORT     default 4242
  SEND_TIMEOUT default 60 (seconds)
"""

import os, sys, time, threading
import pathlib

sys.stdout = os.fdopen(sys.stdout.fileno(), 'w', buffering=1)
sys.stderr = os.fdopen(sys.stderr.fileno(), 'w', buffering=1)

BASE = pathlib.Path(__file__).resolve().parent.parent.parent.parent.parent.parent
for lib in ["Reticulum-master", "LXMF-master"]:
    p = str(BASE / lib)
    if p not in sys.path:
        sys.path.insert(0, p)

import RNS
import LXMF

if len(sys.argv) < 4:
    print("Usage: rns_prop_sender.py <config_dir> <dest_hash_hex> <content>",
          file=sys.stderr)
    sys.exit(2)

config_dir   = sys.argv[1]
dest_hex     = sys.argv[2].strip()
content      = sys.argv[3]
SEND_TIMEOUT    = int(os.environ.get("SEND_TIMEOUT", "60"))
RNS_HOST        = os.environ.get("RNS_HOST", "192.168.2.107")
RNS_PORT        = int(os.environ.get("RNS_PORT", "4242"))
PROP_NODE_HASH  = os.environ.get("PROP_NODE_HASH", "90c650419e3a991a0bbe4cb3123724a4")

done_event = threading.Event()
final_state = [None]

# For propagated messages, SENT means the prop node accepted it.
# DELIVERED is also acceptable (direct path happened to be available).
TERMINAL_STATES = {
    LXMF.LXMessage.SENT,
    LXMF.LXMessage.DELIVERED,
    LXMF.LXMessage.FAILED,
    LXMF.LXMessage.REJECTED,
    0xFE,  # CANCELLED
}

def state_changed_or_delivered(message):
    state = message.state
    print(f"[py-prop-send] state={state:#04x}", flush=True)
    if state == LXMF.LXMessage.SENT or state == LXMF.LXMessage.DELIVERED:
        final_state[0] = "SENT"
        done_event.set()
    elif state in TERMINAL_STATES:
        final_state[0] = f"FAILED:state={state:#04x}"
        done_event.set()

def delivery_cb(message):
    state_changed_or_delivered(message)

def failed_cb(message):
    state_changed_or_delivered(message)

# ── Main ──────────────────────────────────────────────────────────────────
RNS.loglevel = RNS.LOG_WARNING
print(f"[py-prop-send] connecting to {RNS_HOST}:{RNS_PORT}", flush=True)
print(f"[py-prop-send] target dest = {dest_hex}", flush=True)

try:
    reticulum = RNS.Reticulum(configdir=config_dir)
except Exception as e:
    print(f"ERROR: RNS init failed: {e}", flush=True)
    sys.exit(2)

storage_dir = os.path.join(config_dir, "lxmf_storage")
os.makedirs(storage_dir, exist_ok=True)

prop_node_bytes = bytes.fromhex(PROP_NODE_HASH)
router = LXMF.LXMRouter(storagepath=storage_dir, enforce_stamps=False)
router.set_outbound_propagation_node(prop_node_bytes)
sender_id = RNS.Identity()
sender_dest = router.register_delivery_identity(sender_id, display_name="Retichat-PropSender")
router.announce(sender_dest.hash)
print(f"[py-prop-send] sender dest = {sender_dest.hash.hex()}", flush=True)

# Wait briefly for a path to the propagation node.
if not RNS.Transport.has_path(prop_node_bytes):
    RNS.Transport.request_path(prop_node_bytes)
    deadline = time.time() + 30
    while not RNS.Transport.has_path(prop_node_bytes) and time.time() < deadline:
        time.sleep(0.3)
if not RNS.Transport.has_path(prop_node_bytes):
    print(f"FAILED:no path to prop node {PROP_NODE_HASH}", flush=True)
    sys.exit(1)
print(f"[py-prop-send] path to prop node confirmed", flush=True)

# Give rnsd a moment to relay the Rust client's announce to this connection.
# Without this, Identity.recall may return None even after the re-announce.
time.sleep(2)

# Build recipient destination from its hash (no path resolution needed for
# propagated sends — the router will route via the prop node).
dest_hash = bytes.fromhex(dest_hex)

# Try to resolve path (best-effort; not strictly required for propagated).
if not RNS.Transport.has_path(dest_hash):
    RNS.Transport.request_path(dest_hash)
    deadline = time.time() + 15
    last_request = time.time()
    while not RNS.Transport.has_path(dest_hash) and time.time() < deadline:
        time.sleep(0.3)
        if time.time() - last_request > 5:
            RNS.Transport.request_path(dest_hash)
            last_request = time.time()

if RNS.Transport.has_path(dest_hash):
    print(f"[py-prop-send] path found to {dest_hex}", flush=True)
else:
    print(f"[py-prop-send] no path to {dest_hex} (OK for propagated)", flush=True)

# Identity.recall requires having processed an ANNOUNCE packet for this dest.
# Retry for up to 30 s — the Rust client may re-announce after we connect.
dest_identity = RNS.Identity.recall(dest_hash)
if dest_identity is None:
    print(f"[py-prop-send] waiting up to 30 s for identity of {dest_hex}...", flush=True)
    recall_deadline = time.time() + 30
    last_path_req = time.time()
    while dest_identity is None and time.time() < recall_deadline:
        time.sleep(0.5)
        # Periodically re-request path — the path response carries the announce
        if time.time() - last_path_req > 5:
            RNS.Transport.request_path(dest_hash)
            last_path_req = time.time()
        dest_identity = RNS.Identity.recall(dest_hash)

if dest_identity is None:
    print(f"FAILED:identity not recalled for {dest_hex} — did the Rust client announce?", flush=True)
    sys.exit(1)

destination = RNS.Destination(
    dest_identity,
    RNS.Destination.OUT,
    RNS.Destination.SINGLE,
    "lxmf",
    "delivery",
)

msg = LXMF.LXMessage(
    destination,
    sender_dest,
    content,
    title="",
    desired_method=LXMF.LXMessage.PROPAGATED,
)
msg.register_delivery_callback(delivery_cb)
msg.register_failed_callback(failed_cb)

# Poll for state changes (LXMF doesn't always fire callbacks on SENT).
def poller():
    while not done_event.is_set():
        state = msg.state
        if state in TERMINAL_STATES:
            state_changed_or_delivered(msg)
            break
        time.sleep(1)

import threading
poll_thread = threading.Thread(target=poller, daemon=True)

print(f"[py-prop-send] sending propagated message ...", flush=True)
router.handle_outbound(msg)
poll_thread.start()

if done_event.wait(timeout=SEND_TIMEOUT):
    result = final_state[0]
    print(result, flush=True)
    sys.exit(0 if result == "SENT" else 1)
else:
    print(f"FAILED:timeout after {SEND_TIMEOUT}s (state={msg.state:#04x})", flush=True)
    sys.exit(1)
