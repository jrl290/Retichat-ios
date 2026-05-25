// NSEPropagationAppLinksTests.swift
//
// Focused source-level guard for the Notification Service Extension's
// propagation pull path.
//
// Run with:
//
//     swift Retichat-ios/tests/NSEPropagationAppLinksTests.swift

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

func sourceFile(_ components: [String]) throws -> String {
    let sourceURL = components.reduce(
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    ) { partial, component in
        partial.appendingPathComponent(component)
    }
    return try String(contentsOf: sourceURL, encoding: .utf8)
}

func testSourceUsesAppLinksForPropagationPull() {
    do {
        let source = try sourceFile(["NotificationService", "NotificationService.swift"])

        check(
            source.contains("client.setAppLinkStatusCallback("),
            "NSE registers an AppLinks status callback"
        )
        check(
            source.contains("client.appLinkOpen(node.data, app: \"lxmf\", aspects: [\"propagation\"]"),
            "NSE primes lxmf.propagation via AppLinks"
        )
        check(
            source.contains("handlePropagationAppLinkStatus(destHash: hash, status: status)"),
            "NSE routes AppLinks status changes into the service"
        )
        check(
            source.contains("beginPropagationSync(nodeHash: destHash, reason: \"AppLinks became active\")"),
            "NSE retries propagation sync when AppLinks becomes active"
        )
    } catch {
        check(false, "reads NotificationService source", String(describing: error))
    }
}

testSourceUsesAppLinksForPropagationPull()

if failures.isEmpty {
    print("all NSE propagation AppLinks tests passed")
    exit(0)
} else {
    print("\n\(failures.count) failure(s)")
    exit(1)
}