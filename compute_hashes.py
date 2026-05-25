import hashlib

def rfed_dest_hash(identity_hash_hex, app, aspects):
    identity_bytes = bytes.fromhex(identity_hash_hex)
    name = ".".join([app] + aspects)
    name_hash_full = hashlib.sha256(name.encode('utf-8')).digest()
    name_hash_trunc = name_hash_full[:10]
    material = name_hash_trunc + identity_bytes
    final_hash = hashlib.sha256(material).digest()
    return final_hash[:16].hex()

identities = ["7e5ff856dc2aa0fbc9fc8831b62d2834", "2c29f67404f1babdd0b76bb88cb05ac9"]
configs = [
    # Legacy rfed roots (kept registered during the soft-cut window)
    ("rfed", ["notify"]),
    ("rfed", ["channel"]),
    ("rfed", ["delivery"]),
    # Canonical split rfed aspects (REFACTOR.md step 4)
    ("rfed", ["channel", "subscribe"]),
    ("rfed", ["channel", "unsubscribe"]),
    ("rfed", ["channel", "publish"]),
    ("rfed", ["channel", "pull"]),
    ("rfed", ["notify", "register"]),
    ("rfed", ["notify", "unregister"]),
    # apns-bridge canonical aspects
    ("apns", ["relay"]),
    ("apns", ["register"]),
    ("apns", ["unregister"]),
    # LXMF
    ("lxmf", ["propagation"]),
]
prefixes = ["f52e34bc", "017304a6", "0ab898e0", "b2d42012", "3e558a3c"]

for ident in identities:
    print(f"Identity: {ident}")
    for app, aspects in configs:
        h = rfed_dest_hash(ident, app, aspects)
        match = ""
        for p in prefixes:
            if h.startswith(p):
                match = f" [MATCH: {p}]"
        print(f"  app={app} aspects={aspects} -> {h}{match}")
