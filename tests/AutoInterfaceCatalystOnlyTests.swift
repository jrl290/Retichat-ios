// AutoInterfaceCatalystOnlyTests.swift
//
// The generated Reticulum config has [[AutoInterface]] on Mac Catalyst only
// (James, 2026-09-25: no more entitlements unless they are needed). Its peer
// discovery is IPv6 multicast, which iOS allows only with Apple's
// com.apple.developer.networking.multicast entitlement; the app does not
// carry it, and since Reticulum-rust 33bea13 AutoInterface really tries, so
// on iOS it could only fail. macOS needs no such entitlement.
//
// Run from the workspace root with:
//
//     swift Retichat-ios/tests/AutoInterfaceCatalystOnlyTests.swift
//
// Source-level, like DefaultEndpointParityTests.swift: the config is built
// inside ChatRepository, which needs SwiftData and the FFI, so the gate is
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

/// The text from `from` through the next `to`.
func span(from: String, to: String, in source: String) -> String {
    guard let start = source.range(of: from),
          let end = source.range(of: to, range: start.upperBound..<source.endIndex) else { return "" }
    return String(source[start.lowerBound..<end.upperBound])
}

func occurrences(_ needle: String, in source: String) -> Int {
    source.components(separatedBy: needle).count - 1
}

func testConfigGatesAutoInterfaceOnCatalyst() {
    let repository: String
    do {
        repository = try sourceFile(["Retichat", "Services", "ChatRepository.swift"])
    } catch {
        check(false, "reads ChatRepository source", String(describing: error))
        return
    }

    let generate = function("private func generateConfig(", in: repository)
    check(!generate.isEmpty, "finds generateConfig")

    // The whole directive line: `#if targetEnvironment(macCatalyst) || os(iOS)`
    // would write the section on iOS again.
    let gate = span(from: "\n        #if targetEnvironment(macCatalyst)\n", to: "#endif", in: generate)
    check(gate.contains("lines.append(\"  [[AutoInterface]]\")")
            && gate.contains("lines.append(\"    type = AutoInterface\")")
            && gate.contains("lines.append(\"    enabled = Yes\")"),
          "the AutoInterface section is written under #if targetEnvironment(macCatalyst)")
    check(!gate.contains("#else"), "the gate has no #else that writes it elsewhere")
    check(!gate.contains("TCPClientInterface"), "the gate holds nothing but AutoInterface")

    let outside = generate.replacingOccurrences(of: gate, with: "")
    check(!outside.contains("[[AutoInterface]]") && !outside.contains("type = AutoInterface"),
          "no AutoInterface section outside the gate")
    check(occurrences("[[AutoInterface]]", in: repository) == 1,
          "ChatRepository writes one AutoInterface section")
    check(outside.contains("type = TCPClientInterface"),
          "TCP interfaces stay ungated (a local IP needs only the Local Network permission)")
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
    check(offenders.isEmpty, "only ChatRepository mentions AutoInterface", "\(offenders)")

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

testConfigGatesAutoInterfaceOnCatalyst()
testNothingElseOffersAutoInterface()

if failures.isEmpty {
    print("all AutoInterface Catalyst-only tests passed")
    exit(0)
} else {
    print("\n\(failures.count) failure(s)")
    exit(1)
}
