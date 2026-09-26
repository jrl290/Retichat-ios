// NSEDistroPullTests.swift
//
// A push for a distro message (2026-09-26): the NSE pulls the blobs RFed
// queued, saves every one for the app before anything else, and shows the
// newest; the app ingests the saved blobs as a pull of its own. Until then
// the NSE only synced from the propagation node and suppressed the push.
//
// Run from the workspace root with:
//
//   { echo 'import Foundation'; \
//     sed -n '/^\/\/ BEGIN NSEDistroPullDecoder/,/^\/\/ END NSEDistroPullDecoder/p' \
//     Retichat-ios/NotificationService/NSEDistroPull.swift; } \
//     > /private/tmp/claude-501/NSEDistroPullDecoder.swift && \
//   swiftc -o /private/tmp/claude-501/nse-distro-pull \
//     /private/tmp/claude-501/NSEDistroPullDecoder.swift \
//     Retichat-ios/Retichat/Services/PendingNotification.swift \
//     Retichat-ios/tests/NSEDistroPullTests.swift && \
//     /private/tmp/claude-501/nse-distro-pull
//
// The decoder and the blob store run for real (the store against a scratch
// directory, never the App Group). The NSE and app wiring needs UIKit, the
// FFI and SwiftData, so it is asserted on the source, like
// NSEDeliveryHandOffTests.swift.

import Foundation

nonisolated(unsafe) var failures: [String] = []

func check(_ ok: Bool, _ what: String) {
    if !ok { failures.append(what); print("FAIL: \(what)") }
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func source(_ path: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

func bin(_ d: [UInt8]) -> [UInt8] { [0xC4, UInt8(d.count)] + d }

func testDecodesPairsAndMore() {
    let hash = [UInt8](repeating: 0xD1, count: 16)
    let a: [UInt8] = hash + [1, 2, 3]
    let b: [UInt8] = hash + [4, 5]
    let bytes: [UInt8] = [0x92, 0x92] + [0x92] + bin(hash) + bin(a) + [0x92] + bin(hash) + bin(b) + [0xC3]
    guard let (blobs, more) = NSEDistroPullDecoder.decode(Data(bytes)) else {
        check(false, "a well-formed pull response decodes")
        return
    }
    check(blobs == [Data(a), Data(b)], "the blobs, in order")
    check(more, "more pending")

    let empty = NSEDistroPullDecoder.decode(Data([0x92, 0x90, 0xC2]))
    check(empty?.0.isEmpty == true && empty?.1 == false, "an empty pull decodes")
}

func testAnErrorCodeOrTruncationIsNotAPull() {
    check(NSEDistroPullDecoder.decode(Data([0xCC, 0xF2])) == nil, "an error code (bare integer) is not a pull")
    check(NSEDistroPullDecoder.decode(Data([0x92, 0x91, 0x92, 0xC4, 0x10])) == nil, "a truncated response is rejected")
}

func testSavedBlobsComeBackOnceInOrder() {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("nse-distro-blobs-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let a = Data([0xA1, 0xA2]), b = Data(repeating: 0xBB, count: 300), c = Data([0xC3])
    check(PendingNotification.saveNSEDistroBlobs([a, b], in: dir), "round 1 saved")
    Thread.sleep(forTimeInterval: 0.01)   // distinct creation times, so a defined order
    check(PendingNotification.saveNSEDistroBlobs([c], in: dir), "round 2 saved")
    let read = PendingNotification.readAndClearNSEDistroBlobs(in: dir)
    check(read == [a, b, c], "every blob, oldest round first (\(read.map(\.count)))")
    check(PendingNotification.readAndClearNSEDistroBlobs(in: dir).isEmpty, "and only once")
}

func testThePullRouteRoundTrips() {
    let dest = String(repeating: "d7", count: 16)
    let node = String(repeating: "87", count: 16), prop = String(repeating: "0f", count: 16)
    let route = PendingNotification.DistroPullRoute(destination: dest, sources: [node, prop])
    check(PendingNotification.decodeDistroPullRoute(PendingNotification.encodeDistroPullRoute(route)) == route,
          "the route (destination, then its seed sources) round-trips")
    check(PendingNotification.decodeDistroPullRoute(dest)?.sources == [], "a route without sources still names the destination")
    check(PendingNotification.decodeDistroPullRoute("not a hash\n" + node) == nil, "no destination, no route")
}

func testTheWiring() {
    let pull = source("NotificationService/NSEDistroPull.swift")
    let path = pull.range(of: "guard ensurePath(to: dest, from: route.sources")
    let request = pull.range(of: "pullRequest(dest: dest")
    check(path != nil && request != nil && path!.lowerBound < request!.lowerBound,
          "the NSE has a path to rfed.distro.register before its link request (the iPad, 2026-09-26)")
    check(pull.contains("retichat_transport_clone_path_and_identity("),
          "the path is seeded from the node's destinations, as the app does")
    // The iPad, 2026-09-26 20:17 and 22:20: a stored path, trusted, led to a
    // transport node that no longer knew rfed.distro.register after an RFed
    // restart. The NSE asks for the path first and waits for the answer.
    let ensure = pull.range(of: "private static func ensurePath(")
    let ask = pull.range(of: "requestPath(dest)\n        let budget")
    let wait = pull.range(of: "if waitForVerifiedPath(dest, budget: budget)")
    let stored = pull.range(of: "if hasPath(dest) {\n            NSLog(\"[NSE-Distro] path request unanswered; using the stored path\")")
    check(ensure != nil && ask != nil && wait != nil && stored != nil
            && ensure!.lowerBound < ask!.lowerBound && ask!.lowerBound < wait!.lowerBound
            && wait!.lowerBound < stored!.lowerBound,
          "the NSE requests the path and waits for a confirmed one before it falls back to a stored path")
    check(pull.contains("retichat_transport_wait_for_path_verified("),
          "the wait is the stack's event-driven one, not a polling loop")
    let save = pull.range(of: "PendingNotification.saveNSEDistroBlobs(blobs)")
    let unwrap = pull.range(of: "unwrapToShow(blob, distroHandle: distroHandle)")
    check(save != nil && unwrap != nil && save!.lowerBound < unwrap!.lowerBound,
          "the NSE saves every pulled blob before it unwraps any (the pull drained RFed)")

    let nse = source("NotificationService/NotificationService.swift")
    let pulls = nse.range(of: "NSEDistroPull.run(")
    let shows = nse.range(of: "candidates += distro.shown")
    check(pulls != nil && shows != nil && pulls!.lowerBound < shows!.lowerBound,
          "the NSE pulls the distro before it builds the notification")
    let failed = nse.range(of: "} else if distro.failed {")
    let suppress = nse.range(of: "} else if summary.dropped > 0 || distro.pulled > 0 {")
    check(failed != nil && suppress != nil && failed!.lowerBound < suppress!.lowerBound,
          "an incomplete distro pull keeps the alert: it is decided before any suppression")

    let manager = source("Retichat/Services/DistroManager.swift")
    check(manager.components(separatedBy: "shareWithNSE(data)").count == 2, "the key is shared when it loads")
    check(manager.components(separatedBy: "shareWithNSE(key)").count == 2, "and when it is adopted")
    check(manager.components(separatedBy: "shareWithNSE(nil)").count == 3, "and withdrawn when absent or forgotten")

    let client = source("Retichat/Services/RfedDistroClient.swift")
    check(client.contains("destination: registerDestHex, sources: pullRouteSources"),
          "the pull route, with its seed sources, is written once RFed accepts the registration")
    check(client.contains("aspects: [\"node\"]") && client.contains("app: \"lxmf\", aspects: [\"propagation\"]"),
          "the seed sources are rfed.node and the node's lxmf.propagation")
    check(source("Retichat/Services/ChatRepository.swift").contains("RfedDistroClient.importNSEBlobs()"),
          "the app ingests the NSE's blobs with its NSE import")
}

@main
enum NSEDistroPullTests {
    static func main() {
        testDecodesPairsAndMore()
        testAnErrorCodeOrTruncationIsNotAPull()
        testSavedBlobsComeBackOnceInOrder()
        testThePullRouteRoundTrips()
        testTheWiring()
        if failures.isEmpty {
            print("all NSE distro pull tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
