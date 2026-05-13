//
//  ApnsTokenRegistrar.swift
//  Retichat
//
//  Registers this device's APNs token with the rfed APNs bridge (rfed.apns).
//
//  Protocol (plain encrypted RNS packet):
//    Payload: msgpack Map
//      register:   {"subscriber_hash": bin(16),
//                   "apns_token":      str(64 hex),
//                   "env":             str("sandbox" | "production")}
//      unregister: {"subscriber_hash": bin(16)}
//
//  The rfed.apns destination hash is loaded from PushBridgeConfig.plist when
//  available. Without it, APNs bridge registration is disabled.
//  Registration is attempted on service start and whenever the APNs token
//  changes.  Retried with exponential backoff if the path is not yet known.
//

import Foundation
import Security

final class ApnsTokenRegistrar {
    static let shared = ApnsTokenRegistrar()

    private let bridge = RetichatBridge.shared
    private let prefs  = UserPreferences.shared

    /// Last token-registration input tuple attempted during this app run.
    /// Prevents duplicate sends for the same subscriber/token pair while still
    /// allowing a real APNs token change to trigger a fresh registration.
    private var lastRegistrationKey: String? = nil

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
        guard !prefs.effectiveRfedNodeIdentityHash.isEmpty else {
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
                apnsToken: apnsToken,
                env: Self.currentApsEnvironment()
            )
        } catch {
            print("[APNsRegistrar] msgpack encode error: \(error)")
            return
        }

        let registrationKey = subscriberHash.hexString + ":" + apnsToken
                              + ":" + Self.currentApsEnvironment()
        guard lastRegistrationKey != registrationKey else { return }
        lastRegistrationKey = registrationKey

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
        // Outbound encrypted send needs the bridge's identity, not just a
        // cached path. A path can survive across launches via the on-disk
        // path table while the identity has not yet been re-cached this
        // session. Issue a path request whenever identity is missing —
        // PATH_RESPONSE is an announce and will populate the
        // known-destinations table on receipt.
        if !bridge.transportIdentityKnown(destHash: destHash) {
            _ = bridge.transportRequestPath(destHash: destHash)
        }

        // Wait up to 30 s for identity. 200 ms tick keeps wakeups cheap.
        let deadline = Date().addingTimeInterval(30.0)
        while Date() < deadline {
            if bridge.transportIdentityKnown(destHash: destHash) { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard bridge.transportIdentityKnown(destHash: destHash) else {
            print("[APNsRegistrar] No identity for rfed.apns within 30 s — will retry on next app start")
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
    // Encodes: fixmap(3) {
    //   "subscriber_hash" => bin8(16 bytes)
    //   "apns_token"      => str(64 chars)
    //   "env"             => str("sandbox" | "production")
    // }
    //
    // The `env` field tells the bridge which APNs gateway issued the token.
    // Tokens are gateway-scoped: a sandbox token sent through the production
    // gateway returns BadDeviceToken (and vice-versa).  Xcode rewrites the
    // signed `aps-environment` entitlement based on the provisioning profile
    // (development → "development" → sandbox APNs; distribution → "production"
    // → prod APNs), so reading the *runtime* entitlement is the source of
    // truth — not the static value baked into the .entitlements file.

    private func encodeMsgpackRegistration(subscriberHash: Data,
                                            apnsToken: String,
                                            env: String) throws -> Data {
        guard subscriberHash.count == 16 else {
            throw RegistrarError.badSubscriberHash
        }
        guard apnsToken.count == 64,
              apnsToken.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw RegistrarError.badApnsToken
        }
        guard env == "sandbox" || env == "production" else {
            throw RegistrarError.badEnv
        }

        var buf = Data()

        // fixmap, 3 entries
        buf.append(0x83)

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

        // key: "env" (3 bytes) → fixstr
        let key3 = "env"
        buf.append(UInt8(0xa0 | key3.utf8.count))
        buf.append(contentsOf: key3.utf8)
        // value: fixstr (env is always ≤ 31 chars: "sandbox" or "production")
        let envBytes = Array(env.utf8)
        buf.append(UInt8(0xa0 | envBytes.count))
        buf.append(contentsOf: envBytes)

        return buf
    }

    /// Returns "sandbox" or "production" based on the runtime
    /// `aps-environment` entitlement embedded in this code-signed binary.
    /// Falls back to `#if DEBUG` heuristic if the entitlement cannot be read.
    static func currentApsEnvironment() -> String {
        // SecTaskCopyValueForEntitlement reads the entitlement that was
        // actually baked into the signed binary (not the source .entitlements
        // file), which is the same value Apple uses to choose which APNs
        // gateway to bind the device token to.
        if let task = SecTaskCreateFromSelf(nil) {
            let key = "aps-environment" as CFString
            if let value = SecTaskCopyValueForEntitlement(task, key, nil) {
                if let s = value as? String {
                    if s == "development" { return "sandbox" }
                    if s == "production"  { return "production" }
                }
            }
        }
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    private enum RegistrarError: Error {
        case badSubscriberHash
        case badApnsToken
        case badEnv
    }
}


