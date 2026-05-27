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

func testIosSelectorProbesUntilThreeSuccesses() {
    do {
        let iosSource = try sourceFile(["Retichat", "Services", "DefaultEndpointManager.swift"])

        check(
            iosSource.contains("probeTimeoutSecs: TimeInterval = 5.0"),
            "iOS uses a 5-second probe success budget"
        )
        check(
            !iosSource.contains("withTaskGroup"),
            "iOS probes serially instead of fan-out"
        )
        check(
            iosSource.contains("for endpoint in shuffledCandidates"),
            "iOS walks the shuffled fallback list when probing"
        )
        check(
            iosSource.contains("if selected.count == fallbackEndpointCount"),
            "iOS stops probing once three successful connections are found"
        )
    } catch {
        check(false, "reads iOS selector source", String(describing: error))
    }
}

func testAndroidSelectorProbesUntilThreeSuccesses() {
    do {
        let androidSource = try sourceFile(["..", "Retichat-android", "app", "src", "main", "kotlin", "com", "newendian", "retichat", "service", "DefaultEndpointManager.kt"])
        let stackRuntime = try sourceFile(["..", "Retichat-android", "app", "src", "main", "kotlin", "com", "newendian", "retichat", "service", "StackRuntime.kt"])

        check(
            androidSource.contains("PROBE_TIMEOUT_MS = 5_000"),
            "Android uses a 5-second probe success budget"
        )
        check(
            androidSource.contains("suspend fun selectFallbackEndpoints()"),
            "Android exposes a startup fallback selector"
        )
        check(
            androidSource.contains("for (endpoint in shuffledEndpoints)"),
            "Android walks the shuffled fallback list when probing"
        )
        check(
            androidSource.contains("if (selected.size == FALLBACK_ENDPOINT_COUNT)"),
            "Android stops probing once three successful connections are found"
        )
        check(
            stackRuntime.contains("DefaultEndpointManager.selectFallbackEndpoints()"),
            "Android startup uses the probed fallback selector"
        )
        check(
            stackRuntime.contains("DefaultEndpointManager.fallbackInterfaceConfigs(endpoints)"),
            "Android startup injects the probed fallback endpoints"
        )
    } catch {
        check(false, "reads Android selector sources", String(describing: error))
    }
}

testIosDefaultEndpointsMatchAndroid()
testIosSelectorProbesUntilThreeSuccesses()
testAndroidSelectorProbesUntilThreeSuccesses()

if failures.isEmpty {
    print("all default endpoint parity tests passed")
    exit(0)
} else {
    print("\n\(failures.count) failure(s)")
    exit(1)
}