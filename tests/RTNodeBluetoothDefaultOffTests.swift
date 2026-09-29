// RTNodeBluetoothDefaultOffTests.swift
//
// The Nearby RTNode switch (Bluetooth to any RTNode in range, d7eb6cc) is
// off by default (James, 2026-09-29). A user who never turns it on sees no
// Bluetooth permission prompt and nothing scans: iOS asks when a
// CBCentralManager is created, RTNodeBluetoothCoordinator creates its one in
// start() only, and ChatRepository starts it only when the switch is on.
// A user who turned it on keeps it on: Settings saves the switch as a Bool
// and an explicit value, on or off, is what is read back.
//
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/rtnode-bluetooth-default-off \
//     Retichat-ios/Retichat/Services/UserPreferences.swift \
//     Retichat-ios/tests/RTNodeBluetoothDefaultOffTests.swift && \
//     /private/tmp/claude-501/rtnode-bluetooth-default-off
//
// The preference runs for real, on a scratch defaults suite and on the test
// binary's own UserDefaults domain (the key is cleared before and after).
// The wiring needs CoreBluetooth, SwiftUI and the FFI, so it is asserted on
// the source, like DisplayNamesTests.swift.

import Foundation

// UserPreferences.swift uses the app's Data hex helpers
// (PropagationNodeManager.swift), which need the whole app; the same two here.
extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var out = Data()
        var i = hexString.startIndex
        while i < hexString.endIndex {
            let j = hexString.index(i, offsetBy: 2)
            guard let b = UInt8(hexString[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        self = out
    }
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

nonisolated(unsafe) var failures: [String] = []

func check(_ ok: Bool, _ what: String, _ detail: String = "") {
    if ok {
        print("ok    - \(what)")
    } else {
        let message = detail.isEmpty ? what : "\(what) — \(detail)"
        failures.append(message)
        print("FAIL  - \(message)")
    }
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func source(_ path: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

/// Every Swift file the app and the NSE are built from.
func appSources() -> [(String, String)] {
    var out: [(String, String)] = []
    for dir in ["Retichat", "NotificationService"] {
        let base = root.appendingPathComponent(dir)
        guard let walk = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
        for case let url as URL in walk where url.pathExtension == "swift" {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            out.append((url.path.replacingOccurrences(of: root.path + "/", with: ""), text))
        }
    }
    return out
}

func count(_ text: String, _ needle: String) -> Int {
    text.components(separatedBy: needle).count - 1
}

/// The text of `text` from `start` up to the next `end` after it.
func between(_ text: String, _ start: String, _ end: String) -> String {
    guard let a = text.range(of: start) else { return "" }
    let rest = text[a.upperBound...]
    guard let b = rest.range(of: end) else { return String(rest) }
    return String(rest[..<b.lowerBound])
}

let key = "rtnode_bluetooth_enabled"

// MARK: - The preference

func testTheSwitchIsOffUntilTurnedOn() {
    let suite = "rtnode-bluetooth-test-\(UUID().uuidString)"
    guard let d = UserDefaults(suiteName: suite) else { check(false, "a scratch defaults suite"); return }
    defer { d.removePersistentDomain(forName: suite) }

    check(d.object(forKey: key) == nil, "a new install has no saved switch")
    check(UserPreferences.rtnodeBluetoothEnabled(d) == false,
          "never set: off, so nothing starts Bluetooth and iOS never asks")

    d.set(true, forKey: key)
    check(UserPreferences.rtnodeBluetoothEnabled(d) == true, "turned on: stays on")

    d.set(false, forKey: key)
    check(UserPreferences.rtnodeBluetoothEnabled(d) == false, "turned off again: off")
}

/// The property Settings and ChatRepository use, on this binary's own domain.
func testTheSharedPreference() {
    let defaults = UserDefaults.standard
    defaults.removeObject(forKey: key)
    defer { defaults.removeObject(forKey: key) }

    let prefs = UserPreferences.shared
    check(prefs.rtnodeBluetoothEnabled == false, "UserPreferences.shared: unset reads off")

    prefs.rtnodeBluetoothEnabled = true
    check(defaults.object(forKey: key) as? Bool == true, "Settings saves the switch under \(key) as a Bool")
    check(prefs.rtnodeBluetoothEnabled == true, "UserPreferences.shared: a saved on is respected")

    prefs.rtnodeBluetoothEnabled = false
    check(defaults.object(forKey: key) != nil, "a saved off is kept as a value, not removed")
    check(prefs.rtnodeBluetoothEnabled == false, "UserPreferences.shared: a saved off is respected")
}

func testNoOtherDefaultIsAssumed() {
    let prefs = source("Retichat/Services/UserPreferences.swift")
    let getter = between(prefs, "static func rtnodeBluetoothEnabled(_ defaults: UserDefaults) -> Bool {", "\n    }")
    check(getter.hasSuffix(": false"), "the one getter falls back to false", getter)
    check(count(prefs, "Keys.rtnodeBluetoothEnabled") == 3,
          "the key is read in the one getter and written in the one setter only")
    let behindItsBack = appSources()
        .filter { $0.0 != "Retichat/Services/UserPreferences.swift" && $0.1.contains("\"\(key)\"") }
        .map { $0.0 }
    check(behindItsBack.isEmpty, "no other file reads the key behind UserPreferences' back", "\(behindItsBack)")
}

// MARK: - Wiring (source)

/// The permission prompt comes from creating a CBCentralManager: the
/// coordinator creates its one in start(), never at init or in stop(), and
/// Settings holding the shared instance for its status creates nothing.
func testOnlyStartCreatesTheCentral() {
    let coord = source("Retichat/Services/RTNodeBluetoothCoordinator.swift")
    check(count(coord, "CBCentralManager(") == 1, "the coordinator creates one CBCentralManager")
    let start = between(coord, "func start(storageDir: String, endpointHost: UInt8) {", "\n    func stop()")
    check(start.contains("central = CBCentralManager("), "and creates it in start()")
    check(!coord.contains("override init("), "the shared instance does nothing at init")
}

func testTheStackStartsBluetoothOnlyWhenOn() {
    var starts: [String] = []
    for (path, text) in appSources() where text.contains("RTNodeBluetoothCoordinator.shared.start(") {
        starts.append(path)
    }
    check(starts == ["Retichat/Services/ChatRepository.swift"],
          "ChatRepository is the one place the coordinator is started", "\(starts)")
    let repo = source("Retichat/Services/ChatRepository.swift")
    check(count(repo, "RTNodeBluetoothCoordinator.shared.start(") == 1, "and it starts it once")
    let gated = between(repo, "if UserPreferences.shared.rtnodeBluetoothEnabled {", "startPropagationPolling()")
    check(gated.contains("RTNodeBluetoothCoordinator.shared.start("),
          "behind the switch: off means no start, no CBCentralManager, no prompt")
}

/// Turning it on in Settings and pressing Apply saves it and restarts the
/// stack, and the restart is what starts the coordinator (and so asks).
func testTurningItOnGoesThroughTheStart() {
    let vm = source("Retichat/Views/Settings/SettingsViewModel.swift")
    check(vm.contains("self.rtnodeBluetoothEnabled = prefs.rtnodeBluetoothEnabled"),
          "Settings shows the saved switch, so off on a new install")
    check(between(vm, "var needsRestart: Bool {", "\n    }").contains("rtnodeBluetoothEnabled != originalRtnodeBluetoothEnabled"),
          "changing the switch restarts the stack on Apply")
    check(between(vm, "func apply() {", "\n    }").contains("prefs.rtnodeBluetoothEnabled = rtnodeBluetoothEnabled"),
          "Apply saves the switch before the restart")
    let view = source("Retichat/Views/Settings/SettingsView.swift")
    let apply = between(view, "private func applySettings() {", "\n    }")
    check(apply.contains("let needsRestart = vm.needsRestart") &&
          apply.contains("vm.apply()") &&
          apply.contains("guard needsRestart, repository.serviceRunning else { return }") &&
          apply.contains("repository.startService()"),
          "applySettings saves, then stops and starts a running stack")
    check(view.contains("Toggle(\"\", isOn: $vm.rtnodeBluetoothEnabled)"), "the card's switch is the view model's")
}

@main
enum RTNodeBluetoothDefaultOffTests {
    static func main() {
        testTheSwitchIsOffUntilTurnedOn()
        testTheSharedPreference()
        testNoOtherDefaultIsAssumed()
        testOnlyStartCreatesTheCentral()
        testTheStackStartsBluetoothOnlyWhenOn()
        testTurningItOnGoesThroughTheStart()
        if failures.isEmpty {
            print("all RTNode Bluetooth default tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
