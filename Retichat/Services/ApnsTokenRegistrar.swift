//
//  ApnsTokenRegistrar.swift
//  Retichat
//
//  Registers this device's APNs token with the apns-bridge `apns.register`
//  destination.
//
//  Protocol payload (msgpack Map sent as APP_LINK DATA):
//    Payload: msgpack Map
//      register:   {"subscriber_hash": bin(16),
//                   "apns_token":      str(64 hex),
//                   "env":             str("sandbox" | "production")}
//
//  The `apns.register` destination hash is loaded from PushBridgeConfig.plist
//  when available (key `APNSRegistrationDestinationHash`). Without it, APNs
//  bridge registration is disabled.
//  Registration is attempted on service start and whenever the APNs token
//  changes. The send rides AppLinks' DATA path so Rust owns path readiness,
//  link establishment, and delivery proof handling.
//

import Foundation
import CryptoKit

final class ApnsTokenRegistrar {
    static let shared = ApnsTokenRegistrar()

    private let prefs  = UserPreferences.shared

    /// One per `apns.register` destination (it changes with the bridge config).
    @MainActor private var registrations: [String: HeldLinkRegistrations] = [:]

    private init() {}

    // MARK: - Public API

    /// Call after service starts (and identity is known) whenever the APNs token
    /// or the `apns.register` hash changes.
    ///
    /// Owes the bridge this device's token: it is sent on a held link to
    /// `apns.register` once that link is established, with its delivery
    /// proof, and owed until then (see `HeldLinkRegistrations`). A token
    /// already registered in this app run is not sent again.
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

        // The token itself stays out of the key, which is logged.
        let tokenTag = SHA256.hash(data: Data(apnsToken.utf8)).prefix(4)
            .map { String(format: "%02x", $0) }.joined()
        let key = "token \(subscriberHash.hexString.prefix(8))/\(tokenTag)/\(Self.currentApsEnvironment())"
        Task { @MainActor in
            let registration = self.registrations[destHash.hexString] ?? {
                let created = HeldLinkRegistrations(destHash: destHash, app: "apns", aspects: ["register"],
                                                    ops: LiveHeldLinkOps.shared)
                self.registrations[destHash.hexString] = created
                return created
            }()
            registration.owe(key: key, payload: payload)
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


