// PropagationPollingModeTests.swift
//
// Self-contained Swift test script.
// Run with:
//
//     swift Retichat-ios/tests/PropagationPollingModeTests.swift
//
// Exits with status 0 on success, 1 on failure.
//
// IMPORTANT: keep `shouldUsePeriodicPropagationPolling` in sync with the
// production helper in `ChatRepository.swift`.

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

func shouldUsePeriodicPropagationPolling(effectivePropHex: String,
                                         derivedPropHex: String,
                                         propagationStreamFallbackRequired: Bool) -> Bool {
    let effective = normalizedPropagationHex(effectivePropHex)
    return !effective.isEmpty || propagationStreamFallbackRequired
}

func shouldUseRfedPropagationStream(effectivePropHex: String,
                                    derivedPropHex: String) -> Bool {
    let effective = normalizedPropagationHex(effectivePropHex)
    let derived = normalizedPropagationHex(derivedPropHex)
    return !effective.isEmpty && effective == derived
}

func normalizedPropagationHex(_ hex: String) -> String {
    hex.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
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

func testRfedPropagationStreamKeepsPolling() {
    let derived = "0f75ac15424242424242424242424242"
    check(
        shouldUsePeriodicPropagationPolling(
            effectivePropHex: derived,
            derivedPropHex: derived,
            propagationStreamFallbackRequired: false
        ) == true,
        "derived propagation keeps periodic polling"
    )
}

func testRfedPropagationFallbackStillPolls() {
    let derived = "0f75ac15424242424242424242424242"
    check(
        shouldUsePeriodicPropagationPolling(
            effectivePropHex: derived,
            derivedPropHex: derived,
            propagationStreamFallbackRequired: true
        ) == true,
        "derived propagation polls after stream rejection"
    )
}

func testRfedPropagationStillUsesStream() {
    let derived = "0f75ac15424242424242424242424242"
    check(
        shouldUseRfedPropagationStream(
            effectivePropHex: derived,
            derivedPropHex: derived
        ) == true,
        "derived propagation still uses stream mode"
    )
}

func testStandalonePropagationKeepsPolling() {
    check(
        shouldUsePeriodicPropagationPolling(
            effectivePropHex: "813be36e005df166d8b168d16e69e4ab",
            derivedPropHex: "0f75ac15424242424242424242424242",
            propagationStreamFallbackRequired: false
        ) == true,
        "standalone propagation keeps periodic polling"
    )
}

func testStandalonePropagationDisablesRfedStream() {
    check(
        shouldUseRfedPropagationStream(
            effectivePropHex: "813be36e005df166d8b168d16e69e4ab",
            derivedPropHex: "0f75ac15424242424242424242424242"
        ) == false,
        "standalone propagation does not use rfed stream mode"
    )
}

func testWhitespaceAndCaseNormalization() {
    check(
        shouldUsePeriodicPropagationPolling(
            effectivePropHex: "  0F75AC15424242424242424242424242  ",
            derivedPropHex: "0f75ac15424242424242424242424242",
            propagationStreamFallbackRequired: false
        ) == true,
        "polling hash comparison is normalized"
    )
    check(
        shouldUseRfedPropagationStream(
            effectivePropHex: "  0F75AC15424242424242424242424242  ",
            derivedPropHex: "0f75ac15424242424242424242424242"
        ) == true,
        "stream hash comparison is normalized"
    )
}

func testSourceHooksPropagationReadyPolling() {
    do {
        let repository = try sourceFile(["Retichat", "Services", "ChatRepository.swift"])
        let connectionState = try sourceFile(["Retichat", "Services", "ConnectionStateManager.swift"])

        check(
            repository.contains("setEssentialDestinationReadyHandler(destHash: watchDest)"),
            "repository registers propagation ready handler"
        )
        check(
            repository.contains("pollPropagationNode(force: true)"),
            "repository forces immediate poll on ready"
        )
        check(
            connectionState.contains("appendDestination(\"lxmf.propagation\", derivedPropHash)"),
            "connection state tracks derived propagation as essential"
        )
        check(
            connectionState.contains("rfedServiceTargets.append((\"lxmf.propagation\", derivedPropHash))"),
            "connection state seeds derived propagation from rfed siblings"
        )
    } catch {
        check(false, "reads propagation polling sources", String(describing: error))
    }
}

testRfedPropagationStreamKeepsPolling()
testRfedPropagationFallbackStillPolls()
testRfedPropagationStillUsesStream()
testStandalonePropagationKeepsPolling()
testStandalonePropagationDisablesRfedStream()
testWhitespaceAndCaseNormalization()
testSourceHooksPropagationReadyPolling()

if failures.isEmpty {
    print("all propagation polling tests passed")
    exit(0)
} else {
    print("\n\(failures.count) failure(s)")
    exit(1)
}