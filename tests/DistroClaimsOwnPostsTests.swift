// DistroClaimsOwnPostsTests.swift
//
// A channel post from the distro that arrived before this device held it was
// stored as another poster's, with the distro's hash as its label, and stayed
// so (James, 2026-10-20: "iOS doesn't recognize that a Channel message sent
// from Distro on one device belongs to the same Distro on another device").
// Once the device holds the distro (at launch, or a later transfer or
// import), those posts are the user's own: outgoing, SENT, in the store and
// on screen.
//
// Run from the workspace root with:
//
//     swift Retichat-ios/tests/DistroClaimsOwnPostsTests.swift
//
// Source-level: RfedChannelClient needs SwiftData, the FFI and a stack.

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
let client = (try? String(contentsOf: root.appendingPathComponent("Retichat/Services/RfedChannelClient.swift"), encoding: .utf8)) ?? ""

func body(_ signature: String) -> String {
    guard let start = client.range(of: signature) else { return "" }
    let rest = client[start.upperBound...]
    let next = ["\n    func ", "\n    private func ", "\n    nonisolated ", "\n    // MARK"]
        .compactMap { rest.range(of: $0)?.lowerBound }.min() ?? rest.endIndex
    return String(client[start.lowerBound..<next])
}

func inOrder(_ text: String, _ parts: [String]) -> Bool {
    var from = text.startIndex
    for part in parts {
        guard let r = text.range(of: part, range: from..<text.endIndex) else { return false }
        from = r.upperBound
    }
    return true
}

// 1. Watched from the first start, with the distro held then and at every change.
let start = body("func start()")
check(inOrder(start, [
    "didLoadPersistedState = true",
    "heldDistroWatch = RfedDistroClient.shared.$distro",
    ".map { $0?.deliveryHashHex }",
    ".removeDuplicates()",
    "guard let hex else { return }",
    "self?.claimDistroPosts(distroHex: hex)",
]), "start watches the distro the device holds, once the store is loaded")

// 2. The store: only the distro's posts stored as another poster's.
let claim = body("private func claimDistroPosts(")
check(claim.contains("#Predicate { $0.senderHash == hex && $0.isOutgoing == false }"),
      "the distro's posts stored as another poster's are found")
check(inOrder(claim, ["for e in rows {", "e.isOutgoing = true",
                      "e.deliveryState = Self.verifiedChannelMessageDeliveryState(isOutgoing: true)", "try? ctx.save()"]),
      "and stored as the user's own, SENT, as an own post that arrives now")
check(claim.contains("let hex = distroHex.lowercased()"), "stored senders are lowercase hex: the distro's is too")

// 3. On screen: the same posts in memory.
check(inOrder(claim, ["messages[channel] = list.map { msg in",
                      "guard !msg.isOutgoing, msg.senderHash.lowercased() == hex else { return msg }",
                      "own.isOutgoing = true"]),
      "the posts shown change at once, not at the next launch")

// 4. Arrival keeps the rule it had: decided then, against the distro held then.
check(client.contains("let isOutgoing = DistroCodec.isOwnChannelPost(sourceHex: senderHashHex, deviceHex: ownHashHex, distroHex: distroHex)"),
      "a post arriving now is still judged at arrival")

if failures.isEmpty {
    print("\nall passed")
} else {
    print("\n\(failures.count) failed")
    exit(1)
}
