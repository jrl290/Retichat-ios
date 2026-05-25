//
//  ApnsBridgeHashes.swift
//  Retichat
//
//  Optional destination hashes for the APNs push bridge, loaded from a
//  local PushBridgeConfig.plist bundled only in private/release builds.
//

import Foundation

enum ApnsBridgeHashes {
    private enum Key {
        /// Hash of the apns-bridge `apns.register` destination.
        static let apnsRegistrationHex = "APNSRegistrationDestinationHash"
        /// Hash of the apns-bridge `apns.relay` destination.
        static let apnsRelayHex = "APNSRelayDestinationHash"
    }

    private static let config: [String: String] = {
        guard let url = Bundle.main.url(forResource: "PushBridgeConfig", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url) as? [String: String] else {
            return [:]
        }
        return dict
    }()

    static var isConfigured: Bool {
        apnsRegistration != nil && apnsRelay != nil
    }

    static var apnsRegistrationHex: String? {
        validatedHex(for: Key.apnsRegistrationHex)
    }

    static var apnsRegistration: Data? {
        guard let hex = apnsRegistrationHex else { return nil }
        return Data(hexString: hex)
    }

    /// `apns.relay` destination hash.
    static var apnsRelayHex: String? {
        validatedHex(for: Key.apnsRelayHex)
    }

    static var apnsRelay: Data? {
        guard let hex = apnsRelayHex else { return nil }
        return Data(hexString: hex)
    }

    /// Relay-target hash for outbound wake traffic from this device.
    /// Kept as a named accessor (in addition to `apnsRelayHex`) so call
    /// sites read intent — "where do I aim the wake packet" — rather than
    /// a raw plist key.
    static var effectiveRelayHex: String? { apnsRelayHex }
    static var effectiveRelay: Data?      { apnsRelay }

    private static func validatedHex(for key: String) -> String? {
        guard let value = config[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.count == 32,
              value.allSatisfy({ "0123456789abcdefABCDEF".contains($0) }) else {
            return nil
        }
        return value.lowercased()
    }
}
