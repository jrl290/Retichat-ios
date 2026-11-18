//
//  DistroOfflineRules.swift
//  Retichat
//
//  The rules of offline use of a distro address (RFed-rust SPEC.md §17.15, James
//  2026-11-17) that DistroOffline decides by: pure, Foundation only, so
//  tests/DistroOfflineTests.swift runs them with swiftc. Retichat-android's
//  DistroOfflineRules (service/DistroOffline.kt), rule for rule.
//

import Foundation

nonisolated enum DistroOfflineRules {
    /// `<random>`: 16 lowercase hex characters, from 8 random bytes.
    static func isRandomPart(_ s: String) -> Bool {
        s.utf8.count == 16 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// The name Transport gives an RTNode reached over Bluetooth (Reticulum-rust prns-ble `interface_name`).
    static let rtnodeBluetoothPrefix = "PrnsBLE["

    /// A mesh connection: an interface to a radio mesh, an RTNode over Bluetooth or an RNode
    /// (`rnodeNames`, the names of the saved RNode rows). Every other interface is an internet
    /// connection (§17.15).
    static func isMesh(_ name: String, rnodeNames: Set<String>) -> Bool {
        name.hasPrefix(rtnodeBluetoothPrefix) || rnodeNames.contains(name)
    }

    /// Whether the device is offline (§17.15): its offline toggle is on, it holds a distro, its
    /// link to RFed failed to come up or closed (`rfedReached` false; nil, nothing known yet, is
    /// not), and none of the interfaces `online` is an internet connection. Losing RFed alone
    /// never makes a device offline while an internet connection is up (James: "it cannot be
    /// triggered by RFed disconnect alone").
    static func offline(enabled: Bool, holdsDistro: Bool, rfedReached: Bool?, online: [String], rnodeNames: Set<String>) -> Bool {
        enabled && holdsDistro && rfedReached == false && online.allSatisfy { isMesh($0, rnodeNames: rnodeNames) }
    }

    /// What a status of the link to RFed says: reached (3 ACTIVE, 5 RECOVERED), not reached
    /// (4 DISCONNECTED: it failed to come up, or closed), or neither (nil: 0 NONE is a link closed
    /// on purpose, as a slow route closes its link after its requests, or no link at all; the rest
    /// are on the way). An event, never slowness.
    static func reached(_ status: UInt8) -> Bool? {
        switch status {
        case 3, 5: return true
        case 4: return false
        default: return nil
        }
    }

    /// The lookup address's answer while offline: the device's own offline address first, then
    /// its siblings heard offline.
    static func lookup(own: String, siblings: [String]) -> [String] {
        [own] + siblings.filter { $0 != own }
    }

    /// A message the router still holds for the propagation node (0 GENERATING, 1 OUTBOUND, 2
    /// SENDING): it has not reached RFed. A handle let go reads as none of them.
    static func waitingForRfed(_ state: Int) -> Bool { (0...2).contains(state) }

    /// Whether a sender asks for a distro's offline devices at a send (§17.15): a mesh connection
    /// is up, and since one last came up it has neither asked for this distro nor heard from any
    /// of its offline addresses.
    static func asks(meshUp: Bool, askedSince: Bool, heardSince: Bool) -> Bool {
        meshUp && !askedSince && !heardSince
    }
}
