// AutoInterfaceOffTests.swift
//
// The generated Reticulum config has no [[AutoInterface]] on any build for
// now (James, 2026-10-12). Its peer discovery is IPv6 multicast, which iOS
// allows only with Apple's com.apple.developer.networking.multicast
// entitlement; the app does not carry it (James, 2026-09-25: no more
// entitlements unless they are needed), and since Reticulum-rust 33bea13
// AutoInterface really tries, so on iOS it could only fail. Mac Catalyst kept
// it until 2026-10-12, when it took utun2, a VPN tunnel that carries no
// multicast, and logged "No multicast echoes received" as an error.
//
// Run from the workspace root with:
//
//     swift Retichat-ios/tests/AutoInterfaceOffTests.swift
//
// Source-level, like DefaultEndpointParityTests.swift: the config is built
// inside ChatRepository, which needs SwiftData and the FFI, so the absence is
// asserted on the code itself. The NSE starts from a copy of the same file.

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

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func sourceFile(_ components: [String]) throws -> String {
    let url = components.reduce(root) { $0.appendingPathComponent($1) }
    return try String(contentsOf: url, encoding: .utf8)
}

/// A method's text: from its signature to its closing brace.
func function(_ signature: String, in source: String, indent: String = "    ") -> String {
    guard let start = source.range(of: signature) else { return "" }
    guard let end = source.range(of: "\n\(indent)}\n", range: start.upperBound..<source.endIndex) else {
        return String(source[start.lowerBound...])
    }
    return String(source[start.lowerBound..<end.upperBound])
}

func testConfigWritesNoAutoInterface() {
    let repository: String
    do {
        repository = try sourceFile(["Retichat", "Services", "ChatRepository.swift"])
    } catch {
        check(false, "reads ChatRepository source", String(describing: error))
        return
    }

    let generate = function("private func generateConfig(", in: repository)
    check(!generate.isEmpty, "finds generateConfig")

    // Under any gate: a Catalyst-only section would bring the utun2 error back.
    check(!repository.contains("[[AutoInterface]]") && !repository.contains("type = AutoInterface"),
          "ChatRepository writes no AutoInterface section, under any #if")
    check(generate.contains("type = TCPClientInterface"),
          "TCP interfaces stay (a local IP needs only the Local Network permission)")
}

func testNothingElseOffersAutoInterface() {
    // The NSE must start from the app's copy, not a config of its own, and
    // no other source (a Settings row, a second config writer) may add one.
    var offenders: [String] = []
    for directory in ["Retichat", "NotificationService"] {
        let base = root.appendingPathComponent(directory)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
            check(false, "lists \(directory)")
            continue
        }
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if text.contains("AutoInterface") && url.lastPathComponent != "ChatRepository.swift" {
                offenders.append(url.lastPathComponent)
            }
        }
    }
    check(offenders.isEmpty, "only ChatRepository mentions AutoInterface (its comment)", "\(offenders)")

    do {
        let pending = try sourceFile(["Retichat", "Services", "PendingNotification.swift"])
        let nse = try sourceFile(["NotificationService", "NotificationService.swift"])
        check(function("static func copyConfigToAppGroup(", in: pending).contains("copyItem(atPath: sourcePath"),
              "the NSE's config is a copy of the app's")
        check(nse.contains("configDir + \"/config\"") && !nse.contains("[interfaces]"),
              "the NSE reads that copy and writes no config of its own")
    } catch {
        check(false, "reads the NSE sources", String(describing: error))
    }
}

testConfigWritesNoAutoInterface()
testNothingElseOffersAutoInterface()

if failures.isEmpty {
    print("all AutoInterface-off tests passed")
    exit(0)
} else {
    print("\n\(failures.count) failure(s)")
    exit(1)
}
