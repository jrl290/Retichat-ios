import RNS
import LXMF
import os
import sys
import shutil
import glob
import base64

# Paths
RATCHET_DIR = "/Users/james/Library/Containers/152AB01A-BAE8-4F74-BCCC-F430629E3977/Data/Library/Application Support/reticulum/lxmf_storage/lxmf/ratchets/"
IDENTITY_PATH = "/Users/james/Library/Containers/152AB01A-BAE8-4F74-BCCC-F430629E3977/Data/Library/Application Support/reticulum/identity"
TEMP_CONFIG = os.path.abspath("./temp_rns_config")
PAYLOAD_HEX = "13a0e1169141ee921192f879ecad36225498d5c313d2d262a477eee9198e217473dfffa64d07ae6060ad4573d677b48294bb532edac07c41cc53479d577b745cb78f7e2406c93caf4a948cc5d1574a1b9fff5fb885703d8e189ab602ece4b46711c3c39010ce052d933989c6629729c466d4274a5fa0fe8dd97ca693ab7197ea20c1e2da96c66abd1503d0daa943830d2cc6ab888aa5659ed6b51424520511816ecefa8c202e4297db2611a4e0dfc1d147f170dcc61adbb811c95481dd8c39fe"

# Find source ratchet
files = glob.glob(RATCHET_DIR + "7509e054b24e7135465f0ef3898cfbfb*")
if not files:
    print(f"No file matching 7509e054b24e7135465f0ef3898cfbfb in {RATCHET_DIR}")
    sys.exit(1)
SOURCE_RATCHET = files[0]

# Prepare temp directory
if os.path.exists(TEMP_CONFIG):
    shutil.rmtree(TEMP_CONFIG)
os.makedirs(os.path.join(TEMP_CONFIG, "storage", "ratchets"), exist_ok=True)

# Copy ratchet to where RNS expects it
TARGET_RATCHET = os.path.join(TEMP_CONFIG, "storage", "ratchets", "7509e054b24e7135465f0ef3898cfbfb")
shutil.copy(SOURCE_RATCHET, TARGET_RATCHET)

# Setup Reticulum
rns = RNS.Reticulum(configdir=TEMP_CONFIG)

# Load identity
identity = RNS.Identity.from_file(IDENTITY_PATH)
delivery_destination = RNS.Destination(identity, RNS.Destination.IN, RNS.Destination.SINGLE, "lxmf", "delivery")

print(f"Destination hash: {delivery_destination.hash.hex()}")

# Try to decrypt directly
payload = bytes.fromhex(PAYLOAD_HEX)
print(f"Payload length: {len(payload)}")

try:
    decrypted = delivery_destination.decrypt(payload)
    if decrypted:
        print("Decryption successful!")
        print(f"Plaintext (hex): {decrypted.hex()}")
    else:
        print("Decryption failed: returned None")
        
        # Manually inspect the ratchet if possible
        if os.path.exists(TARGET_RATCHET):
            print(f"Ratchet file size: {os.path.getsize(TARGET_RATCHET)}")
        
except Exception as e:
    print(f"Decryption failed with exception: {str(e)}")
