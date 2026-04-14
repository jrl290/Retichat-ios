//
//  ApnsBridgeHashes.swift
//  Retichat
//
//  Hardcoded destination hashes for the APNs push bridge.
//  These are derived from the bridge's Reticulum identity and do not change
//  unless the bridge's identity key (~/.rfed-apns/identity) is regenerated.
//

import Foundation

enum ApnsBridgeHashes {
    /// rfed.apns destination hash — the iOS app sends its APNs device token
    /// here for registration (plain encrypted packet, no Link).
    static let apnsRegistrationHex = "7e193144b02086570fa0b85c6515a57f"
    static let apnsRegistration: Data = Data(hexString: apnsRegistrationHex)!

    /// rfed.notify destination hash of the APNs bridge — rfed sends wake
    /// packets here when a message arrives for a registered subscriber.
    /// This is the "relay hash" that the iOS app tells rfed about via
    /// /rfed/notify/register.
    static let notifyRelayHex = "2ec8076262ba5be05b6163aec2b54fc5"
    static let notifyRelay: Data = Data(hexString: notifyRelayHex)!
}
