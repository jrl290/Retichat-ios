// RNodeFrequencyFormatterTests.swift
//
// Run with:
//
//     swiftc Retichat/Models/RNodeFrequencyFormatter.swift tests/RNodeFrequencyFormatterTests.swift \
//       -o /tmp/rnode-frequency-tests && /tmp/rnode-frequency-tests

import Foundation

@main
struct RNodeFrequencyFormatterTests {
    static var failures: [String] = []

    static func check(_ actual: String, equals expected: String) {
        if actual == expected {
            print("ok    - \(actual)")
        } else {
            print("FAIL  - expected \(expected), got \(actual)")
            failures.append("expected \(expected), got \(actual)")
        }
    }

    static func checkRoundTrip(_ frequencyHz: UInt64) {
        let text = RNodeFrequencyFormatter.mhzText(for: frequencyHz)
        let parsedHz = Double(text).map { UInt64($0 * 1_000_000) }
        if parsedHz == frequencyHz {
            print("ok    - \(frequencyHz) Hz round trip")
        } else {
            print("FAIL  - expected \(frequencyHz), got \(String(describing: parsedHz))")
            failures.append("\(frequencyHz) Hz round trip")
        }
    }

    static func main() {
        check(RNodeFrequencyFormatter.mhzText(for: 868_672_500), equals: "868.6725")
        check(RNodeFrequencyFormatter.mhzText(for: 867_500_000), equals: "867.5")
        check(RNodeFrequencyFormatter.mhzText(for: 868_000_001), equals: "868.000001")
        check(RNodeFrequencyFormatter.mhzText(for: 868_000_000), equals: "868")
        checkRoundTrip(868_672_500)
        checkRoundTrip(868_000_001)

        if failures.isEmpty {
            print("all RNode frequency formatter tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
