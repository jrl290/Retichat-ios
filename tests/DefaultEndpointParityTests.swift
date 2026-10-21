// DefaultEndpointParityTests.swift
//
// Source-level guard for the shared fresh-start fallback backbone pool.
//
// Run with:
//
//     swift Retichat-ios/tests/DefaultEndpointParityTests.swift

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

func endpointStrings(in source: String, pattern: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(source.startIndex..., in: source)
    return regex.matches(in: source, range: range).compactMap { match in
        guard match.numberOfRanges == 3,
              let hostRange = Range(match.range(at: 1), in: source),
              let portRange = Range(match.range(at: 2), in: source) else {
            return nil
        }
        return "\(source[hostRange]):\(source[portRange])"
    }
}

func firstInteger(in source: String, pattern: String) -> Int? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(source.startIndex..., in: source)
    guard let match = regex.firstMatch(in: source, range: range),
          let valueRange = Range(match.range(at: 1), in: source) else {
        return nil
    }
    return Int(source[valueRange])
}

func testIosDefaultEndpointsMatchAndroid() {
    do {
        let iosSource = try sourceFile(["Retichat", "Services", "DefaultEndpointManager.swift"])
        let androidSource = try sourceFile(["..", "Retichat-android", "app", "src", "main", "kotlin", "com", "newendian", "retichat", "service", "DefaultEndpointManager.kt"])

        let iosEndpoints = endpointStrings(
            in: iosSource,
            pattern: #"\("([^"]+)",\s*(\d+)\)"#
        )
        let androidEndpoints = endpointStrings(
            in: androidSource,
            pattern: #""([^"]+)"\s+to\s+(\d+)"#
        )

        check(!iosEndpoints.isEmpty, "reads iOS fallback endpoints")
        check(!androidEndpoints.isEmpty, "reads Android fallback endpoints")
        check(
            iosEndpoints == androidEndpoints,
            "iOS and Android share the same fallback endpoint pool",
            "iOS=\(iosEndpoints) Android=\(androidEndpoints)"
        )

        let iosFallbackCount = firstInteger(
            in: iosSource,
            pattern: #"fallbackEndpointCount\s*=\s*(\d+)"#
        )
        let androidFallbackCount = firstInteger(
            in: androidSource,
            pattern: #"FALLBACK_ENDPOINT_COUNT\s*=\s*(\d+)"#
        )

        check(iosFallbackCount == 3, "iOS fallback count remains three")
        check(androidFallbackCount == 3, "Android fallback count remains three")
        check(
            iosFallbackCount == androidFallbackCount,
            "iOS and Android use the same fallback count",
            "iOS=\(String(describing: iosFallbackCount)) Android=\(String(describing: androidFallbackCount))"
        )
    } catch {
        check(false, "reads fallback endpoint sources", String(describing: error))
    }
}

// Both test the whole list at once and take the first three to answer, and
// skip for a day a backbone that failed while others answered (James,
// 2026-10-21: "probe all default backbones at once and take the first three
// that answer", "Add a blacklist also"). Until then they tested one at a time
// (b0d071f), each backbone down costing its whole 5 s. The behaviour itself is
// tested in FallbackBackbonesTests.swift and Android's DefaultBackbonesTest.kt.

func testIosSelectorTestsAllAtOnce() {
    do {
        let iosSource = try sourceFile(["Retichat", "Services", "DefaultEndpointManager.swift"])
        let picker = try sourceFile(["Retichat", "Services", "FallbackBackbones.swift"])

        check(
            iosSource.contains("probeTimeoutSecs: TimeInterval = 5.0"),
            "iOS uses a 5-second probe success budget"
        )
        check(
            iosSource.contains("await FallbackBackbones.pick("),
            "iOS picks through FallbackBackbones.pick"
        )
        check(
            !iosSource.contains("for endpoint in shuffledCandidates"),
            "iOS no longer walks the list one backbone at a time"
        )
        check(
            picker.contains("static let skipSeconds: TimeInterval = 24 * 60 * 60"),
            "iOS skips a failed backbone for 24 hours"
        )
    } catch {
        check(false, "reads iOS selector source", String(describing: error))
    }
}

func testAndroidSelectorTestsAllAtOnce() {
    do {
        let androidSource = try sourceFile(["..", "Retichat-android", "app", "src", "main", "kotlin", "com", "newendian", "retichat", "service", "DefaultEndpointManager.kt"])
        let stackRuntime = try sourceFile(["..", "Retichat-android", "app", "src", "main", "kotlin", "com", "newendian", "retichat", "service", "StackRuntime.kt"])

        check(
            androidSource.contains("PROBE_TIMEOUT_MS = 5_000"),
            "Android uses a 5-second probe success budget"
        )
        check(
            androidSource.contains("suspend fun selectFallbackEndpoints(context: Context)"),
            "Android exposes a startup fallback selector"
        )
        check(
            androidSource.contains("internal suspend fun pick("),
            "Android picks through DefaultEndpointManager.pick"
        )
        check(
            !androidSource.contains("for (endpoint in shuffledEndpoints)"),
            "Android no longer walks the list one backbone at a time"
        )
        check(
            androidSource.contains("SKIP_MS = 24 * 60 * 60 * 1000L"),
            "Android skips a failed backbone for 24 hours, as iOS"
        )
        check(
            stackRuntime.contains("DefaultEndpointManager.selectFallbackEndpoints(app)"),
            "Android startup uses the fallback selector"
        )
        check(
            stackRuntime.contains("DefaultEndpointManager.fallbackInterfaceConfigs(defaultBackbones)"),
            "Android startup injects the picked fallback endpoints"
        )
    } catch {
        check(false, "reads Android selector sources", String(describing: error))
    }
}

testIosDefaultEndpointsMatchAndroid()
testIosSelectorTestsAllAtOnce()
testAndroidSelectorTestsAllAtOnce()

if failures.isEmpty {
    print("all default endpoint parity tests passed")
    exit(0)
} else {
    print("\n\(failures.count) failure(s)")
    exit(1)
}