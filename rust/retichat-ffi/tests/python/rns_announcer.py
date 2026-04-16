#!/usr/bin/env python3
"""
LXMF Announcer for retichat-ffi integration tests.

Behaviour:
  1. Connect to rnsd with a fresh ephemeral identity.
  2. Register a delivery destination.
  3. Announce it on the network.
  4. Print "ANNOUNCED:<hex-dest-hash>" to stdout.
  5. Stay alive for $ANNOUNCE_DURATION seconds re-announcing every 10 s,
     then exit 0.

Usage:
  rns_announcer.py <config_dir>

Environment variables:
  RNS_HOST          default 192.168.2.107
  RNS_PORT          default 4242
  ANNOUNCE_DURATION default 60 (seconds to keep announcing)
  DISPLAY_NAME      default "Retichat-Test-Peer"
"""

import os, sys, time
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

if len(sys.argv) < 2:
    print("Usage: rns_announcer.py <config_dir>", file=sys.stderr)
    sys.exit(2)

config_dir       = sys.argv[1]
RNS_HOST         = os.environ.get("RNS_HOST", "192.168.2.107")
RNS_PORT         = int(os.environ.get("RNS_PORT", "4242"))
ANNOUNCE_DURATION = int(os.environ.get("ANNOUNCE_DURATION", "60"))
DISPLAY_NAME     = os.environ.get("DISPLAY_NAME", "Retichat-Test-Peer")

RNS.loglevel = RNS.LOG_WARNING
print(f"[py-announce] connecting to {RNS_HOST}:{RNS_PORT}", flush=True)

try:
    reticulum = RNS.Reticulum(configdir=config_dir)
except Exception as e:
    print(f"ERROR: RNS init failed: {e}", flush=True)
    sys.exit(2)

storage_dir = os.path.join(config_dir, "lxmf_storage")
os.makedirs(storage_dir, exist_ok=True)

router = LXMF.LXMRouter(storagepath=storage_dir, enforce_stamps=False)
identity = RNS.Identity()
destination = router.register_delivery_identity(identity, display_name=DISPLAY_NAME)

# First announce
router.announce(destination.hash)
dest_hex = destination.hash.hex()
print(f"ANNOUNCED:{dest_hex}", flush=True)
print(f"[py-announce] dest hash = {dest_hex}", flush=True)

start = time.time()
next_announce = time.time() + 10.0
while time.time() - start < ANNOUNCE_DURATION:
    now = time.time()
    if now >= next_announce:
        router.announce(destination.hash)
        print(f"[py-announce] re-announced at t={now - start:.1f}s", flush=True)
        next_announce = now + 10.0
    time.sleep(0.5)

print("[py-announce] done", flush=True)
sys.exit(0)
