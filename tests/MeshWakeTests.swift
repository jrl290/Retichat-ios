// MeshWakeTests.swift
//
// This device as its own RFed Notify relay, so RFed can wake it over the
// mesh (James, 2026-10-23: "have rfed send the notify ping directly to the
// requesting device as well. Then RTNode would be able to push those
// notifications to wake Retichat at low power"; then "build the direct mesh
// wake in Retichat for iOS first"). RFed already wakes every relay a device
// registers, a self-hosted one included (RFed-rust notify/rns.rs
// remember_self_hosted_relay); the app did not host one.
//
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/mesh-wake \
//     Retichat-ios/Retichat/Services/MeshWake.swift \
//     Retichat-ios/tests/MeshWakeTests.swift && \
//     /private/tmp/claude-501/mesh-wake
//
// The rules are pure; the FFI, the registrar, the stack and the app
// delegate are asserted on their source, like BluetoothRestorationTests.swift.

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

func testWanted() {
    check(!MeshWake.wanted(savedRNode: false, rtnodeSwitchOn: false),
          "no Bluetooth radio: no relay of its own (APNs only)")
    check(MeshWake.wanted(savedRNode: true, rtnodeSwitchOn: false), "an enabled saved RNode: hosted")
    check(MeshWake.wanted(savedRNode: false, rtnodeSwitchOn: true), "the Nearby RTNode switch on: hosted")
    check(MeshWake.wanted(savedRNode: true, rtnodeSwitchOn: true), "and with both")
}

func hash(_ byte: UInt8) -> Data { Data(repeating: byte, count: 16) }

/// msgpack as RFed's encode_wake_payload writes it: str keys, bin8 values.
func key(_ s: String) -> Data { Data([0xa0 | UInt8(s.utf8.count)]) + Data(s.utf8) }
func bin(_ d: Data) -> Data { Data([0xc4, UInt8(d.count)]) + d }

func testParse() {
    let receiver = hash(0x11), sender = hash(0x22), channel = hash(0x33)

    let lxmf = Data([0x82]) + key("receiver") + bin(receiver) + key("sender") + bin(sender)
    check(MeshWake.parse(lxmf) == MeshWake.Wake(receiver: receiver, sender: sender, channel: nil),
          "an LXMF wake: receiver and sender")

    let distro = Data([0x81]) + key("receiver") + bin(receiver)
    check(MeshWake.parse(distro) == MeshWake.Wake(receiver: receiver, sender: nil, channel: nil),
          "a distro wake: the receiver alone")

    let chan = Data([0x82]) + key("channel") + bin(channel) + key("receiver") + bin(receiver)
    check(MeshWake.parse(chan)?.channel == channel, "a channel wake, keys in any order")

    let map16 = Data([0xde, 0x00, 0x01]) + key("receiver") + bin(receiver)
    check(MeshWake.parse(map16)?.receiver == receiver, "a map16 header")

    let later = Data([0x83]) + key("receiver") + bin(receiver)
        + key("message") + bin(Data(repeating: 0x44, count: 32))
        + key("count") + Data([0x05])
    check(MeshWake.parse(later)?.receiver == receiver,
          "fields RFed adds later (a 32-byte bin, an int) do not stop the wake")

    // RFed-spec Notify.md 1cd0e63: the wake names its message by its
    // transient id, and an LXMF wake names no sender.
    let message = Data(repeating: 0x44, count: 32)
    let named = Data([0x82]) + key("receiver") + bin(receiver) + key("message") + bin(message)
    check(MeshWake.parse(named) == MeshWake.Wake(receiver: receiver, sender: nil, channel: nil, message: message),
          "a wake names its message")
    check(MeshWake.parse(Data([0x82]) + key("receiver") + bin(receiver) + key("message") + bin(hash(0x44)))?.message
            == nil,
          "a message id that is not 32 bytes is left out, and the wake goes on")

    check(MeshWake.parse(Data([0x81]) + key("sender") + bin(sender)) == nil, "no receiver: dropped")
    check(MeshWake.parse(Data([0x81]) + key("receiver") + bin(Data(repeating: 1, count: 8))) == nil,
          "a receiver that is not 16 bytes: dropped")
    check(MeshWake.parse(Data([0x81]) + key("receiver") + key("0123456789abcdef")) == nil,
          "a receiver as a string, not bin: dropped")
    check(MeshWake.parse(distro + Data([0x00])) == nil, "trailing bytes: dropped")
    check(MeshWake.parse(Data([0x82]) + key("receiver") + bin(receiver)) == nil, "a short map: dropped")
    check(MeshWake.parse(Data()) == nil, "empty: dropped")
    check(MeshWake.parse(Data([0x93, 0x01, 0x02, 0x03])) == nil, "not a map: dropped")
    check(MeshWake.parse(Data([0x81]) + key("receiver") + Data([0xc4, 0x10, 0x01])) == nil,
          "a cut-off value: dropped")
}

// MARK: - The source

func sourceFile(_ components: [String]) -> String? {
    let url = components.reduce(
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    ) { $0.appendingPathComponent($1) }
    do {
        return try String(contentsOf: url, encoding: .utf8)
    } catch {
        check(false, "reads \(components.joined(separator: "/"))", String(describing: error))
        return nil
    }
}

/// From `marker` up to the next member function or the end of its type.
func member(_ source: String, _ marker: String) -> String {
    guard let start = source.range(of: marker) else { return "" }
    let rest = source[start.upperBound...]
    let ends = ["\n    func ", "\n    private func ", "\n    @MainActor func ", "\n    @MainActor\n", "\n}\n",
                "\n#[no_mangle]", "\n#[cfg(test)]"]
        .compactMap { rest.range(of: $0)?.lowerBound }
    return String(rest[..<(ends.min() ?? rest.endIndex)])
}

func ordered(_ text: String, _ needles: [String]) -> Bool {
    var from = text.startIndex
    for needle in needles {
        guard let r = text.range(of: needle, range: from..<text.endIndex) else { return false }
        from = r.upperBound
    }
    return true
}

func testFFI() {
    guard let rust = sourceFile(["rust", "retichat-ffi", "src", "lib.rs"]),
          let header = sourceFile(["Retichat", "Bridge", "CRetichatFFI.h"]),
          let bridge = sourceFile(["Retichat", "Bridge", "RetichatBridge.swift"]) else { return }

    let destination = member(rust, "fn notify_relay_destination(")
    check(ordered(destination, ["Destination::new_inbound(", "DestinationType::Single", "\"rfed\"", "\"notify\""]),
          "FFI: the relay is rfed.notify, inbound, under the device's identity")
    let start = member(rust, "pub extern \"C\" fn retichat_notify_relay_start(")
    check(ordered(start, ["set_packet_callback(", "Transport::register_destination(", "Transport::publish_destination("]),
          "FFI: each wake goes to the callback; registered, then published so RFed has a path")
    check(start.contains("from_secs(30 * 60)") && start.contains("None,\n    );"),
          "FFI: refreshed every 30 minutes like lxmf.delivery, with no app_data (DESIGN_PRINCIPLES §9)")
    check(!start.contains("set_proof_strategy"), "FFI: wakes are not proved (RFed sends them unproved)")
    check(member(rust, "pub extern \"C\" fn retichat_notify_relay_stop(").contains("Transport::unpublish_destination("),
          "FFI: stop unpublishes it")
    check(header.contains("int32_t retichat_notify_relay_start(") && header.contains("int32_t retichat_notify_relay_stop(void);"),
          "header: both declared")
    check(bridge.contains("NotificationCenter.default.post(name: MeshWake.received"),
          "bridge: each wake is posted as MeshWake.received")
}

func testRegistrar() {
    guard let registrar = sourceFile(["Retichat", "Services", "RfedNotifyRegistrar.swift"]) else { return }
    let register = member(registrar, "func registerMeshRelay(")
    check(register.contains("operation: \"register\"") && register.contains("channelHash: nil"),
          "registrar: the relay is registered for LXMF wakes (direct messages and the distro)")
    check(register.contains("registrations.owe("), "registrar: owed to the node like the push relay's")
    let unregister = member(registrar, "func unregisterMeshRelay(")
    check(unregister.contains("operation: \"unregister\"") && unregister.contains(".owe("),
          "registrar: the unregistration is owed too, sent on an established rfed.link")
    check(unregister.contains("path: \"/notify/unregister\""), "registrar: on /notify/unregister")
    check(unregister.contains("prefs.meshWakeRelayHex = nil"), "registrar: and forgotten once rfed proves it")
    check(member(registrar, "func deregisterFrom(").contains("prefs.meshWakeRelayHex"),
          "registrar: a node change unregisters the mesh relay from the old node too")
}

func testStack() {
    guard let repo = sourceFile(["Retichat", "Services", "ChatRepository.swift"]) else { return }
    let finish = member(repo, "private func finishStartService(")
    check(ordered(finish, ["publishClient.publish(refreshSecs:", "setUpMeshWake(client: client)",
                           "RTNodeBluetoothCoordinator.shared.start("]),
          "stack: hosted after the lxmf.delivery publish, before the RTNode starts (its up-edge announces it)")
    let setUp = member(repo, "private func setUpMeshWake(")
    check(setUp.contains("MeshWake.wanted(savedRNode: hasEnabledRNode, rtnodeSwitchOn: prefs.rtnodeBluetoothEnabled)"),
          "stack: only with a Bluetooth radio configured")
    check(ordered(setUp, ["meshWakeStart(identityHandle:", "meshWakeRelayHex = relayHex", "registerMeshRelay("]),
          "stack: hosted first, then remembered and registered")
    check(setUp.contains("unregisterMeshRelay("), "stack: with no radio, a relay registered before is unregistered")
    let stop = member(repo, "func stopService(")
    check(ordered(stop, ["meshWakeStop()", "client?.shutdown()"]), "stack: stopped before the stack shuts down")
}

func testAppDelegate() {
    guard let app = sourceFile(["Retichat", "RetichatApp.swift"]) else { return }
    let launch = member(app, "didFinishLaunchingWithOptions launchOptions:")
    check(ordered(launch, ["forName: MeshWake.received", "MeshWake.parse(", "wake.receiver == self.repository.ownHash",
                           "collectAfterWake("]),
          "app: a mesh wake for this device collects, as a push does")
    let push = member(app, "didReceiveRemoteNotification userInfo:")
    check(push.contains("self.collectAfterWake(isActive: isActive)"), "app: the push path shares it")
    let collect = member(app, "private func collectAfterWake(")
    check(collect.contains("RfedDistroClient.shared.pull()") && collect.contains("pollPropagationNode(force: true)")
              && collect.contains("beginBackgroundExecution(repository: repository, forcePoll: true)"),
          "app: the distro pull, a propagation sync, and background time when not active")
}

@main
enum MeshWakeTests {
    static func main() {
        testWanted()
        testParse()
        testFFI()
        testRegistrar()
        testStack()
        testAppDelegate()

        if failures.isEmpty {
            print("all mesh wake tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
