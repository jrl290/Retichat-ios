//
//  RfedNotifyRegistrar.swift
//  Retichat
//
//  Registers this device's push-notification relay with rfed via a signed
//  plain DATA packet on the ephemeral `rfed.notify.register` /
//  `rfed.notify.unregister` AppLinks (split per REFACTOR.md step 1).
//
//  Architecture:
//    iOS app ──APP_LINK DATA──▶ rfed.notify.{register|unregister}
//      payload: signed msgpack [op, relay_hex, channel_hash|nil]
//      success: Reticulum LRPROOF for that packet
//
//  Required UserPreferences:
//    rfedNotifyHash  — rfed's rfed.notify.register destination hash
//                       (UI status probe; the unregister hash is derived
//                        on demand from the rfed identity hash).
//
//  The relay hash (apns-bridge's `apns.relay` destination) is loaded from
//  PushBridgeConfig.plist via `ApnsBridgeHashes.effectiveRelayHex`.
//

import Foundation

final class RfedNotifyRegistrar {
    static let shared = RfedNotifyRegistrar()

    private let bridge = RetichatBridge.shared
    private let prefs  = UserPreferences.shared

    /// One per `rfed.notify.register` destination (it changes with the node).
    @MainActor private var registrations: [String: HeldLinkRegistrations] = [:]

    private init() {}

    @MainActor
    private func registrations(for rfedHash: Data) -> HeldLinkRegistrations {
        if let existing = registrations[rfedHash.hexString] { return existing }
        let created = HeldLinkRegistrations(destHash: rfedHash, app: "rfed", aspects: ["notify", "register"],
                                            ops: LiveHeldLinkOps.shared)
        registrations[rfedHash.hexString] = created
        return created
    }

    private static func channelKey(_ channelHash: Data, relayHex: String, identityHandle: UInt64) -> String {
        "channel \(channelHash.hexString.prefix(8)) relay=\(relayHex.prefix(8)) identity=\(identityHandle)"
    }

    // MARK: - Public API

    /// Register this subscriber's relay hash with rfed.
    /// `identityHandle` is the Rust FFI handle for the local identity.
    ///
    /// Owed to the node: sent on a held link to `rfed.notify.register` once
    /// it is established, with its delivery proof, and owed until then (see
    /// `HeldLinkRegistrations`). Already registered in this run: not sent.
    @MainActor
    func registerIfNeeded(identityHandle: UInt64) {
        let rfedDestHex = prefs.effectiveRfedNotifyHash
        guard !rfedDestHex.isEmpty else { return }
        guard let rfedHash = Data(hexString: rfedDestHex) else {
            print("[RfedNotify] Invalid rfedNotifyHash — not 32 hex chars")
            return
        }
        guard let relayHex = ApnsBridgeHashes.effectiveRelayHex else {
            print("[RfedNotify] PushBridgeConfig.plist missing or invalid; skipping relay registration")
            return
        }

        // Payload: fixarray-3 [str(relayHex), bin(64) pubkey, bin(64) sig_over_utf8(relayHex)]
        // Subscriber identity is derived from pubkey on the server — no timing dependency.
        guard let payload = buildSignedPayload(
            operation: "register",
            relayHex: relayHex,
            channelHash: nil,
            identityHandle: identityHandle
        ) else {
            print("[RfedNotify] Failed to sign payload")
            return
        }

        let key = "lxmf relay=\(relayHex.prefix(8)) identity=\(identityHandle)"
        registrations(for: rfedHash).owe(key: key, payload: payload)
    }

    /// Best-effort deregistration from a previous rfed node.
    /// Sends a single signed DATA packet over the ephemeral
    /// `rfed.notify.unregister` AppLink derived from `oldRfedIdentityHashHex`.
    func deregisterFrom(oldRfedIdentityHashHex: String, identityHandle: UInt64) {
        let trimmed = oldRfedIdentityHashHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let unregisterHex = RfedChannelClient.rfedDestHash(
            identityHashHex: trimmed, app: "rfed", aspects: ["notify", "unregister"])
        guard !unregisterHex.isEmpty,
              let rfedHash = Data(hexString: unregisterHex) else { return }
        guard let relayHex = ApnsBridgeHashes.effectiveRelayHex else { return }

        guard let payload = buildSignedPayload(
            operation: "unregister",
            relayHex: relayHex,
            channelHash: nil,
            identityHandle: identityHandle
        ) else { return }

        Task.detached(priority: .background) {
            let delivered = await ConnectionStateManager.shared.appLinkSendData(
                destHash: rfedHash,
                app: "rfed", aspects: ["notify", "unregister"],
                payload: payload
            )
            if delivered {
                print("[RfedNotify] Delivered unregister to old rfed node")
            } else {
                print("[RfedNotify] Unregister: no delivery proof within budget")
            }
        }
    }

    /// Register for per-channel push notification wakeups.
    /// Sends `[relay_hex, channel_hash_bin16]` as the value so the rfed node
    /// wakes this device when a message arrives on that specific channel.
    func registerForChannel(channelHash: Data, rfedNotifyHashHex: String, identityHandle: UInt64) {
        guard !rfedNotifyHashHex.isEmpty,
              let rfedHash = Data(hexString: rfedNotifyHashHex) else { return }
        guard let relayHex = ApnsBridgeHashes.effectiveRelayHex else {
            print("[RfedNotify] PushBridgeConfig.plist missing — skipping channel notify registration")
            return
        }
        guard let payload = buildSignedPayload(operation: "register",
                                               relayHex: relayHex,
                                               channelHash: channelHash,
                                               identityHandle: identityHandle) else {
            print("[RfedNotify] Failed to sign channel notify payload")
            return
        }
        let key = Self.channelKey(channelHash, relayHex: relayHex, identityHandle: identityHandle)
        Task { @MainActor in
            self.registrations(for: rfedHash).owe(key: key, payload: payload)
        }
    }

    /// Deregister this device from per-channel push notifications (best-effort, no retry).
    /// Call when the user leaves / unsubscribes from a channel.
    func deregisterForChannel(channelHash: Data, rfedNotifyHashHex: String, identityHandle: UInt64) {
        // `rfedNotifyHashHex` is the register-op hash; derive the unregister
        // hash by re-routing through the rfed identity. Pulling it from the
        // register hex is not reversible.
        let identityHex = prefs.effectiveRfedNodeIdentityHash
        let unregisterHex = RfedChannelClient.rfedDestHash(
            identityHashHex: identityHex, app: "rfed", aspects: ["notify", "unregister"])
        guard !unregisterHex.isEmpty,
              let rfedHash = Data(hexString: unregisterHex) else { return }
        guard let relayHex = ApnsBridgeHashes.effectiveRelayHex else { return }
        guard let payload = buildSignedPayload(operation: "unregister",
                                               relayHex: relayHex,
                                               channelHash: channelHash,
                                               identityHandle: identityHandle) else { return }
        // A registration still owed must not go out after this.
        if let registerHash = Data(hexString: rfedNotifyHashHex) {
            let key = Self.channelKey(channelHash, relayHex: relayHex, identityHandle: identityHandle)
            Task { @MainActor in self.registrations(for: registerHash).forget(key: key) }
        }
        Task.detached(priority: .background) {
            let delivered = await ConnectionStateManager.shared.appLinkSendData(
                destHash: rfedHash,
                app: "rfed", aspects: ["notify", "unregister"],
                payload: payload
            )
            if delivered {
                print("[RfedNotify] Delivered channel deregister (channel=\(channelHash.hexString.prefix(8))…)")
            }
        }
    }

    // MARK: - Private

    private func buildSignedPayload(operation: String,
                                    relayHex: String?,
                                    channelHash: Data?,
                                    identityHandle: UInt64) -> Data? {
        // Value: msgpack fixarray-3 [str(op), str(relay_hex)|nil, bin(16 channel_hash)|nil]
        var value = Data([0x93])                    // fixarray of 3
        value.append(encodeMsgpackString(operation))
        if let relayHex {
            value.append(encodeMsgpackString(relayHex))
        } else {
            value.append(0xc0)
        }
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
