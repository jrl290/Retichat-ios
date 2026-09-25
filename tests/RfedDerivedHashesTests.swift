// RfedDerivedHashesTests.swift
//
// The rfed.notify and lxmf.propagation hashes follow the RFed node in use.
// Until 2026-09-24 Settings saved copies derived from the node and those
// copies won: a node changed any other way left propagated sends going to
// the old node's lxmf.propagation (the simulator, switched back from
// staging, sent every propagated message to the unreachable staging node).
//
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/rfed-derived \
//     Retichat-ios/Retichat/Services/UserPreferences.swift \
//     Retichat-ios/tests/RfedDerivedHashesTests.swift && \
//     /private/tmp/claude-501/rfed-derived
//
// It uses the test binary's own UserDefaults domain and clears the keys it
// sets.

import Foundation

var failures: [String] = []

func check(_ condition: @autoclosure () -> Bool, _ name: String, _ detail: String = "") {
    if condition() {
        print("ok    - \(name)")
    } else {
        let message = detail.isEmpty ? name : "\(name) — \(detail)"
        print("FAIL  - \(message)")
        failures.append(message)
    }
}

// Known destinations, from the staging and production chains.
let stagingNode = "5143274db13e03f88c7950ccee9b3148"
let stagingPropagation = "baad3f33be0cbb363f35d3d1a4383531"
let productionPropagation = "0f75ac15961b7d2b1577a57bdb1fda3c"

@main
enum RfedDerivedHashesTests {
    static func main() {
        let defaults = UserDefaults.standard
        let keys = ["rfed_node_identity_hash", "rfed_lxmf_prop_override",
                    "lxmf_propagation_hash", "rfed_notify_hash"]
        keys.forEach { defaults.removeObject(forKey: $0) }

        // The simulator's state: a propagation copy saved while on staging,
        // the node since cleared by hand.
        defaults.set(stagingPropagation, forKey: "lxmf_propagation_hash")
        defaults.set("0123456789abcdef0123456789abcdef", forKey: "rfed_notify_hash")

        let prefs = UserPreferences.shared
        check(defaults.string(forKey: "lxmf_propagation_hash") == nil,
              "the saved propagation copy is dropped at load")
        check(defaults.string(forKey: "rfed_notify_hash") == nil,
              "the saved notify copy is dropped at load")

        check(prefs.effectiveRfedNodeIdentityHash == UserPreferences.defaultRfedNodeIdentityHash,
              "no node saved: the default node is in use")
        check(prefs.effectiveLxmfPropagationHash == productionPropagation,
              "no node saved: propagation is the default node's",
              prefs.effectiveLxmfPropagationHash)

        prefs.rfedNodeIdentityHash = stagingNode
        check(prefs.effectiveLxmfPropagationHash == stagingPropagation,
              "propagation follows a node set any way", prefs.effectiveLxmfPropagationHash)
        let stagingNotify = prefs.effectiveRfedNotifyHash
        check(stagingNotify.count == 32, "notify is derived from the node")

        prefs.rfedNodeIdentityHash = ""
        check(prefs.effectiveLxmfPropagationHash == productionPropagation,
              "and back to the default node's when it is cleared", prefs.effectiveLxmfPropagationHash)
        check(prefs.effectiveRfedNotifyHash != stagingNotify,
              "notify follows the node back too")

        prefs.rfedLxmfPropOverride = "  AABBCCDDEEFF00112233445566778899 "
        check(prefs.effectiveLxmfPropagationHash == "aabbccddeeff00112233445566778899",
              "an explicit override wins, normalized", prefs.effectiveLxmfPropagationHash)
        prefs.rfedNodeIdentityHash = stagingNode
        check(prefs.effectiveLxmfPropagationHash == "aabbccddeeff00112233445566778899",
              "whatever the node")

        keys.forEach { defaults.removeObject(forKey: $0) }
        if failures.isEmpty {
            print("all rfed derived-hash tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
