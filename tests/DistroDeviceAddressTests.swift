// DistroDeviceAddressTests.swift
//
// What reaches the device's own address that only the distro may send
// (RFed SPEC §17.9, §17.11):
//
// - A distro sent copy (FIELD_CUSTOM_TYPE "rfed.distro.sent") is addressed
//   to the distro and reaches a device only through the distro fan-out
//   (RfedDistroClient). One on the device address is forged or misrouted:
//   it is dropped first, whoever sent it, filter on or off, before any name
//   is read or anything is stored, so the user's own message never shows as
//   a DM from the distro. iOS has dropped it since the sent copies came in;
//   Android caught up in v0.1.9 (SentCopyOnDeviceAddressTest). Pinned here.
// - A distro identity transfer (FIELD_CUSTOM_TYPE "rfed.distro.transfer")
//   on the device address is offered only when the privacy filter lets its
//   sender through (filter off: anyone; on: an allowlisted row), as the web
//   and Android offer it (James, 2026-10-05), on the router's path and on
//   the NSE import alike. Offered or dropped, it is never a message. Until
//   2026-10-05 iOS offered it from anyone, so any stranger could put the
//   Import Distro Identity prompt in front of the user.
//
// Run from the workspace root with:
//
//   swiftc -parse-as-library -o /private/tmp/claude-501/distro-device-address \
//     Retichat-ios/tests/DistroDeviceAddressTests.swift && \
//     /private/tmp/claude-501/distro-device-address
//
// The receive paths need SwiftData and the FFI, so they are asserted on the
// source, like DisplayNamesTests.swift; the field decoding is
// LxmfFieldsDistroTransferTests.swift's.

import Foundation

nonisolated(unsafe) var failures: [String] = []

func check(_ ok: Bool, _ what: String) {
    if ok {
        print("ok    - \(what)")
    } else {
        failures.append(what)
        print("FAIL  - \(what)")
    }
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func source(_ path: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

/// `a` appears, and before `b`.
func before(_ text: String, _ a: String, _ b: String) -> Bool {
    guard let ra = text.range(of: a), let rb = text.range(of: b) else { return false }
    return ra.lowerBound < rb.lowerBound
}

func body(_ text: String, _ signature: String) -> String {
    guard let start = text.range(of: signature) else { return "" }
    let rest = text[start.upperBound...]
    let ends = ["\n    func ", "\n    private func ", "\n    @MainActor func ", "\n    // MARK: -", "\n    /// "]
        .compactMap { rest.range(of: $0)?.lowerBound }
    return String(rest[..<(ends.min() ?? rest.endIndex)])
}

let repo = source("Retichat/Services/ChatRepository.swift")

func testTheSentCopyIsDroppedFirst() {
    let incoming = body(repo, "private func handleIncomingMessage(")
    check(incoming.contains("if fields.isDistroSentCopy {\n            print(\"[Retichat] handleIncomingMessage: DROPPED distro sent-copy marker outside fan-out")
            && incoming.contains("outside fan-out src=\\(srcHex.prefix(8))\")\n            return\n        }"),
          "a sent copy on the device address is dropped")
    for later in ["LxmfClient.decodeDisplayName(fieldsRaw: fieldsRaw)", "if let groupId = fields.groupId",
                  "let allowlist = allowlistDecision(destHash: srcHex)", "storeIncomingDirect("] {
        check(before(incoming, "if fields.isDistroSentCopy {", later),
              "before anything else: \(later.prefix(40))")
    }
    let nse = body(repo, "func importNSEMessages()")
    check(before(nse, "if fields.isDistroSentCopy {", "if let groupId = fields.groupId")
            && before(nse, "if fields.isDistroSentCopy {", "let allowlist = allowlistDecision(destHash: srcHex)"),
          "the NSE import drops one too, before the group and allowlist paths")
}

func testTheTransferGoesThroughTheFilter() {
    let offer = body(repo, "private func offerDistroTransfer(")
    check(before(offer, "guard isAllowlisted(destHash: srcHex) else {", "RfedDistroClient.shared.offerTransfer(")
            && offer.contains("DROPPED distro identity transfer from"),
          "a transfer is offered only when the privacy filter lets its sender through")
    let incoming = body(repo, "private func handleIncomingMessage(")
    check(incoming.contains("if let key = fields.distroTransferKey {\n            offerDistroTransfer(fromHashHex: srcHex, privateKeyHex: key, via: \"handleIncomingMessage\")\n            return\n        }"),
          "the router's path offers it through the filter, and never as a message")
    check(!incoming.contains("RfedDistroClient.shared.offerTransfer("), "never straight past the filter")
    let nse = body(repo, "func importNSEMessages()")
    check(nse.contains("offerDistroTransfer(fromHashHex: srcHex, privateKeyHex: key, via: \"importNSEMessages\")"),
          "the NSE import's transfer in its fields goes through the filter")
    check(before(nse, "let filterAllows = isAllowlisted(destHash: srcHex)", "PendingNotification.takeDistroTransferKey(messageHash: msgHash)")
            && before(nse, "guard filterAllows else {", "RfedDistroClient.shared.offerTransfer(fromHashHex: srcHex, privateKeyHex: key)"),
          "a transfer the NSE kept in the Keychain is taken out (cleared) and offered only through the filter")
    check(repo.components(separatedBy: "RfedDistroClient.shared.offerTransfer(").count == 3,
          "no other path offers a transfer on the device address")
}

@main
struct DistroDeviceAddressTestsMain {
    static func main() {
        testTheSentCopyIsDroppedFirst()
        testTheTransferGoesThroughTheFilter()
        if failures.isEmpty {
            print("all distro device-address tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
