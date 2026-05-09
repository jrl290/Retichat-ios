//
//  ApnsTokenRegistrar.swift
//  Retichat
//
//  Registers this device's APNs token with the rfed APNs bridge (rfed.apns).
//
//  Protocol (plain encrypted RNS packet):
//    Payload: msgpack Map
//      register:   {"subscriber_hash": bin(16), "apns_token": str(64 hex)}
//      unregister: {"subscriber_hash": bin(16)}
//
//  The rfed.apns destination hash is loaded from PushBridgeConfig.plist when
//  available. Without it, APNs bridge registration is disabled.
//  Registration is attempted on service start and whenever the APNs token
//  changes.  Retried with exponential backoff if the path is not yet known.
//

import Foundation

final class ApnsTokenRegistrar {
    static let shared = ApnsTokenRegistrar()

    private let bridge = RetichatBridge.shared
    private let prefs  = UserPreferences.shared

    /// One-shot guard so multiple registerIfNeeded() calls (token refresh,
    /// service restart, etc.) don't queue up redundant sends per app run.
    /// Reset only on explicit re-registration request.
    private var didRegister = false

    private init() {}

    // MARK: - Public API

    /// Call after service starts (and identity is known) whenever the APNs token
    /// or the rfed.apns hash changes.
    ///
    /// rfed.apns is a packet endpoint (no link). We poll path availability
    /// with a short tick: the path is requested at
    /// startup and arrives with the first matching announce (typically 1–15 s).
    /// We wait up to 30 s, send once, and log loudly if the window elapses.
    func registerIfNeeded(subscriberHash: Data) {
        guard !didRegister else { return }
        guard !prefs.rfedNodeIdentityHash.isEmpty else {
            print("[APNsRegistrar] No RFed node configured; skipping APNs registration")
            return
        }
        let apnsToken = prefs.apnsDeviceToken
        guard !apnsToken.isEmpty else { return }
        guard let destHash = ApnsBridgeHashes.apnsRegistration else {
            print("[APNsRegistrar] PushBridgeConfig.plist missing or invalid; skipping APNs registration")
            return
        }

        let payload: Data
        do {
            payload = try encodeMsgpackRegistration(
                subscriberHash: subscriberHash,
                apnsToken: apnsToken
            )
        } catch {
            print("[APNsRegistrar] msgpack encode error: \(error)")
            return
        }

        didRegister = true
        Task.detached(priority: .background) { [weak self] in
            await self?.awaitPathThenSend(
                destHash: destHash, payload: payload,
                subscriberHashHex: subscriberHash.hexString
            )
        }
    }

    // MARK: - Private

    /// Poll path availability up to 30 s, then send once.
    private func awaitPathThenSend(destHash: Data, payload: Data,
                                   subscriberHashHex: String) async {
        // Kick a path request immediately if we don't have one yet.
        if !bridge.transportHasPath(destHash: destHash) {
            _ = bridge.transportRequestPath(destHash: destHash)
        }

        // Wait up to 30 s for path. 200 ms tick keeps wakeups cheap.
        let deadline = Date().addingTimeInterval(30.0)
        while Date() < deadline {
            if bridge.transportHasPath(destHash: destHash) { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard bridge.transportHasPath(destHash: destHash) else {
            print("[APNsRegistrar] No path to rfed.apns within 30 s — will retry on next app start")
            return
        }

        let ok = bridge.packetSendToHash(
            destHash: destHash,
            appName:  "rfed",
            aspects:  "apns",
            payload:  payload
        )
        if ok {
            print("[APNsRegistrar] Token registered for \(subscriberHashHex.prefix(8))…")
        } else {
            let err = bridge.lastError() ?? "unknown"
            print("[APNsRegistrar] Send failed: \(err)")
        }
    }

    // MARK: - msgpack encoding (hand-rolled, no library needed)
    //
    // Encodes: fixmap(2) {
    //   "subscriber_hash" => bin8(16 bytes)
    //   "apns_token"      => str(64 chars)
    // }

    private func encodeMsgpackRegistration(subscriberHash: Data,
                                            apnsToken: String) throws -> Data {
        guard subscriberHash.count == 16 else {
            throw RegistrarError.badSubscriberHash
        }
        guard apnsToken.count == 64,
              apnsToken.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw RegistrarError.badApnsToken
        }

        var buf = Data()

        // fixmap, 2 entries
        buf.append(0x82)

        // key: "subscriber_hash" (15 bytes) → fixstr
        let key1 = "subscriber_hash"
        buf.append(UInt8(0xa0 | key1.utf8.count))
        buf.append(contentsOf: key1.utf8)
        // value: bin8, 16 bytes
        buf.append(0xc4)
        buf.append(UInt8(subscriberHash.count))
        buf.append(contentsOf: subscriberHash)

        // key: "apns_token" (10 bytes) → fixstr
        let key2 = "apns_token"
        buf.append(UInt8(0xa0 | key2.utf8.count))
        buf.append(contentsOf: key2.utf8)
        // value: str8, 64 bytes
        buf.append(0xd9)
        buf.append(UInt8(apnsToken.utf8.count))
        buf.append(contentsOf: apnsToken.utf8)

        return buf
    }

    private enum RegistrarError: Error {
        case badSubscriberHash
        case badApnsToken
    }
}


