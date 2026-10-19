// AutoInterfaceTests.swift
//
// The built-in Local network interface (AutoInterface, James 2026-10-19):
// Settings' switch, off by default, offered only where multicast works (Mac
// Catalyst, the simulator, or a device build with Apple's multicast
// entitlement), written into the config only when on, and left out of the
// NSE's copy. It replaces AutoInterfaceOffTests.swift (2026-10-12: no
// AutoInterface on any build, because Catalyst took utun2; Reticulum-rust
// 35207c0 skips tunnels on iOS and Catalyst).
//
// Run from the workspace root with:
//
//     swift Retichat-ios/tests/AutoInterfaceTests.swift
//
// Source-level, like the file it replaces: the config is built inside
// ChatRepository, which needs SwiftData and the FFI.

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

func between(_ start: String, _ end: String, in source: String) -> String {
    guard let a = source.range(of: start),
          let b = source.range(of: end, range: a.upperBound..<source.endIndex) else { return "" }
    return String(source[a.lowerBound..<b.upperBound])
}

func read(_ components: [String]) -> String {
    do { return try sourceFile(components) } catch {
        check(false, "reads \(components.joined(separator: "/"))", String(describing: error))
        return ""
    }
}

func testOffByDefault() {
    let prefs = read(["Retichat", "Services", "UserPreferences.swift"])
    let stored = function("static func autoInterfaceEnabled(", in: prefs)
    check(stored.contains("defaults.object(forKey: Keys.autoInterfaceEnabled) != nil") && stored.contains(": false"),
          "the switch reads false when it was never set")
}

func testConfigOnlyWhenOnAndWhereMulticastWorks() {
    let repository = read(["Retichat", "Services", "ChatRepository.swift"])
    let generate = function("private func generateConfig(", in: repository)
    check(!generate.isEmpty, "finds generateConfig")
    let gate = "if UserPreferences.shared.autoInterfaceEnabled && LocalNetworkPermission.multicastAvailable {"
    let section = between(gate, "}", in: generate)
    check(section.contains("type = AutoInterface"), "the AutoInterface section is written under the switch and multicastAvailable")
    check(generate.components(separatedBy: "type = AutoInterface").count == 2, "and nowhere else in generateConfig")
    for key in ["group_id", "discovery_port", "data_port", "devices"] {
        check(!section.contains(key), "Reticulum's default \(key), so it finds Sideband, MeshChat and rnsd")
    }

    let permission = read(["Retichat", "Services", "LocalNetworkPermission.swift"])
    check(permission.contains("#if targetEnvironment(macCatalyst) || targetEnvironment(simulator) || MULTICAST_ENTITLEMENT"),
          "multicastAvailable: Catalyst, the simulator, or a build with the entitlement")
    let entitlements = read(["Retichat", "Retichat.entitlements"])
    let project = read(["Retichat.xcodeproj", "project.pbxproj"])
    check(entitlements.contains("com.apple.developer.networking.multicast") == project.contains("MULTICAST_ENTITLEMENT"),
          "MULTICAST_ENTITLEMENT is set exactly when the app carries the entitlement")
}

func testSettingsOffersItAndAsksForLocalNetwork() {
    let view = read(["Retichat", "Views", "Settings", "SettingsView.swift"])
    check(view.components(separatedBy: "if LocalNetworkPermission.multicastAvailable {\n                        localNetworkCard").count == 3,
          "the card is shown beside Nearby RTNode, with or without other interfaces, where it can work")
    check(view.contains("if on { localNetwork.check() }"), "turning it on is when iOS asks for Local Network access")
    check(view.contains("if status == .denied { vm.autoInterfaceDenied() }"), "refused, the switch goes off")
    let model = read(["Retichat", "Views", "Settings", "SettingsViewModel.swift"])
    check(model.contains("autoInterfaceEnabled != originalAutoInterfaceEnabled ||"), "a change restarts the stack on Apply")
    check(model.contains("prefs.autoInterfaceEnabled = autoInterfaceEnabled"), "Apply saves it")
}

func testTheNSECopyLeavesItOut() {
    let pending = read(["Retichat", "Services", "PendingNotification.swift"])
    check(function("static func copyConfigToAppGroup(", in: pending).contains("withoutAutoInterface(text)"),
          "the NSE's config is the app's without the AutoInterface")
    let nse = read(["NotificationService", "NotificationService.swift"])
    check(nse.contains("configDir + \"/config\"") && !nse.contains("[interfaces]"),
          "the NSE reads that copy and writes no config of its own")
}

testOffByDefault()
testConfigOnlyWhenOnAndWhereMulticastWorks()
testSettingsOffersItAndAsksForLocalNetwork()
testTheNSECopyLeavesItOut()

if failures.isEmpty {
    print("all AutoInterface tests passed")
    exit(0)
} else {
    print("\n\(failures.count) failure(s)")
    exit(1)
}
