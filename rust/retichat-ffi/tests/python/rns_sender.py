#!/usr/bin/env python3
"""
LXMF Sender for retichat-ffi integration tests.

Behaviour:
  1. Connect to rnsd.
  2. Create a fresh ephemeral identity, register delivery destination.
  3. Announce sender identity.
  4. Resolve path to recipient (dest hash from CLI arg).
  5. Send one LXMF message with the given content.
  6. Wait for DELIVERED or FAILED state.
  7. Print "SENT" and exit 0 on DELIVERED; print "FAILED:<reason>" and exit 1 otherwise.

Usage:
  rns_sender.py <config_dir> <dest_hash_hex> <message_content> [direct|propagated]

Environment variables:
  RNS_HOST     default 192.168.2.107
  RNS_PORT     default 4242
  SEND_TIMEOUT default 60 (seconds)
"""

import os, sys, time, threading
import pathlib

sys.stdout = os.fdopen(sys.stdout.fileno(), 'w', buffering=1)
sys.stderr = os.fdopen(sys.stderr.fileno(), 'w', buffering=1)

# ── Locate RNS / LXMF from workspace ─────────────────────────────────────
BASE = pathlib.Path(__file__).resolve().parent.parent.parent.parent.parent.parent
for lib in ["Reticulum-master", "LXMF-master"]:
    p = str(BASE / lib)
    if p not in sys.path:
        sys.path.insert(0, p)

import RNS
import LXMF

# ── Args ──────────────────────────────────────────────────────────────────
if len(sys.argv) < 4:
    print("Usage: rns_sender.py <config_dir> <dest_hash_hex> <content> [direct|propagated]",
          file=sys.stderr)
    sys.exit(2)

config_dir   = sys.argv[1]
dest_hex     = sys.argv[2].strip()
content      = sys.argv[3]
method_str   = sys.argv[4].lower() if len(sys.argv) > 4 else "direct"

SEND_TIMEOUT = int(os.environ.get("SEND_TIMEOUT", "60"))
RNS_HOST     = os.environ.get("RNS_HOST", "192.168.2.107")
RNS_PORT     = int(os.environ.get("RNS_PORT", "4242"))

method = LXMF.LXMessage.DIRECT if method_str == "direct" else LXMF.LXMessage.PROPAGATED

# ── State ─────────────────────────────────────────────────────────────────
done_event = threading.Event()
final_state = [None]

def delivery_cb(message):
    print(f"[py-send] delivered: state={message.state}", flush=True)
    final_state[0] = "DELIVERED"
    done_event.set()

def failed_cb(message):
    print(f"[py-send] failed: state={message.state}", flush=True)
    final_state[0] = f"FAILED:state={message.state}"
    done_event.set()

# ── Main ──────────────────────────────────────────────────────────────────
RNS.loglevel = RNS.LOG_WARNING
print(f"[py-send] connecting to {RNS_HOST}:{RNS_PORT}", flush=True)

try:
    reticulum = RNS.Reticulum(configdir=config_dir)
except Exception as e:
    print(f"ERROR: RNS init failed: {e}", flush=True)
    sys.exit(2)

storage_dir = os.path.join(config_dir, "lxmf_storage")
os.makedirs(storage_dir, exist_ok=True)

router = LXMF.LXMRouter(storagepath=storage_dir, enforce_stamps=False)
sender_id = RNS.Identity()
sender_dest = router.register_delivery_identity(sender_id, display_name="Retichat-Test-Sender")
router.announce(sender_dest.hash)
print(f"[py-send] sender dest = {sender_dest.hash.hex()}", flush=True)

# Give rnsd a moment to relay recent announces to this newly-connected client.
# Without this delay, request_path may be sent before rnsd has replayed the
# Rust announce, leading to a 60-second timeout.
time.sleep(2)

# Resolve path
dest_hash = bytes.fromhex(dest_hex)
print(f"[py-send] resolving path to {dest_hex} ...", flush=True)
if not RNS.Transport.has_path(dest_hash):
    RNS.Transport.request_path(dest_hash)
    start = time.time()
    last_request = start
    while not RNS.Transport.has_path(dest_hash):
        time.sleep(0.3)
        # Retry request_path every 10 s in case the first one was lost.
        if time.time() - last_request > 10:
            RNS.Transport.request_path(dest_hash)
            last_request = time.time()
        if time.time() - start > SEND_TIMEOUT:
            print(f"FAILED:no path to {dest_hex} after {SEND_TIMEOUT}s", flush=True)
            sys.exit(1)
print(f"[py-send] path found", flush=True)

# Build destination
dest_identity = RNS.Identity.recall(dest_hash)
if dest_identity is None:
    print(f"FAILED:identity not recalled for {dest_hex}", flush=True)
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
    desired_method=method,
)
msg.register_delivery_callback(delivery_cb)
msg.register_failed_callback(failed_cb)

print(f"[py-send] sending via {method_str} ...", flush=True)
router.handle_outbound(msg)

if done_event.wait(timeout=SEND_TIMEOUT):
    result = final_state[0]
    if result == "DELIVERED":
        print("SENT", flush=True)
        sys.exit(0)
    else:
        print(result, flush=True)
        sys.exit(1)
else:
    print(f"FAILED:timeout after {SEND_TIMEOUT}s", flush=True)
    sys.exit(1)
