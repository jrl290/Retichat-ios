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
        static let apnsRegistrationHex = "APNSRegistrationDestinationHash"
        static let notifyRelayHex = "APNSNotifyRelayDestinationHash"
    }

    private static let config: [String: String] = {
        guard let url = Bundle.main.url(forResource: "PushBridgeConfig", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url) as? [String: String] else {
            return [:]
        }
        return dict
    }()

    static var isConfigured: Bool {
        apnsRegistration != nil && notifyRelay != nil
    }

    static var apnsRegistrationHex: String? {
        validatedHex(for: Key.apnsRegistrationHex)
    }

    static var apnsRegistration: Data? {
        guard let hex = apnsRegistrationHex else { return nil }
        return Data(hexString: hex)
    }

    static var notifyRelayHex: String? {
        validatedHex(for: Key.notifyRelayHex)
    }

    static var notifyRelay: Data? {
        guard let hex = notifyRelayHex else { return nil }
        return Data(hexString: hex)
    }

    private static func validatedHex(for key: String) -> String? {
        guard let value = config[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.count == 32,
              value.allSatisfy({ "0123456789abcdefABCDEF".contains($0) }) else {
            return nil
        }
        return value.lowercased()
    }
}
