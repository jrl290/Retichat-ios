//
//  RfedNotifyRegistrar.swift
//  Retichat
//
//  Registers this device's push-notification relay with rfed via a signed
//  plain DATA packet on the ephemeral `rfed.notify` AppLink.
//
//  Architecture:
//    iOS app ──APP_LINK DATA──▶ rfed.notify
//      payload: signed msgpack [op, relay_hex, channel_hash|nil]
//      success: Reticulum LRPROOF for that packet
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

    /// Last rfed.notify registration tuple successfully accepted during this
    /// app run. Failed sends must not latch success, or a later APP_LINK
    /// ACTIVE event would be unable to retry the same tuple.
    private var lastRegistrationKey: String? = nil
    private var pendingRegistrationKey: String? = nil
    private let stateQueue = DispatchQueue(label: "chat.retichat.rfednotify.state")

    private init() {}

    // MARK: - Public API

    /// Register this subscriber's relay hash with rfed.
    /// `identityHandle` is the Rust FFI handle for the local identity.
    ///
    /// The registration is a one-shot signed DATA send over the ephemeral
    /// `rfed.notify` AppLink. We fire one immediate attempt and leave an
    /// ACTIVE-status handler installed so a later readiness event can drive
    /// the same send without Swift owning link lifecycle or retries.
    /// NEVER REMOVE EVER — see DESIGN_PRINCIPLES.md §1
    @MainActor
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
        guard let payload = buildSignedPayload(
            operation: "register",
            relayHex: relayHex,
            channelHash: nil,
            identityHandle: identityHandle
        ) else {
            print("[RfedNotify] Failed to sign payload")
            return
        }

        let registrationKey = rfedDestHex + ":" + relayHex + ":" + String(identityHandle)
        guard shouldAttempt(registrationKey) else { return }

        ConnectionStateManager.shared.setAppLinkStatusHandler(destHash: rfedHash) { [weak self] status in
            guard status == 3 else { return }
            self?.attemptRegistrationIfNeeded(
                registrationKey,
                rfedHash: rfedHash,
                payload: payload,
                kind: "register"
            )
        }

        _ = ConnectionStateManager.shared.appLinkPrime(
            destHash: rfedHash,
            app: "rfed",
            aspects: ["notify"]
        )

        attemptRegistrationIfNeeded(
            registrationKey,
            rfedHash: rfedHash,
            payload: payload,
            kind: "register"
        )
    }

    /// Best-effort deregistration from a previous rfed node.
    /// Sends a single signed DATA packet over the ephemeral `rfed.notify`
    /// AppLink.
    func deregisterFrom(oldNotifyHashHex: String, identityHandle: UInt64) {
        guard !oldNotifyHashHex.isEmpty,
              let rfedHash = Data(hexString: oldNotifyHashHex) else { return }
        guard let relayHex = ApnsBridgeHashes.notifyRelayHex else { return }

        guard let payload = buildSignedPayload(
            operation: "unregister",
            relayHex: relayHex,
            channelHash: nil,
            identityHandle: identityHandle
        ) else { return }

        Task.detached(priority: .background) {
            let delivered = await ConnectionStateManager.shared.appLinkSendData(
                destHash: rfedHash,
                app: "rfed", aspects: ["notify"],
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
        guard let relayHex = ApnsBridgeHashes.notifyRelayHex else {
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
        Task.detached(priority: .background) { [weak self] in
            await self?.sendOnce(rfedHash: rfedHash,
                                 payload: payload, kind: "channel-register")
        }
    }

    /// Deregister this device from per-channel push notifications (best-effort, no retry).
    /// Call when the user leaves / unsubscribes from a channel.
    func deregisterForChannel(channelHash: Data, rfedNotifyHashHex: String, identityHandle: UInt64) {
        guard !rfedNotifyHashHex.isEmpty,
              let rfedHash = Data(hexString: rfedNotifyHashHex) else { return }
        guard let relayHex = ApnsBridgeHashes.notifyRelayHex else { return }
        guard let payload = buildSignedPayload(operation: "unregister",
                                               relayHex: relayHex,
                                               channelHash: channelHash,
                                               identityHandle: identityHandle) else { return }
        Task.detached(priority: .background) {
            let delivered = await ConnectionStateManager.shared.appLinkSendData(
                destHash: rfedHash,
                app: "rfed", aspects: ["notify"],
                payload: payload
            )
            if delivered {
                print("[RfedNotify] Delivered channel deregister (channel=\(channelHash.hexString.prefix(8))…)")
            }
        }
    }

    // MARK: - Private

    /// Single-attempt registration via a signed DATA send on the ephemeral
    /// `rfed.notify` AppLink.
    private func sendOnce(rfedHash: Data, payload: Data, kind: String) async -> Bool {
        let delivered = await ConnectionStateManager.shared.appLinkSendData(
            destHash: rfedHash,
            app: "rfed", aspects: ["notify"],
            payload: payload
        )

        if delivered {
            print("[RfedNotify] \(kind): delivered to rfed.notify")
            return true
        } else {
            print("[RfedNotify] \(kind): no delivery proof within budget — skipping")
            return false
        }
    }

    private func attemptRegistrationIfNeeded(_ key: String,
                                             rfedHash: Data,
                                             payload: Data,
                                             kind: String) {
        guard shouldAttempt(key) else { return }
        markPending(key)
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            let success = await self.sendOnce(
                rfedHash: rfedHash,
                payload: payload,
                kind: kind
            )
            if success {
                self.markRegistrationSucceeded(key)
            } else {
                self.clearPendingRegistration(key)
            }
        }
    }

    private func shouldAttempt(_ key: String) -> Bool {
        stateQueue.sync {
            lastRegistrationKey != key && pendingRegistrationKey != key
        }
    }

    private func markPending(_ key: String) {
        stateQueue.sync {
            pendingRegistrationKey = key
        }
    }

    private func clearPendingRegistration(_ key: String) {
        stateQueue.sync {
            if pendingRegistrationKey == key {
                pendingRegistrationKey = nil
            }
        }
    }

    private func markRegistrationSucceeded(_ key: String) {
        stateQueue.sync {
            lastRegistrationKey = key
            if pendingRegistrationKey == key {
                pendingRegistrationKey = nil
            }
        }
    }

    // MARK: - msgpack encoding

    /// Build the signed payload: fixarray-3 [bin(value), bin(64) pubkey, bin(64) sig]
    /// where value = msgpack fixarray-3 [str(op), str(relay_hex)|nil,
    /// bin(16 channel_hash)|nil].
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
