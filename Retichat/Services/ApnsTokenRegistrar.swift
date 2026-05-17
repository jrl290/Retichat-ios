//
//  ApnsTokenRegistrar.swift
//  Retichat
//
//  Registers this device's APNs token with the rfed APNs bridge (rfed.apns).
//
//  Protocol payload (msgpack Map sent as APP_LINK DATA):
//    Payload: msgpack Map
//      register:   {"subscriber_hash": bin(16),
//                   "apns_token":      str(64 hex),
//                   "env":             str("sandbox" | "production")}
//      unregister: {"subscriber_hash": bin(16)}
//
//  The rfed.apns destination hash is loaded from PushBridgeConfig.plist when
//  available. Without it, APNs bridge registration is disabled.
//  Registration is attempted on service start and whenever the APNs token
//  changes. We intentionally keep the client on AppLinks Ephemeral mode here:
//  reliability and delivery proof matter more than single-packet minimization,
//  while APNs token registration volume is low enough that holding a
//  persistent link open is not required. Rust owns path readiness, link
//  establishment, and delivery proof handling.
//

import Foundation

final class ApnsTokenRegistrar {
    static let shared = ApnsTokenRegistrar()

    private let prefs  = UserPreferences.shared

    /// Last APNs registration tuple successfully accepted during this app run.
    /// Failed sends must not latch success, or a later APP_LINK ACTIVE event
    /// would be unable to retry the same tuple.
    private var lastRegistrationKey: String? = nil
    private var pendingRegistrationKey: String? = nil
    private let stateQueue = DispatchQueue(label: "chat.retichat.apns.state")

    private init() {}

    // MARK: - Public API

    /// Call after service starts (and identity is known) whenever the APNs token
    /// or the rfed.apns hash changes.
    ///
    /// The registration is a one-shot DATA send via the ephemeral `rfed.apns`
    /// AppLink. This deliberately favors proof-backed infrastructure delivery
    /// over raw packet minimization. We fire one immediate attempt and leave an
    /// ACTIVE-status handler installed so a later readiness event can drive the
    /// same send without Swift owning path polling or retry timing.
    /// NEVER REMOVE EVER — see DESIGN_PRINCIPLES.md §1
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
        guard shouldAttempt(registrationKey) else { return }

        ConnectionStateManager.shared.setAppLinkStatusHandler(destHash: destHash) { [weak self] status in
            guard status == 3 else { return }
            self?.attemptRegistrationIfNeeded(
                registrationKey,
                destHash: destHash,
                payload: payload,
                subscriberHashHex: subscriberHash.hexString
            )
        }

        _ = ConnectionStateManager.shared.appLinkPrime(
            destHash: destHash,
            app: "rfed",
            aspects: ["apns"]
        )

        attemptRegistrationIfNeeded(
            registrationKey,
            destHash: destHash,
            payload: payload,
            subscriberHashHex: subscriberHash.hexString
        )
    }

    // MARK: - Private

    /// Single-attempt registration via a plain DATA send on the ephemeral
    /// `rfed.apns` AppLink.
    private func sendOnce(destHash: Data,
                          payload: Data,
                          subscriberHashHex: String) async -> Bool {
        let delivered = await ConnectionStateManager.shared.appLinkSendData(
            destHash: destHash,
            app: "rfed",
            aspects: ["apns"],
            payload: payload
        )

        if delivered {
            print("[APNsRegistrar] Token registered for \(subscriberHashHex.prefix(8))…")
            return true
        } else {
            print("[APNsRegistrar] Registration: no delivery proof within budget")
            return false
        }
    }

    private func attemptRegistrationIfNeeded(_ key: String,
                                             destHash: Data,
                                             payload: Data,
                                             subscriberHashHex: String) {
        guard shouldAttempt(key) else { return }
        markPending(key)
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            let success = await self.sendOnce(
                destHash: destHash,
                payload: payload,
                subscriberHashHex: subscriberHashHex
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
        // The `SecTask*` APIs aren't available in the public iOS / Mac
        // Catalyst SDK, so instead we parse `embedded.mobileprovision`
        // (present in development, ad-hoc, enterprise, and TestFlight
        // builds). The provisioning profile carries the same
        // `aps-environment` value Apple uses to bind the device token to a
        // specific APNs gateway.
        //
        // App Store distribution builds ship without an embedded profile;
        // those are always production.
        if let url = Bundle.main.url(forResource: "embedded",
                                     withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url),
           let env = parseApsEnvironment(fromMobileProvision: data) {
            if env == "development" { return "sandbox" }
            if env == "production"  { return "production" }
        }
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    /// Extracts the `aps-environment` value from a CMS-wrapped
    /// `embedded.mobileprovision` blob without needing the Security
    /// framework's CMS decoder.  The signed blob contains a plain XML plist
    /// between the literal markers `<?xml` … `</plist>`; we slice that out
    /// and feed it to PropertyListSerialization.
    private static func parseApsEnvironment(fromMobileProvision data: Data) -> String? {
        guard
            let openRange  = data.range(of: Data("<?xml".utf8)),
            let closeRange = data.range(
                of: Data("</plist>".utf8),
                options: [],
                in: openRange.upperBound..<data.endIndex
            )
        else { return nil }

        let plistData = data.subdata(in: openRange.lowerBound..<closeRange.upperBound)
        guard
            let plist = try? PropertyListSerialization.propertyList(
                from: plistData, options: [], format: nil
            ) as? [String: Any],
            let entitlements = plist["Entitlements"] as? [String: Any],
            let env = entitlements["aps-environment"] as? String
        else { return nil }
        return env
    }

    private enum RegistrarError: Error {
        case badSubscriberHash
        case badApnsToken
        case badEnv
    }
}


