//
//  RfedNotifyRegistrar.swift
//  Retichat
//
//  Registers this device's push-notification relay with rfed via a Link request
//  to `/rfed/notify/register`.
//
//  Architecture:
//    iOS app ──Link+identify──▶ rfed.notify (/rfed/notify/register)
//      payload: the apns_bridge's rfed.notify dest hash (32-char hex)
//      response: msgpack bool (true = success)
//
//  Required UserPreferences:
//    rfedNotifyHash  — rfed's rfed.notify destination hash (Link target)
//
//  The relay hash (apns_bridge's rfed.notify dest) is loaded from
//  PushBridgeConfig.plist when available.
//

import Foundation

final class RfedNotifyRegistrar {
    static let shared = RfedNotifyRegistrar()

    private let bridge = RetichatBridge.shared
    private let prefs  = UserPreferences.shared

    private let maxAttempts  = 8
    private let baseDelaySec = 5.0

    private init() {}

    // MARK: - Public API

    /// Register this subscriber's relay hash with rfed.
    /// `identityHandle` is the Rust FFI handle for the local identity.
    func registerIfNeeded(identityHandle: UInt64) {
        let rfedDestHex = prefs.rfedNotifyHash
        guard !rfedDestHex.isEmpty else { return }
        guard let rfedHash = Data(hexString: rfedDestHex) else {
            print("[RfedNotify] Invalid rfedNotifyHash — not 32 hex chars")
            return
        }
        guard let relayHex = ApnsBridgeHashes.notifyRelayHex else {
            print("[RfedNotify] PushBridgeConfig.plist missing or invalid; skipping relay registration")
            return
        }

        // Payload: fixarray-3 [str(relayHex), bin(64) pubkey, bin(64) sig_over_utf8(relayHex)]
        // Subscriber identity is derived from pubkey on the server — no timing dependency.
        guard let payload = buildSignedPayload(relayHex: relayHex, channelHash: nil, identityHandle: identityHandle) else {
            print("[RfedNotify] Failed to sign payload")
            return
        }

        Task.detached(priority: .background) { [weak self] in
            await self?.requestWithRetry(
                rfedHash: rfedHash,
                identityHandle: identityHandle,
                payload: payload
            )
        }
    }

    /// Best-effort deregistration from a previous rfed node.
    /// Sends a single `/rfed/notify/unregister` request with no retry.
    /// Call before changing `rfedNotifyHash` in UserPreferences and restarting the service.
    func deregisterFrom(oldNotifyHashHex: String, identityHandle: UInt64) {
        guard !oldNotifyHashHex.isEmpty,
              let rfedHash = Data(hexString: oldNotifyHashHex) else { return }
        guard let relayHex = ApnsBridgeHashes.notifyRelayHex else { return }

        guard let payload = buildSignedPayload(relayHex: relayHex, channelHash: nil, identityHandle: identityHandle) else { return }

        let bridge = self.bridge
        Task.detached(priority: .background) {
            guard bridge.transportHasPath(destHash: rfedHash) else {
                print("[RfedNotify] No path to old rfed node — skipping deregister")
                return
            }
            _ = bridge.linkRequest(
                destHash: rfedHash,
                appName: "rfed",
                aspects: "notify",
                identityHandle: identityHandle,
                path: "/rfed/notify/unregister",
                payload: payload,
                timeoutSecs: 5.0
            )
            print("[RfedNotify] Sent unregister to old rfed node")
        }
    }

    /// Register for per-channel push notification wakeups.
    /// Sends `[relay_hex, channel_hash_bin16]` as the value so the rfed node
    /// wakes this device when a message arrives on that specific channel.
    func registerForChannel(channelHash: Data, rfedNotifyHashHex: String, identityHandle: UInt64) {
        guard !rfedNotifyHashHex.isEmpty,
              let rfedHash = Data(hexString: rfedNotifyHashHex) else { return }
        guard let relayHex = ApnsBridgeHashes.notifyRelayHex else {
            print("[RfedNotify] PushBridgeConfig.plist missing — skipping channel notify registration")
            return
        }
        guard let payload = buildSignedPayload(relayHex: relayHex, channelHash: channelHash,
                                               identityHandle: identityHandle) else {
            print("[RfedNotify] Failed to sign channel notify payload")
            return
        }
        Task.detached(priority: .background) { [weak self] in
            await self?.requestWithRetry(rfedHash: rfedHash, identityHandle: identityHandle,
                                         payload: payload)
        }
    }

    /// Deregister this device from per-channel push notifications (best-effort, no retry).
    /// Call when the user leaves / unsubscribes from a channel.
    func deregisterForChannel(channelHash: Data, rfedNotifyHashHex: String, identityHandle: UInt64) {
        guard !rfedNotifyHashHex.isEmpty,
              let rfedHash = Data(hexString: rfedNotifyHashHex) else { return }
        guard let relayHex = ApnsBridgeHashes.notifyRelayHex else { return }
        guard let payload = buildSignedPayload(relayHex: relayHex, channelHash: channelHash,
                                               identityHandle: identityHandle) else { return }
        let bridge = self.bridge
        Task.detached(priority: .background) {
            guard bridge.transportHasPath(destHash: rfedHash) else { return }
            _ = bridge.linkRequest(destHash: rfedHash, appName: "rfed", aspects: "notify",
                                   identityHandle: identityHandle,
                                   path: "/rfed/notify/unregister",
                                   payload: payload, timeoutSecs: 5.0)
            print("[RfedNotify] Sent channel deregister (channel=\(channelHash.hexString.prefix(8))…)")
        }
    }

    // MARK: - Private

    nonisolated private func requestWithRetry(rfedHash: Data, identityHandle: UInt64,
                                              payload: Data) async {
        var delay = baseDelaySec
        for attempt in 1...maxAttempts {
            // Ensure path to rfed is known.
            if !bridge.transportHasPath(destHash: rfedHash) {
                _ = bridge.transportRequestPath(destHash: rfedHash)
                print("[RfedNotify] Waiting for path (attempt \(attempt))…")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                delay = min(delay * 2, 120)
                continue
            }

            let response = bridge.linkRequest(
                destHash: rfedHash,
                appName: "rfed",
                aspects: "notify",
                identityHandle: identityHandle,
                path: "/rfed/notify/register",
                payload: payload,
                timeoutSecs: 15.0
            )

            if let resp = response {
                // Response should be msgpack bool (true = 0xc3).
                let success = resp.count == 1 && resp[0] == 0xc3
                if success {
                    print("[RfedNotify] Registered relay with rfed")
                    return
                } else {
                    print("[RfedNotify] rfed returned false (attempt \(attempt))")
                }
            } else {
                let err = bridge.lastError() ?? "unknown"
                print("[RfedNotify] Link request failed (attempt \(attempt)): \(err)")
                // Request a fresh path — the stored path may be stale (e.g. old rfed
                // instance at many hops whose route is now broken).  A fresh PATH_REQUEST
                // forces rmap.world to update its routing table entry for this destination,
                // so the next attempt uses the current best route.
                _ = bridge.transportRequestPath(destHash: rfedHash)
            }

            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            delay = min(delay * 2, 120)
        }
        print("[RfedNotify] Giving up after \(maxAttempts) attempts")
    }

    // MARK: - msgpack encoding

    /// Build the signed payload: fixarray-3 [bin(value), bin(64) pubkey, bin(64) sig]
    /// where value = msgpack fixarray-2 [str(relay_hex), bin(16 channel_hash) | nil].
    /// Pass channelHash = nil for LXMF wakeup registration (server registers against
    /// the lxmf.delivery dest hash); pass the 16-byte channel hash for rfed channel
    /// wakeup registration.
    private func buildSignedPayload(relayHex: String, channelHash: Data?,
                                    identityHandle: UInt64) -> Data? {
        // Value: msgpack fixarray-2 [str(relay_hex), bin(16 channel_hash) | nil]
        var value = Data([0x92])                    // fixarray of 2
        value.append(encodeMsgpackString(relayHex))
        if let ch = channelHash {
            value.append(msgpackBin(ch))
        } else {
            value.append(0xc0)                      // msgpack nil
        }
        // Sig is over the raw msgpack-encoded value bytes
        guard let pubkey = bridge.identityPublicKey(handle: identityHandle),
              let sig    = bridge.identitySign(handle: identityHandle, data: value) else { return nil }
        var out = Data([0x93])    // fixarray of 3
        out.append(msgpackBin(value))
        out.append(msgpackBin(pubkey))
        out.append(msgpackBin(sig))
        return out
    }

    private func msgpackBin(_ data: Data) -> Data {
        var out = Data([0xc4, UInt8(data.count)])
        out.append(data)
        return out
    }

    /// Encode a UTF-8 string in msgpack format.
    private func encodeMsgpackString(_ s: String) -> Data {
        let utf8 = Array(s.utf8)
        var buf = Data()
        let len = utf8.count
        if len <= 31 {
            buf.append(UInt8(0xa0 | len))
        } else if len <= 0xFF {
            buf.append(0xd9)
            buf.append(UInt8(len))
        } else {
            buf.append(0xda)
            buf.append(UInt8((len >> 8) & 0xFF))
            buf.append(UInt8(len & 0xFF))
        }
        buf.append(contentsOf: utf8)
        return buf
    }
}
