// BluetoothRestorationTests.swift
//
// iOS keeps a saved RNode's and a nearby RTNode's Bluetooth connection,
// pending connect and scan going after the system ends a suspended Retichat,
// and relaunches it in the background when something happens on one, but
// only for a CBCentralManager made with a restore identifier. Neither had
// one, so once iOS ended the app, a message over Bluetooth waited until the
// user opened it (James, 2026-10-23: can a message arrive in the background
// when Bluetooth to an RNode or RTNode is the only interface? Then "Do this
// task here").
//
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/bluetooth-restoration \
//     Retichat-ios/Retichat/Services/BluetoothRestoration.swift \
//     Retichat-ios/tests/BluetoothRestorationTests.swift && \
//     /private/tmp/claude-501/bluetooth-restoration
//
// The rules are pure; the coordinators and the app delegate need
// CoreBluetooth, UIKit and the FFI, so that they follow them is asserted on
// their source, like RNodeSlotRulesTests.swift does.

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

// MARK: - The rules

func testIdentifiers() {
    check(BluetoothRestoration.rnodeCentral == "com.retichat.rnode.central",
          "the RNode central's restore identifier is fixed",
          BluetoothRestoration.rnodeCentral)
    check(BluetoothRestoration.rtnodeCentral == "com.retichat.rtnode.central",
          "the RTNode central's restore identifier is fixed",
          BluetoothRestoration.rtnodeCentral)
    check(BluetoothRestoration.rnodeCentral != BluetoothRestoration.rtnodeCentral,
          "the two centrals are restored apart")
}

func testRelaunch() {
    let starts = BluetoothRestoration.startsStack(restoringCentrals:)
    check(!starts(nil), "an ordinary launch starts nothing early")
    check(!starts([]), "an empty list starts nothing early")
    check(starts([BluetoothRestoration.rnodeCentral]), "relaunched for an RNode: the stack starts")
    check(starts([BluetoothRestoration.rtnodeCentral]), "relaunched for an RTNode: the stack starts")
    check(starts([BluetoothRestoration.rtnodeCentral, BluetoothRestoration.rnodeCentral]), "and for both")
    check(!starts(["com.example.other"]), "a central that is not ours starts nothing")
}

func testStrays() {
    let a = UUID(), b = UUID(), c = UUID()
    check(BluetoothRestoration.strays(restored: [a, b, c], saved: [a, c]) == [b],
          "a kept connection no saved RNode wants is dropped")
    check(BluetoothRestoration.strays(restored: [a], saved: [a]).isEmpty,
          "a saved RNode's is kept")
    check(BluetoothRestoration.strays(restored: [], saved: [a]).isEmpty,
          "nothing kept, nothing dropped")
}

// MARK: - The source

func sourceFile(_ components: [String]) throws -> String {
    let url = components.reduce(
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    ) { $0.appendingPathComponent($1) }
    return try String(contentsOf: url, encoding: .utf8)
}

/// From `marker` up to the next member function or the end of its type.
func member(_ source: String, _ marker: String) -> String {
    guard let start = source.range(of: marker) else { return "" }
    let rest = source[start.upperBound...]
    let ends = ["\n    func ", "\n    private func ", "\n    @MainActor func ", "\n}\n"]
        .compactMap { rest.range(of: $0)?.lowerBound }
    return String(rest[..<(ends.min() ?? rest.endIndex)])
}

func count(_ text: String, _ needle: String) -> Int {
    text.components(separatedBy: needle).count - 1
}

/// The needles appear in `text` in this order.
func ordered(_ text: String, _ needles: [String]) -> Bool {
    var from = text.startIndex
    for needle in needles {
        guard let r = text.range(of: needle, range: from..<text.endIndex) else { return false }
        from = r.upperBound
    }
    return true
}

func read(_ components: [String]) -> String? {
    do {
        return try sourceFile(components)
    } catch {
        check(false, "reads \(components.joined(separator: "/"))", String(describing: error))
        return nil
    }
}

func testRNodeCoordinator() {
    guard let coord = read(["Retichat", "Services", "RNodeInterfaceCoordinator.swift"]) else { return }

    check(coord.contains("CBCentralManagerOptionRestoreIdentifierKey: BluetoothRestoration.rnodeCentral"),
          "RNode: the central is made under its restore identifier")
    check(count(coord, "CBCentralManager(") == 1, "RNode: one central, still made in start()")

    let restore = member(coord, "willRestoreState dict:")
    check(restore.contains("CBCentralManagerRestoredStatePeripheralsKey"),
          "RNode: willRestoreState takes the connections iOS kept")
    check(restore.contains(".delegate = self"), "RNode: and becomes their delegate")
    check(!restore.contains("cancelPeripheralConnection(") && !restore.contains(".connect("),
          "RNode: and calls nothing on the central before it is powered on")

    let flush = member(coord, "func flushPendingConnects(")
    check(flush.contains("BluetoothRestoration.strays("), "RNode: a kept connection no slot wants is found")
    check(flush.contains("cancelPeripheralConnection("), "RNode: and dropped")
    check(ordered(flush, ["guard let central = central, central.state == .poweredOn", "restored"]),
          "RNode: once the central is powered on")

    let connect = member(coord, "func connect(slot:")
    check(connect.contains("peripheral.state == .connected"),
          "RNode: a kept connection is set up again, not dialled")
    check(connect.contains("central.connect(peripheral, options: nil)"), "RNode: any other is dialled as before")

    let characteristics = member(coord, "didDiscoverCharacteristicsFor service:")
    check(characteristics.contains("tx.isNotifying"),
          "RNode: a kept subscription goes straight on to the radio handshake")
}

func testRTNodeCoordinator() {
    guard let coord = read(["Retichat", "Services", "RTNodeBluetoothCoordinator.swift"]) else { return }

    check(coord.contains("CBCentralManagerOptionRestoreIdentifierKey: BluetoothRestoration.rtnodeCentral"),
          "RTNode: the central is made under its restore identifier")
    check(count(coord, "CBCentralManager(") == 1, "RTNode: one central, still made in start()")

    let restore = member(coord, "willRestoreState dict:")
    check(restore.contains("CBCentralManagerRestoredStatePeripheralsKey"),
          "RTNode: willRestoreState takes the connections iOS kept")
    check(!restore.contains("cancelPeripheralConnection("),
          "RTNode: and calls nothing on the central before it is powered on")

    // The engine starts new and has no link for a kept connection, and none
    // can be made for one (it dials only what it has seen advertise): each
    // is dropped, the RTNode advertises again, and the scan finds it.
    let state = member(coord, "func bluetoothStateChanged(")
    check(ordered(state, ["case .poweredOn:", "dropRestored(", "applyScan()"]),
          "RTNode: on power on, kept connections are dropped before scanning")
    check(member(coord, "func dropRestored(").contains("cancelPeripheralConnection("),
          "RTNode: by cancelling them")
}

func testAppDelegate() {
    guard let app = read(["Retichat", "RetichatApp.swift"]) else { return }

    let launch = member(app, "didFinishLaunchingWithOptions launchOptions:")
    check(launch.contains("launchOptions?[.bluetoothCentrals]"),
          "launch: a Bluetooth relaunch is recognised")
    check(launch.contains("BluetoothRestoration.startsStack(restoringCentrals:"),
          "launch: by the rules")
    check(ordered(launch, ["repository.configure(modelContext:", "BluetoothRestoration.startsStack(",
                           "repository.startService()", "beginBackgroundExecution(repository: repository)"]),
          "launch: the stack starts (re-making both centrals) and is kept running, after the store is set up")
}

@main
enum BluetoothRestorationTests {
    static func main() {
        testIdentifiers()
        testRelaunch()
        testStrays()
        testRNodeCoordinator()
        testRTNodeCoordinator()
        testAppDelegate()

        if failures.isEmpty {
            print("all Bluetooth state restoration tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
