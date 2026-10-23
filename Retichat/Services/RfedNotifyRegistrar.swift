//
//  RfedNotifyRegistrar.swift
//  Retichat
//
//  Registers this device's push-notification relay with rfed: a signed
//  request on the node's rfed.link (RFed-spec Link.md; RfedLink.swift).
//
//  Architecture:
//    iOS app ──request──▶ rfed.link /notify/register | /notify/unregister
//      payload: signed msgpack [op, relay_hex, channel_hash|nil]
//               (byte-identical to the old rfed.notify.* DATA packets)
//      success: the answer true
//
//  Until 2026-10-18 these went as DATA on rfed.notify.register and
//  rfed.notify.unregister, a link each.
//
//  The relay hash (apns-bridge's `apns.relay` destination) is loaded from
//  PushBridgeConfig.plist via `ApnsBridgeHashes.effectiveRelayHex`.
//

import Foundation

final class RfedNotifyRegistrar {
    static let shared = RfedNotifyRegistrar()

    private let bridge = RetichatBridge.shared
    private let prefs  = UserPreferences.shared

    /// One per RFed node (it changes with the node's identity in Settings).
    @MainActor private var registrations: [String: HeldLinkRegistrations] = [:]

    private init() {}

    /// The registrations owed to `nodeHex`, nil for a bad node hash.
    @MainActor
    private func registrations(forNode nodeHex: String) -> HeldLinkRegistrations? {
        let node = nodeHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let existing = registrations[node] { return existing }
        guard let dest = RfedLink.destHash(nodeHex: node) else { return nil }
        let created = HeldLinkRegistrations(destHash: dest, app: "rfed", aspects: ["link"],
                                            ops: RfedLinkHeldOps(nodeHex: node, path: "/notify/register"))
        registrations[node] = created
        return created
    }

    /// One unregister on `nodeHex`'s rfed.link. True when rfed answered true.
    @MainActor
    private func unregisterOnce(nodeHex: String, payload: Data) async -> Bool {
        await RfedLink.shared.request(nodeHex: nodeHex, path: "/notify/unregister", payload: payload) == Data([0xc3])
    }

    private static func channelKey(_ channelHash: Data, relayHex: String, identityHandle: UInt64) -> String {
        "channel \(channelHash.hexString.prefix(8)) relay=\(relayHex.prefix(8)) identity=\(identityHandle)"
    }

    // MARK: - Public API

    /// Register this subscriber's relay hash with rfed.
    /// `identityHandle` is the Rust FFI handle for the local identity.
    ///
    /// Owed to the node: sent on its rfed.link once it is established, with
    /// rfed's answer as the proof, and owed until then (see
    /// `HeldLinkRegistrations`). Already registered in this run: not sent.
    @MainActor
    func registerIfNeeded(identityHandle: UInt64) {
        let node = prefs.effectiveRfedNodeIdentityHash
        guard !node.isEmpty else { return }
        guard let registrations = registrations(forNode: node) else {
            print("[RfedNotify] Invalid RFed node identity hash — not 32 hex chars")
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
        registrations.owe(key: key, payload: payload)
    }

    // MARK: - Mesh wake (MeshWake.swift)

    private static func meshKey(_ relayHex: String, identityHandle: UInt64) -> String {
        "lxmf mesh relay=\(relayHex.prefix(8)) identity=\(identityHandle)"
    }

    /// Register this device's own relay (`rfed.notify` under its identity)
    /// for its LXMF wakes, beside the push bridge's: RFed wakes every relay a
    /// device registered, so this one gets the wake over the mesh. Owed to
    /// the node like the push relay's registration.
    @MainActor
    func registerMeshRelay(relayHex: String, identityHandle: UInt64) {
        let node = prefs.effectiveRfedNodeIdentityHash
        guard !node.isEmpty, let registrations = registrations(forNode: node) else { return }
        guard let payload = buildSignedPayload(operation: "register", relayHex: relayHex,
                                               channelHash: nil, identityHandle: identityHandle) else {
            print("[RfedNotify] Failed to sign the mesh relay payload")
            return
        }
        registrations.owe(key: Self.meshKey(relayHex, identityHandle: identityHandle), payload: payload)
    }

    /// One per RFed node: the mesh relay's unregistration, owed like a
    /// registration (sent on the established rfed.link, proved by rfed's true).
    @MainActor private var meshUnregistrations: [String: HeldLinkRegistrations] = [:]

    /// Unregister the mesh relay from the current node (no Bluetooth radio
    /// is configured any more), owed until rfed answers true; then it is
    /// forgotten (`UserPreferences.meshWakeRelayHex`).
    @MainActor
    func unregisterMeshRelay(relayHex: String, identityHandle: UInt64) {
        let node = prefs.effectiveRfedNodeIdentityHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let dest = RfedLink.destHash(nodeHex: node),
              let payload = buildSignedPayload(operation: "unregister", relayHex: relayHex,
                                               channelHash: nil, identityHandle: identityHandle) else { return }
        let key = Self.meshKey(relayHex, identityHandle: identityHandle)
        registrations(forNode: node)?.forget(key: key)
        let prefs = self.prefs
        let unregistrations = meshUnregistrations[node] ?? HeldLinkRegistrations(
            destHash: dest, app: "rfed", aspects: ["link"],
            ops: ProvedOps(RfedLinkHeldOps(nodeHex: node, path: "/notify/unregister")) {
                if prefs.meshWakeRelayHex == relayHex { prefs.meshWakeRelayHex = nil }
            })
        meshUnregistrations[node] = unregistrations
        unregistrations.owe(key: key, payload: payload)
    }

    /// `HeldLinkOps` that also runs `proved` when a send is proved.
    @MainActor
    private final class ProvedOps: HeldLinkOps {
        private let ops: HeldLinkOps
        private let proved: () -> Void
        init(_ ops: HeldLinkOps, proved: @escaping () -> Void) { self.ops = ops; self.proved = proved }
        func status(_ destHash: Data) -> Int32 { ops.status(destHash) }
        func openHeld(_ destHash: Data, app: String, aspects: [String]) { ops.openHeld(destHash, app: app, aspects: aspects) }
        func close(_ destHash: Data) { ops.close(destHash) }
        func setStatusHandler(_ destHash: Data, _ handler: @escaping (UInt8) -> Void) { ops.setStatusHandler(destHash, handler) }
        func sendData(_ destHash: Data, app: String, aspects: [String], payload: Data) async -> Bool {
            let ok = await ops.sendData(destHash, app: app, aspects: aspects, payload: payload)
            if ok { proved() }
            return ok
        }
    }

    /// Best-effort deregistration from a previous rfed node: one signed
    /// `/notify/unregister` request on `oldRfedIdentityHashHex`'s rfed.link,
    /// and one for the mesh relay when one is registered (the next start
    /// registers it with the new node).
    func deregisterFrom(oldRfedIdentityHashHex: String, identityHandle: UInt64) {
        let trimmed = oldRfedIdentityHashHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, RfedLink.destHash(nodeHex: trimmed) != nil else { return }
        if let meshRelayHex = prefs.meshWakeRelayHex,
           let payload = buildSignedPayload(operation: "unregister", relayHex: meshRelayHex,
                                            channelHash: nil, identityHandle: identityHandle) {
            Task { @MainActor in
                _ = await self.unregisterOnce(nodeHex: trimmed, payload: payload)
            }
        }
        guard let relayHex = ApnsBridgeHashes.effectiveRelayHex else { return }

        guard let payload = buildSignedPayload(
            operation: "unregister",
            relayHex: relayHex,
            channelHash: nil,
            identityHandle: identityHandle
        ) else { return }

        Task { @MainActor in
            if await self.unregisterOnce(nodeHex: trimmed, payload: payload) {
                print("[RfedNotify] Delivered unregister to old rfed node")
            } else {
                print("[RfedNotify] Unregister: rfed did not answer true within budget")
            }
        }
    }

    /// Register for per-channel push notification wakeups.
    /// Sends `[relay_hex, channel_hash_bin16]` as the value so the rfed node
    /// wakes this device when a message arrives on that specific channel.
    func registerForChannel(channelHash: Data, nodeHex: String, identityHandle: UInt64) {
        guard !nodeHex.isEmpty, RfedLink.destHash(nodeHex: nodeHex) != nil else { return }
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
            self.registrations(forNode: nodeHex)?.owe(key: key, payload: payload)
        }
    }

    /// Deregister this device from per-channel push notifications (best-effort, no retry).
    /// Call when the user leaves / unsubscribes from a channel.
    func deregisterForChannel(channelHash: Data, nodeHex: String, identityHandle: UInt64) {
        guard !nodeHex.isEmpty, RfedLink.destHash(nodeHex: nodeHex) != nil else { return }
        guard let relayHex = ApnsBridgeHashes.effectiveRelayHex else { return }
        guard let payload = buildSignedPayload(operation: "unregister",
                                               relayHex: relayHex,
                                               channelHash: channelHash,
                                               identityHandle: identityHandle) else { return }
        // A registration still owed must not go out after this.
        let key = Self.channelKey(channelHash, relayHex: relayHex, identityHandle: identityHandle)
        Task { @MainActor in
            self.registrations(forNode: nodeHex)?.forget(key: key)
            if await self.unregisterOnce(nodeHex: nodeHex, payload: payload) {
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
