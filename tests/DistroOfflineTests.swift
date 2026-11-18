// DistroOfflineTests.swift
//
// Offline use of a distro address (RFed-rust SPEC.md §17.15, James 2026-11-17): the rules
// DistroOffline decides by (DistroOfflineRules.swift, run for real), and how it is wired to the
// bridge and to the app (pins on the source). Retichat-android's DistroOfflineTest.kt, case for
// case.
//
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/distro-offline \
//     Retichat-ios/Retichat/Services/DistroOfflineRules.swift \
//     Retichat-ios/tests/DistroOfflineTests.swift && \
//     /private/tmp/claude-501/distro-offline
//
// (Give swiftc absolute paths when the checkout is not Retichat-ios: the pins find the source
// next to this file.)

import Foundation

nonisolated(unsafe) var failures: [String] = []
nonisolated(unsafe) var checks = 0
nonisolated(unsafe) var currentTest = ""

func check(_ condition: Bool, _ what: String, file: String = #fileID, line: UInt = #line) {
    checks += 1
    if !condition {
        failures.append("\(currentTest): \(what)")
        print("FAIL: \(currentTest): \(what) (\(file):\(line))")
    }
}

func checkEqual<T: Equatable>(_ a: T, _ b: T, _ what: String, line: UInt = #line) {
    check(a == b, "\(what): got \(a), want \(b)", line: line)
}

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func source(_ path: String) -> String {
    (try? String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

let rnodes: Set<String> = ["LoRa RNode"]

// MARK: - The rules

func aRandomPartIsSixteenLowercaseHexCharacters() {
    check(DistroOfflineRules.isRandomPart("0123456789abcdef"), "16 lowercase hex")
    check(!DistroOfflineRules.isRandomPart("0123456789ABCDEF"), "not uppercase")
    check(!DistroOfflineRules.isRandomPart("0123456789abcde"), "not 15")
    check(!DistroOfflineRules.isRandomPart("0123456789abcdef0"), "not 17")
    check(!DistroOfflineRules.isRandomPart("0123456789abcdeg"), "not g")
}

func aMeshConnectionIsAnRtnodeOverBluetoothOrASavedRnodeAndEveryOtherIsInternet() {
    check(DistroOfflineRules.isMesh("PrnsBLE[0a1b2c3d4e5f60718293a4b5c6d7e8f9]", rnodeNames: rnodes), "an RTNode over Bluetooth")
    check(DistroOfflineRules.isMesh("LoRa RNode", rnodeNames: rnodes), "a saved RNode")
    for internet in ["Default Public Endpoints", "Home", "AutoInterface[Local network]", "AutoInterfacePeer[en0/fe80::1]"] {
        check(!DistroOfflineRules.isMesh(internet, rnodeNames: rnodes), "\(internet) is an internet connection")
    }
}

func offlineNeedsTheToggleADistroRfedNotReachedAndNoInternetConnectionUp() {
    let mesh = ["PrnsBLE[00]"]
    check(DistroOfflineRules.offline(enabled: true, holdsDistro: true, rfedReached: false, online: mesh, rnodeNames: rnodes), "offline")
    check(DistroOfflineRules.offline(enabled: true, holdsDistro: true, rfedReached: false, online: [], rnodeNames: rnodes),
          "no interface at all is no internet either")
    check(!DistroOfflineRules.offline(enabled: false, holdsDistro: true, rfedReached: false, online: mesh, rnodeNames: rnodes),
          "the toggle is off by default")
    check(!DistroOfflineRules.offline(enabled: true, holdsDistro: false, rfedReached: false, online: mesh, rnodeNames: rnodes), "no distro")
    check(!DistroOfflineRules.offline(enabled: true, holdsDistro: true, rfedReached: true, online: mesh, rnodeNames: rnodes), "RFed reached")
    check(!DistroOfflineRules.offline(enabled: true, holdsDistro: true, rfedReached: nil, online: mesh, rnodeNames: rnodes),
          "nothing known of RFed yet")
    // James: "it cannot be triggered by RFed disconnect alone".
    check(!DistroOfflineRules.offline(enabled: true, holdsDistro: true, rfedReached: false, online: mesh + ["Home"], rnodeNames: rnodes),
          "an internet connection up")
}

func theLinkToRfedSaysReachedNotReachedOrNeitherAndAClosedSlowRouteIsNeither() {
    checkEqual(DistroOfflineRules.reached(3), true, "ACTIVE")
    checkEqual(DistroOfflineRules.reached(5), true, "RECOVERED")
    checkEqual(DistroOfflineRules.reached(4), false, "DISCONNECTED")
    // NONE: a link closed on purpose (a slow route closes its link after its requests), or none at all.
    checkEqual(DistroOfflineRules.reached(0), nil, "NONE")
    checkEqual(DistroOfflineRules.reached(1), nil, "PATH_REQUESTED")
    checkEqual(DistroOfflineRules.reached(2), nil, "ESTABLISHING")
}

func theLookupNamesTheDevicesOwnAddressFirstThenItsSiblingsOnce() {
    checkEqual(DistroOfflineRules.lookup(own: "aaaaaaaaaaaaaaaa", siblings: []), ["aaaaaaaaaaaaaaaa"], "own alone")
    checkEqual(DistroOfflineRules.lookup(own: "aaaaaaaaaaaaaaaa", siblings: ["aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb"]),
               ["aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb"], "own first, once")
}

func aSenderAsksOnlyWithAMeshConnectionUpAndOncePerComingUpUnlessItHeardFromTheDistro() {
    check(DistroOfflineRules.asks(meshUp: true, askedSince: false, heardSince: false), "asks")
    check(!DistroOfflineRules.asks(meshUp: false, askedSince: false, heardSince: false), "no mesh connection")
    check(!DistroOfflineRules.asks(meshUp: true, askedSince: true, heardSince: false), "asked already")
    check(!DistroOfflineRules.asks(meshUp: true, askedSince: false, heardSince: true), "heard already")
}

func aMessageWaitsForRfedUntilTheRouterHasHandedItToTheNode() {
    for state in [0, 1, 2] { check(DistroOfflineRules.waitingForRfed(state), "state \(state) waits") }
    for state in [4, 8, 0xFF, -1] { check(!DistroOfflineRules.waitingForRfed(state), "state \(state) does not") }
}

// MARK: - Wiring

func everyNewFunctionHasItsRustSymbolAndTheBridgeCallsIt() {
    let header = source("Retichat/Bridge/CRetichatFFI.h")
    let bridge = source("Retichat/Bridge/RetichatBridge.swift")
    let rust = source("rust/retichat-ffi/src/lib.rs")
    for name in ["retichat_distro_direct_register", "retichat_distro_direct_unregister", "retichat_distro_direct_hold",
                 "retichat_distro_direct_set_app_data", "retichat_distro_direct_announce", "retichat_distro_direct_sign",
                 "retichat_propagation_build_direct_upload", "retichat_distro_direct_copy", "retichat_distro_direct_send",
                 "retichat_distro_direct_ask", "retichat_distro_direct_watch", "retichat_online_interfaces",
                 "retichat_interface_edges_register", "retichat_interface_edges_clear"] {
        check(header.contains(" \(name)(") || header.contains("*\(name)("), "\(name) is declared in the header")
        check(rust.contains("pub extern \"C\" fn \(name)("), "\(name) has its Rust symbol")
        check(bridge.contains("\(name)("), "\(name) is called by the bridge")
    }
    // The answer's bits are the crate's.
    check(bridge.contains("static let held: Int32 = 1") && bridge.contains("static let back: Int32 = 2"), "the bridge's bits")
    let direct = source("rust/retichat-ffi/src/distro_direct.rs")
    check(direct.contains("pub const HELD: u8 = 1;") && direct.contains("pub const BACK: u8 = 2;"), "the crate's bits")
    // The same module as Retichat-android's, apart from its header.
    check(direct.contains("The same code as\n//! Retichat-android's `rust/retichat-jni/src/distro_direct.rs`."), "it says whose twin it is")
}

func aSendGoesFromOnePlaceAndAFailureIsNeverSentAgain() {
    let offline = source("Retichat/Services/DistroOffline.swift")
    // DESIGN_PRINCIPLES §3: one call site sends; the outcome handler sends nothing.
    checkEqual(offline.components(separatedBy: "bridge.distroDirectSend(").count - 1, 1, "one send")
    guard let from = offline.range(of: "private func sent("), let to = offline.range(of: "private func waiting(") else {
        check(false, "the outcome handler is in the source")
        return
    }
    let sent = String(offline[from.lowerBound..<to.lowerBound])
    for text in ["distroDirectSend", "send(", "sendKept("] { check(!sent.contains(text), "the outcome sends nothing: \(text)") }
    check(sent.contains("if !deliveredNow || back { live[d]?.remove(random) }"), "a failure, or a device back, is no longer live")
}

func theDeviceAnnouncesOnlyOnItsMeshConnectionsAndNeverOnATimer() {
    let offline = source("Retichat/Services/DistroOffline.swift")
    checkEqual(offline.components(separatedBy: "bridge.distroDirectAnnounce(").count - 1, 1, "one announce call")
    for call in ["announce(pair, on: meshUp,", "announce(pair, on: online.filter(isMesh), why: \"it went offline\")",
                 "announce(pair, on: online.filter(isMesh), why: \"it is back\")"] {
        check(offline.contains(call), "announced on mesh connections only: \(call)")
    }
    for timer in ["Timer", "asyncAfter", "Task.sleep", "schedule"] { check(!offline.contains(timer), "no timer: \(timer)") }
}

func theStackStartsAndStopsItAndTheDistroSendsHandItEachMessage() {
    let repo = source("Retichat/Services/ChatRepository.swift")
    check(repo.contains("DistroOffline.shared.start("), "started with the stack")
    if let outboxStop = repo.range(of: "DistroOutboxRuntime.shared.stop()"), let stop = repo.range(of: "DistroOffline.shared.stop()") {
        check(outboxStop.lowerBound < stop.lowerBound, "stopped with the stack, after the outbox")
    } else {
        check(false, "stopped with the stack")
    }
    // The text message and the reaction, each only to a distro address, once it has gone to the router.
    checkEqual(repo.components(separatedBy: "if toDistro { offlineRef.sentToDistro(").count - 1, 2, "both sends to a distro")
    // The two sends and the fall-back to RFed (2026-11-18).
    checkEqual(repo.components(separatedBy: "let offlineRef = DistroOffline.shared").count - 1, 3, "each captured on the main actor")
    check(repo.contains("offline.fallbackSent(peer: peer, handle: copy, messageId: hashHex, release: { DistroMessageFFI.destroy(copy) })"),
          "a message that went direct first and fell back to RFed gets its copy too")
    // What comes direct is opened and kept as RFed's blobs are, and owed only when new.
    let client = source("Retichat/Services/RfedDistroClient.swift")
    check(client.contains("nonisolated static func takeDirect(sealed: Data, stamp: Data) -> Bool {\n        blobQueue.sync {"),
          "taken on the blobs' own queue")
    check(client.contains("let held = unwrapAndDeliver(sealed, shownByNSE: false, receivedDirect: {"), "opened and routed as RFed's blobs are")
    check(client.contains("DistroOutboxRuntime.shared.oweDirect("), "owed")
    check(client.contains("} else if let hash = parsed.hash, hash.count == 64 {"), "what RFed brings settles it")
    check(client.contains("            DistroOutboxRuntime.brought(hash)"), "through the outbox runtime")
    check(client.contains("Self.blobQueue.async { DistroOutboxRuntime.pulled() }"), "a drained pull lets it go up")
}

/// 2026-11-18 (James: "Yes, build it"): the device announces its lookup address with its offline
/// address while offline, and the sender watches each distro it knows, so the lookup and kept
/// offline addresses pass the app's drop of announces.
func theDeviceAnnouncesItsLookupAndTheSenderWatchesEachDistroItKnows() {
    let direct = source("rust/retichat-ffi/src/distro_direct.rs")
    check(direct.contains(".find(|h| h.offline == offline && !h.back).map(|h| h.lookup.clone())"),
          "the lookup is announced only while the device is offline, never once it is back")
    check(direct.contains("AppLinks::announce_held(&lookup, None, interfaces)"), "on the same mesh connections as the offline address")
    check(direct.contains("Transport::watch_announce(hash.clone());"), "watched addresses pass the drop of announces")
    let offline = source("Retichat/Services/DistroOffline.swift")
    checkEqual(offline.components(separatedBy: "bridge.distroDirectWatch(").count - 1, 1, "one watch call site")
    check(offline.contains("for d in UserPreferences.knownDistroContacts() { self.watch(d) }"), "at start, every distro known")
    check(offline.contains("    private func makeCopy(_ d: String, handle: UInt64, messageId: String, release: (() -> Void)?) {\n        watch(d)"),
          "at each send to a distro")
    check(offline.contains("            say(\"kept \\(d.prefix(8))'s offline address \\(random) (§17.15)\")\n            watch(d)"),
          "when it keeps an address it heard announced")
    check(offline.contains("        watch(d)\n        sendKept(d, to: named)"), "when a lookup names addresses")
    check(offline.contains("if copy.afterAsk || waiting(copy) { kept.append(copy) } else { copy.release?() }"),
          "a fall-back's clone is let go once its copy is dropped")
}

let tests: [(String, () -> Void)] = [
    ("a random part is sixteen lowercase hex characters", aRandomPartIsSixteenLowercaseHexCharacters),
    ("a mesh connection is an RTNode over Bluetooth or a saved RNode, and every other is internet", aMeshConnectionIsAnRtnodeOverBluetoothOrASavedRnodeAndEveryOtherIsInternet),
    ("offline needs the toggle, a distro, RFed not reached and no internet connection up", offlineNeedsTheToggleADistroRfedNotReachedAndNoInternetConnectionUp),
    ("the link to RFed says reached, not reached or neither, and a closed slow route is neither", theLinkToRfedSaysReachedNotReachedOrNeitherAndAClosedSlowRouteIsNeither),
    ("the lookup names the device's own address first, then its siblings, once", theLookupNamesTheDevicesOwnAddressFirstThenItsSiblingsOnce),
    ("a sender asks only with a mesh connection up, once per coming-up, unless it heard from the distro", aSenderAsksOnlyWithAMeshConnectionUpAndOncePerComingUpUnlessItHeardFromTheDistro),
    ("a message waits for RFed until the router has handed it to the node", aMessageWaitsForRfedUntilTheRouterHasHandedItToTheNode),
    ("every new function has its Rust symbol, and the bridge calls it", everyNewFunctionHasItsRustSymbolAndTheBridgeCallsIt),
    ("a send goes from one place and a failure is never sent again", aSendGoesFromOnePlaceAndAFailureIsNeverSentAgain),
    ("the device announces only on its mesh connections and never on a timer", theDeviceAnnouncesOnlyOnItsMeshConnectionsAndNeverOnATimer),
    ("the stack starts and stops it, and the distro sends hand it each message", theStackStartsAndStopsItAndTheDistroSendsHandItEachMessage),
    ("the device announces its lookup and the sender watches each distro it knows", theDeviceAnnouncesItsLookupAndTheSenderWatchesEachDistroItKnows),
]

@main
enum DistroOfflineTests {
    static func main() {
        for (name, run) in tests {
            currentTest = name
            let before = failures.count
            run()
            print(failures.count == before ? "ok    - \(name)" : "FAIL  - \(name)")
        }
        print("\n\(tests.count) tests, \(checks) checks, \(failures.count) failure(s)")
        exit(failures.isEmpty ? 0 : 1)
    }
}
