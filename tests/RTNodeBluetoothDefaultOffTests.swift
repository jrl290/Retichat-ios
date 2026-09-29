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
// iOS asks once. After Don't Allow (the central's .unauthorized), or with
// Bluetooth denied or restricted for Retichat (CBManager.authorization, read
// without a prompt), the coordinator stops the engine and saves the switch
// off, so no stack start starts it again; Settings shows the switch off and
// "Allow Bluetooth for Retichat in iOS Settings" with an Open Settings
// button, as the Notifications card links to iOS Settings. Allowed there,
// the switch turned on and Apply start it as normal.
//
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/rtnode-bluetooth-default-off \
//     Retichat-ios/Retichat/Services/UserPreferences.swift \
//     Retichat-ios/tests/RTNodeBluetoothDefaultOffTests.swift && \
//     /private/tmp/claude-501/rtnode-bluetooth-default-off
//
// The preference runs for real, on a scratch defaults suite and on
// UserDefaults.standard, which UserPreferences.shared uses. Neither is in
// ~/Library/Preferences: emptying a domain there (removePersistentDomain,
// removeObject) leaves an empty plist, and cfprefsd writes it back some
// seconds after the process deletes it, so the test keeps both as plists in
// a scratch directory of its own and deletes the directory at the end.
// The wiring needs CoreBluetooth, SwiftUI and the FFI, so it is asserted on
// the source, like DisplayNamesTests.swift.

import Foundation
import ObjectiveC

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

/// Every needle is in `text`, each after the one before it.
func ordered(_ text: String, _ needles: [String]) -> Bool {
    var rest = text[...]
    for needle in needles {
        guard let r = rest.range(of: needle) else { return false }
        rest = rest[r.upperBound...]
    }
    return true
}

let key = "rtnode_bluetooth_enabled"
let coordinatorPath = "Retichat/Services/RTNodeBluetoothCoordinator.swift"

// MARK: - Scratch preferences

/// Where the test's preferences live, deleted at the end. A defaults suite
/// named by an absolute path is the plist at that path.
let scratchPrefs = FileManager.default.temporaryDirectory
    .appendingPathComponent("rtnode-bluetooth-tests-\(UUID().uuidString)", isDirectory: true)

func scratchDefaults(_ name: String) -> UserDefaults? {
    UserDefaults(suiteName: scratchPrefs.appendingPathComponent(name).path)
}

/// This binary's own domain, which UserDefaults.standard would otherwise be.
let ownDomainPlist = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Preferences/\(ProcessInfo.processInfo.processName).plist")

func modified(_ url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
}

/// UserPreferences.shared keeps UserDefaults.standard from its first use, so
/// this runs before anything touches it.
func pointStandardDefaults(at scratch: UserDefaults) {
    guard let meta = object_getClass(UserDefaults.self) else { return }
    let standard: @convention(block) (AnyObject) -> UserDefaults = { _ in scratch }
    class_replaceMethod(meta, #selector(getter: UserDefaults.standard),
                        imp_implementationWithBlock(standard), "@@:")
}

// MARK: - The preference

func testTheSwitchIsOffUntilTurnedOn() {
    guard let d = scratchDefaults("suite") else { check(false, "a scratch defaults suite"); return }

    check(d.object(forKey: key) == nil, "a new install has no saved switch")
    check(UserPreferences.rtnodeBluetoothEnabled(d) == false,
          "never set: off, so nothing starts Bluetooth and iOS never asks")

    d.set(true, forKey: key)
    check(UserPreferences.rtnodeBluetoothEnabled(d) == true, "turned on: stays on")

    d.set(false, forKey: key)
    check(UserPreferences.rtnodeBluetoothEnabled(d) == false, "turned off again: off")
}

/// The property Settings, ChatRepository and the coordinator's denial use.
func testTheSharedPreference() {
    let defaults = UserDefaults.standard
    defaults.removeObject(forKey: key)
    defer { defaults.removeObject(forKey: key) }

    let prefs = UserPreferences.shared
    check(prefs.rtnodeBluetoothEnabled == false, "UserPreferences.shared: unset reads off")

    prefs.rtnodeBluetoothEnabled = true
    check(defaults.object(forKey: key) as? Bool == true, "Settings saves the switch under \(key) as a Bool")
    check(prefs.rtnodeBluetoothEnabled == true, "UserPreferences.shared: a saved on is respected")

    // What the coordinator's switchOff() does on a denial.
    prefs.rtnodeBluetoothEnabled = false
    check(defaults.object(forKey: key) != nil, "a saved off is kept as a value, not removed")
    check(prefs.rtnodeBluetoothEnabled == false,
          "UserPreferences.shared: a saved off is respected, so a denied switch starts nothing")

    // Allowed in iOS Settings, then turned on and applied.
    prefs.rtnodeBluetoothEnabled = true
    check(prefs.rtnodeBluetoothEnabled == true, "turned on again after a denial: on, nothing remembers the denial")
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
    let coord = source(coordinatorPath)
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

// MARK: - Don't Allow (source)

/// Denied or not is the class property, which never prompts: no central is
/// made to find out.
func testTheDenialIsReadWithoutAPrompt() {
    let coord = source(coordinatorPath)
    let denied = between(coord, "static var bluetoothDenied: Bool {", "\n    }")
    check(denied.contains("switch CBManager.authorization {"),
          "denied is read from the CBManager.authorization class property", denied)
    check(denied.contains("case .denied, .restricted: return true") && denied.contains("default: return false"),
          "denied and restricted are not allowed; allowed and not yet asked are", denied)
    check(count(coord, ".authorization") == count(coord, "CBManager.authorization"),
          "no central's authorization is read: that would need a CBCentralManager")
    check(count(coord, "CBCentralManager(") == 1, "checking it creates no CBCentralManager (the one is start()'s)")
}

/// Don't Allow: the engine stops and the switch is saved off, so the next
/// stack start does not start it again.
func testDontAllowStopsTheEngineAndSavesTheSwitchOff() {
    let coord = source(coordinatorPath)
    let unauthorized = between(coord, "case .unauthorized:", "case .unsupported:")
    check(unauthorized.contains("denied()"), "the central's .unauthorized (Don't Allow) goes to denied()", unauthorized)
    check(!unauthorized.contains("publish(.unavailable("), "and is not only a status line", unauthorized)

    let denied = between(coord, "private func denied() {", "\n    }")
    check(ordered(denied, ["running = false", "dropAll()", "stopEngine()", "switchOff()"]),
          "denied() stops scanning, closes the links, stops the engine, then saves the switch off", denied)

    let stopEngine = between(coord, "private func stopEngine() {", "\n    }")
    check(ordered(stopEngine, ["engineLock.lock()", "guard engineRunning else { return }",
                               "rns_prns_ble_stop()", "engineRunning = false"]),
          "stopEngine() stops a running engine, under engineLock", stopEngine)
    check(count(coord, "rns_prns_ble_stop()") == 1, "the engine is stopped in stopEngine() only")
    let stop = between(coord, "func stop() {", "\n    }")
    check(stop.contains("stopEngine()"), "stop() stops it there too")
    let start = between(coord, "func start(storageDir: String, endpointHost: UInt8) {", "\n    func stop()")
    check(ordered(start, ["engineLock.lock()", "rns_prns_ble_start("]),
          "start() takes engineLock too: a denial on the coordinator's queue cannot race a stack start")
    check(!stop.contains("engineLock") && !stopEngine.contains("queue.sync") && !start.contains("queue.sync"),
          "engineLock is never held across a queue.sync (denied() takes it on that queue)")

    let switchOff = between(coord, "private func switchOff() {", "\n    }")
    check(switchOff.contains("DispatchQueue.main.async") && switchOff.contains("MainActor.assumeIsolated"),
          "switchOff() runs on the main actor", switchOff)
    check(ordered(switchOff, ["UserPreferences.shared.rtnodeBluetoothEnabled = false", "self.status = .denied"]),
          "and saves the switch off before showing .denied, in one turn", switchOff)
}

/// A stack start while denied (a switch saved on, then denied in iOS
/// Settings) starts nothing and saves the switch off.
func testAStartWhileDeniedStartsNothing() {
    let coord = source(coordinatorPath)
    let start = between(coord, "func start(storageDir: String, endpointHost: UInt8) {", "\n    func stop()")
    let deniedGuard = between(start, "guard !Self.bluetoothDenied else {", "}")
    check(deniedGuard.contains("switchOff()") && deniedGuard.contains("return"),
          "start() while denied saves the switch off and returns", deniedGuard)
    check(ordered(start, ["guard !Self.bluetoothDenied else {", "rns_prns_ble_start(", "central = CBCentralManager("]),
          "before the engine starts and before any CBCentralManager")
}

/// The note stays while it is still denied, and goes once it is allowed.
func testTheNoteLastsUntilAllowed() {
    let coord = source(coordinatorPath)
    check(between(coord, "func stop() {", "\n    }").contains("publish(Self.bluetoothDenied ? .denied : .off)"),
          "a stack stop while still denied keeps the card on iOS Settings")
    let recheck = between(coord, "@MainActor func recheckAuthorization() {", "\n    }")
    check(ordered(recheck, ["if Self.bluetoothDenied {", "denied()"]),
          "Settings' recheck: denied in iOS Settings since is handled as a Don't Allow", recheck)
    check(ordered(recheck, ["} else if status == .denied {", "status = .off"]),
          "allowed again: the note goes and the switch can be turned on", recheck)
    check(between(coord, "case .poweredOn:", "case .poweredOff:").contains("publishIdle()"),
          "allowed while the app runs: the kept central's powered-on clears .denied")
    check(!coord.contains("var denied") && !coord.contains("let denied"),
          "no denial is stored: start() reads the permission each time, so allowed means it starts")
}

/// Settings: the switch off, held off, and the way to iOS Settings.
func testSettingsShowsTheWayToIOSSettings() {
    let view = source("Retichat/Views/Settings/SettingsView.swift")
    let card = between(view, "private var rtnodeBluetoothCard: some View {", "\n    }")
    let button = between(card, "if rtnodeBle.status == .denied {", ".tint(")
    check(button.contains("URL(string: UIApplication.openSettingsURLString)") &&
          button.contains("UIApplication.shared.open(url)") &&
          button.contains("Text(\"Open Settings\")"),
          "a denied card has an Open Settings button to iOS Settings", button)
    let notifications = between(view, "private var notificationSection: some View {", "\n    }")
    check(notifications.contains("UIApplication.openSettingsURLString"),
          "the same way the Notifications card links to iOS Settings")
    check(card.contains(".disabled(rtnodeBle.status == .denied)"),
          "the switch is held off while denied: turned on, iOS would not ask")

    let text = between(view, "private var rtnodeStatusText: String {", "\n    }")
    check(text.contains("case (.denied, _): return \"Allow Bluetooth for Retichat in iOS Settings\""),
          "the card says to allow Bluetooth for Retichat in iOS Settings", text)
    check(ordered(text, ["case (.denied, _):", "case (_, false): return \"Off\""]),
          "whatever the switch: after a denial it is off, and the note is what shows", text)

    check(between(view, ".onChange(of: rtnodeBle.status) { _, status in", "}").contains("vm.rtnodeBluetoothDenied()"),
          "a denial shows the switch off at once")
    let vm = source("Retichat/Views/Settings/SettingsViewModel.swift")
    let deniedVM = between(vm, "func rtnodeBluetoothDenied() {", "\n    }")
    check(deniedVM.contains("rtnodeBluetoothEnabled = false") && deniedVM.contains("originalRtnodeBluetoothEnabled = false"),
          "shown off, with off as the baseline: no unapplied change, and Revert cannot save it on", deniedVM)

    check(between(view, ".onAppear {", ".onDisappear").contains("rtnodeBle.recheckAuthorization()"),
          "Settings rechecks the permission when it appears")
    check(between(view, ".onChange(of: scenePhase) { _, phase in", "}").contains("if phase == .active { rtnodeBle.recheckAuthorization()"),
          "and when the app comes back from iOS Settings")
}

@main
enum RTNodeBluetoothDefaultOffTests {
    static func main() {
        let ownDomainBefore = modified(ownDomainPlist)
        var standardIsScratch = false
        do {
            try FileManager.default.createDirectory(at: scratchPrefs, withIntermediateDirectories: true)
            if let standard = scratchDefaults("standard") {
                pointStandardDefaults(at: standard)
                standardIsScratch = UserDefaults.standard === standard
            }
        } catch {
            check(false, "a scratch preferences directory", "\(error)")
        }
        check(standardIsScratch, "UserDefaults.standard is a scratch suite, not ~/Library/Preferences")

        testTheSwitchIsOffUntilTurnedOn()
        // Never on the real domain.
        if standardIsScratch { testTheSharedPreference() }
        testNoOtherDefaultIsAssumed()
        testOnlyStartCreatesTheCentral()
        testTheStackStartsBluetoothOnlyWhenOn()
        testTurningItOnGoesThroughTheStart()
        testTheDenialIsReadWithoutAPrompt()
        testDontAllowStopsTheEngineAndSavesTheSwitchOff()
        testAStartWhileDeniedStartsNothing()
        testTheNoteLastsUntilAllowed()
        testSettingsShowsTheWayToIOSSettings()

        try? FileManager.default.removeItem(at: scratchPrefs)
        check(!FileManager.default.fileExists(atPath: scratchPrefs.path),
              "the scratch preferences directory is deleted")
        check(modified(ownDomainPlist) == ownDomainBefore,
              "nothing written to ~/Library/Preferences/\(ownDomainPlist.lastPathComponent)")

        if failures.isEmpty {
            print("all RTNode Bluetooth default and denial tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
