#!/usr/bin/env python3
"""
LXMF Receiver for retichat-ffi integration tests.

Behaviour:
  1. Connect to rnsd, create a fresh ephemeral identity.
  2. Register a delivery destination, announce it.
  3. Print "READY:<hex-dest-hash>" to stdout (16 bytes = 32 hex chars).
  4. Wait for exactly one LXMF message (timeout via $RECV_TIMEOUT, default 60 s).
  5. On receipt: print "RECEIVED:<content>" then exit 0.
  6. On timeout: print "TIMEOUT" then exit 1.

Environment variables
  RNS_HOST     default 192.168.2.107
  RNS_PORT     default 4242
  RECV_TIMEOUT default 60 (seconds)

The config dir is passed as the first CLI argument so the Rust test can supply
an isolated temp directory that already contains a pre-written 'config' file.
"""

import os, sys, time, signal
import tempfile, threading, pathlib

# Force line-buffered stdout so Rust can read "READY:..." without blocking.
sys.stdout = os.fdopen(sys.stdout.fileno(), 'w', buffering=1)
sys.stderr = os.fdopen(sys.stderr.fileno(), 'w', buffering=1)

# ── Locate RNS / LXMF from workspace ─────────────────────────────────────
BASE = pathlib.Path(__file__).resolve().parent.parent.parent.parent.parent.parent  # workspace root
for lib in ["Reticulum-master", "LXMF-master"]:
    p = str(BASE / lib)
    if p not in sys.path:
        sys.path.insert(0, p)

import RNS
import LXMF

# ── Config ────────────────────────────────────────────────────────────────
RNS_HOST    = os.environ.get("RNS_HOST", "192.168.2.107")
RNS_PORT    = int(os.environ.get("RNS_PORT", "4242"))
RECV_TIMEOUT = int(os.environ.get("RECV_TIMEOUT", "60"))

if len(sys.argv) < 2:
    print("Usage: rns_receiver.py <config_dir>", file=sys.stderr)
    sys.exit(2)
config_dir = sys.argv[1]

# ── State ─────────────────────────────────────────────────────────────────
received_event = threading.Event()
received_content = None

def delivery_callback(message):
    global received_content
    content = message.content_as_string() if message.content else ""
    print(f"[py-recv] delivery: src={message.source_hash.hex()} content={repr(content)}", flush=True)
    received_content = content
    received_event.set()

# ── Main ──────────────────────────────────────────────────────────────────
RNS.loglevel = RNS.LOG_WARNING
print(f"[py-recv] connecting to {RNS_HOST}:{RNS_PORT}", flush=True)

try:
    reticulum = RNS.Reticulum(configdir=config_dir)
except Exception as e:
    print(f"ERROR: RNS init failed: {e}", flush=True)
    sys.exit(2)

storage_dir = os.path.join(config_dir, "lxmf_storage")
os.makedirs(storage_dir, exist_ok=True)

router = LXMF.LXMRouter(storagepath=storage_dir, enforce_stamps=False)
identity = RNS.Identity()
destination = router.register_delivery_identity(identity, display_name="Retichat-Test-Receiver")
router.register_delivery_callback(delivery_callback)

dest_hash_hex = destination.hash.hex()
print(f"READY:{dest_hash_hex}", flush=True)
print(f"[py-recv] dest hash = {dest_hash_hex}", flush=True)

# Announce so the Rust sender can get a path.
router.announce(destination.hash)
print("[py-recv] announced, waiting for message ...", flush=True)

if received_event.wait(timeout=RECV_TIMEOUT):
    print(f"RECEIVED:{received_content}", flush=True)
    sys.exit(0)
else:
    print("TIMEOUT", flush=True)
    sys.exit(1)
