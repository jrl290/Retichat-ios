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

    /// Last rfed.notify registration tuple attempted during this app run.
    /// This suppresses reconnect storms for the same destination while still
    /// allowing re-registration when the RFed node or local identity changes.
    private var lastRegistrationKey: String? = nil

    private init() {}

    // MARK: - Public API

    /// Register this subscriber's relay hash with rfed.
    /// `identityHandle` is the Rust FFI handle for the local identity.
    ///
    /// RFed notify is an infrastructure request, not an AppLink. Send one
    /// request and surface failure; no persistent link, no retry loop.
    /// NEVER REMOVE EVER — see DESIGN_PRINCIPLES.md §1
    func registerIfNeeded(identityHandle: UInt64) {
        let rfedDestHex = prefs.effectiveRfedNotifyHash
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

        let registrationKey = rfedDestHex + ":" + relayHex + ":" + String(identityHandle)
        guard lastRegistrationKey != registrationKey else { return }
        lastRegistrationKey = registrationKey

        Task.detached(priority: .background) { [weak self] in
            await self?.sendOnce(
                rfedHash: rfedHash,
                payload: payload,
                kind: "register",
                identityHandle: identityHandle
            )
        }
    }

    /// Best-effort deregistration from a previous rfed node.
    /// Sends a single `/rfed/notify/unregister` infrastructure request.
    func deregisterFrom(oldNotifyHashHex: String, identityHandle: UInt64) {
        guard !oldNotifyHashHex.isEmpty,
              let rfedHash = Data(hexString: oldNotifyHashHex) else { return }
        guard let relayHex = ApnsBridgeHashes.notifyRelayHex else { return }

        guard let payload = buildSignedPayload(relayHex: relayHex, channelHash: nil, identityHandle: identityHandle) else { return }

        Task.detached(priority: .background) {
            let resp = await ConnectionStateManager.shared.rfedLinkRequest(
                destHash: rfedHash,
                app: "rfed", aspects: "notify",
                identityHandle: identityHandle,
                path: "/rfed/notify/unregister",
                payload: payload
            )
            if resp != nil {
                print("[RfedNotify] Sent unregister to old rfed node")
            } else {
                print("[RfedNotify] Unregister: no response within 5 s")
            }
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
            await self?.sendOnce(rfedHash: rfedHash,
                                 payload: payload, kind: "channel-register",
                                 identityHandle: identityHandle)
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
        Task.detached(priority: .background) {
            let resp = await ConnectionStateManager.shared.rfedLinkRequest(
                destHash: rfedHash,
                app: "rfed", aspects: "notify",
                identityHandle: identityHandle,
                path: "/rfed/notify/unregister",
                payload: payload
            )
            if resp != nil {
                print("[RfedNotify] Sent channel deregister (channel=\(channelHash.hexString.prefix(8))…)")
            }
        }
    }

    // MARK: - Private

    /// Single-attempt registration via an RFed infrastructure request.
    private func sendOnce(rfedHash: Data, payload: Data, kind: String, identityHandle: UInt64) async {
        // Outbound link needs the destination's identity (public key), not
        // just a cached path. On cold start the path table is loaded from
        // disk but the known-destinations table is empty until an announce
        // arrives. Issue a path request — PATH_RESPONSE is an announce and
        // will populate the identity on receipt.
        if !bridge.transportIdentityKnown(destHash: rfedHash) {
            _ = bridge.transportRequestPath(destHash: rfedHash)
        }
        let deadline = Date().addingTimeInterval(30.0)
        while Date() < deadline {
            if bridge.transportIdentityKnown(destHash: rfedHash) { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard bridge.transportIdentityKnown(destHash: rfedHash) else {
            print("[RfedNotify] \(kind): no identity for rfed.notify within 30 s — skipping")
            return
        }

        let response = await ConnectionStateManager.shared.rfedLinkRequest(
            destHash: rfedHash,
            app: "rfed", aspects: "notify",
            identityHandle: identityHandle,
            path: "/rfed/notify/register",
            payload: payload
        )

        if let resp = response {
            // Response should be msgpack bool (true = 0xc3).
            let success = resp.count == 1 && resp[0] == 0xc3
            if success {
                print("[RfedNotify] \(kind): registered with rfed")
            } else {
                print("[RfedNotify] \(kind): rfed returned false")
            }
        } else {
            print("[RfedNotify] \(kind): request failed or no response within 5 s — skipping")
        }
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
