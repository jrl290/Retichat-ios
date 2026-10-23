// NotificationIdsTests.swift
//
// One notification per message (RFed-spec Notify.md "One notification per
// message"; James, 2026-10-23: "include the message id in the notify packet
// so that we can dedup notifications"). An RFed wake names the stored item by
// its transient id, apns-bridge sends that id as the push's apns-collapse-id,
// and the app posts its own notification for the message under the same id,
// so a push, a mesh wake and the message itself make one notification.
//
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/notification-ids \
//     Retichat-ios/Retichat/Services/NotificationIds.swift \
//     Retichat-ios/tests/NotificationIdsTests.swift && \
//     /private/tmp/claude-501/notification-ids
//
// The ids are pure; the FFI, the delivery chain and the notification post are
// asserted on their source, like MeshWakeTests.swift.

import CryptoKit
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

// MARK: - The ids

func testIds() {
    let id = Data((0..<32).map { UInt8($0) })
    check(NotificationIds.requestIdentifier(messageId: id)
            == "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
          "a message id is the request identifier, lowercase hex as apns-bridge writes the collapse id")
    check(NotificationIds.requestIdentifier(messageId: id).count == 64, "64 chars, the apns-collapse-id limit")

    let a = NotificationIds.requestIdentifier(messageId: nil)
    let b = NotificationIds.requestIdentifier(messageId: nil)
    check(a != b && UUID(uuidString: a) != nil, "no message id: a fresh identifier each time, as before")
    check(UUID(uuidString: NotificationIds.requestIdentifier(messageId: Data(repeating: 1, count: 16))) != nil,
          "an id that is not 32 bytes is not used")

    let blob = Data("a distro blob".utf8)
    check(NotificationIds.transientId(of: blob) == Data(SHA256.hash(data: blob)),
          "a blob's transient id is its SHA-256, as RFed names it")
    check(NotificationIds.transientId(of: blob).count == 32, "32 bytes")
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
    let ends = ["\n    func ", "\n    private func ", "\n    @MainActor func ", "\n    @discardableResult\n",
                "\n    nonisolated ", "\n}\n", "\n#[no_mangle]", "\n#[cfg(test)]"]
        .compactMap { rest.range(of: $0)?.lowerBound }
    return String(rest[..<(ends.min() ?? rest.endIndex)])
}

func testFFI() {
    guard let rust = sourceFile(["rust", "retichat-ffi", "src", "lib.rs"]),
          let header = sourceFile(["Retichat", "Bridge", "CRetichatFFI.h"]),
          let bridge = sourceFile(["Retichat", "Bridge", "RetichatBridge.swift"]) else { return }
    check(member(rust, "fn deliver_with_receipt(").contains("optional_bytes(message.transient_id.as_deref())"),
          "the glue crate gives the host the router's transient id")
    check(header.contains("const uint8_t *packed, uint32_t packed_len,\n    const uint8_t *transient_id, uint32_t transient_id_len);"),
          "the callback's last arguments are the transient id")
    let trampoline = member(bridge, "private func deliveryTrampoline(")
    check(trampoline.contains("transientId: UnsafePointer<UInt8>?, transientIdLen: UInt32"),
          "the trampoline takes them")
    check(trampoline.contains("transientId: transientIdData"), "and hands the id on")
    check(member(bridge, "func handleDelivery(").contains("transientId: transientId"),
          "handleDelivery passes it to the message callback")
    if let nse = sourceFile(["NotificationService", "NotificationService.swift"]) {
        check(member(nse, "private func nseDeliveryTrampoline(")
                .contains("transientId: UnsafePointer<UInt8>?, transientIdLen: UInt32"),
              "the NSE's trampoline has the callback's type too")
    }
}

func testDeliveryChain() {
    guard let repo = sourceFile(["Retichat", "Services", "ChatRepository.swift"]),
          let distro = sourceFile(["Retichat", "Services", "RfedDistroClient.swift"]),
          let channel = sourceFile(["Retichat", "Services", "RfedChannelClient.swift"]) else { return }
    check(member(repo, "@MainActor func onMessage(").contains("transientId: transientId"),
          "a delivered message's id reaches handleIncomingMessage")
    check(member(repo, "private func handleIncomingMessage(").contains("transientId: transientId"),
          "and storeIncomingDirect")
    check(member(repo, "private func storeIncomingDirect(").contains("messageId: transientId"),
          "which notifies under it")
    check(member(repo, "private func handleDistroMessage(").contains("transientId: m.transientId"),
          "a distro message is notified under its blob's id")
    check(member(distro, "nonisolated private static func unwrapAndDeliver(")
            .contains("message.transientId = NotificationIds.transientId(of: blob)"),
          "the distro client names a message by its blob's SHA-256")
    let dispatch = member(channel, "private func dispatchBlob(")
    check(dispatch.contains("NotificationIds.transientId(of: lxmfData)") && dispatch.contains("messageId: messageId"),
          "a channel post is named by SHA-256 of channel hash and post")
    check(member(channel, "private func dispatchVerifiedLxmf(").contains("messageId: messageId\n"),
          "and is notified under it")
}

func testPost() {
    guard let manager = sourceFile(["Retichat", "Services", "NotificationManager.swift"]) else { return }
    let post = member(manager, "private func postLocalNotification(")
    check(post.contains("NotificationIds.requestIdentifier(messageId: messageId)"),
          "the request is posted under the message's id")
    check(post.contains("deliveredNotifications()") && post.contains("$0.request.identifier == identifier"),
          "and not at all when a notification with the id is shown already")
    check(member(manager, "private func addLocalNotification(").contains("identifier: identifier"),
          "the shown check and the post use one identifier")
}

@main
enum NotificationIdsTests {
    static func main() {
        testIds()
        testFFI()
        testDeliveryChain()
        testPost()

        if failures.isEmpty {
            print("all notification id tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
