// DistroControlNoChatTests.swift
//
// A Distro control message (0xFB "rfed.distro.*": a sent copy, a transfer, a channel join or
// leave, a group sync, or a kind a later build adds) is never a message to show, as the web
// (Retichat-js 1ac43ff) and Android treat it:
//
// - On the device's own address, one that is not a transfer and has no group id is dropped with a
//   log line by every direct reader (handleIncomingMessage, importNSEMessages, nseHandOffForm).
//   A group id still makes it the group's, and a transfer is still offered.
// - On the distro unwrap (RfedDistroClient, NSEDistroPull), one no branch acts on is dropped.
//
// Until 2026-10-24 both were filed as a DM or a placeholder bubble. Field maps are hand-encoded
// with uint8 keys (0xCC 0xFB), as lxmf_message_add_field writes them.
//
// Run with (from the workspace root):
//
//   swiftc -parse-as-library -o /private/tmp/claude-501/distro-control-no-chat \
//     Retichat-ios/Retichat/Bridge/LxmfFields.swift \
//     Retichat-ios/tests/DistroControlNoChatTests.swift && \
//     /private/tmp/claude-501/distro-control-no-chat

import Foundation

var failures: [String] = []

func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() {
        print("ok    - \(name)")
    } else {
        print("FAIL  - \(name)")
        failures.append(name)
    }
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func source(_ path: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

/// The text from `start` up to the first `end` after it, or "" when either is missing.
func span(_ text: String, from start: String, to end: String) -> String {
    guard let a = text.range(of: start), let b = text.range(of: end, range: a.upperBound..<text.endIndex) else { return "" }
    return String(text[a.lowerBound..<b.upperBound])
}

/// Both appear in `text`, `a` first.
func before(_ text: String, _ a: String, _ b: String) -> Bool {
    guard let ra = text.range(of: a), let rb = text.range(of: b) else { return false }
    return ra.lowerBound < rb.lowerBound
}

// MARK: - Hand encoders (msgpack)

func str(_ s: String) -> [UInt8] {
    let b = Array(s.utf8)
    if b.count < 32 { return [0xA0 | UInt8(b.count)] + b }
    return [0xD9, UInt8(b.count)] + b
}

func bin8(_ s: String) -> [UInt8] { let b = Array(s.utf8); return [0xC4, UInt8(b.count)] + b }
func key(_ k: UInt8) -> [UInt8] { [0xCC, k] }
func arr(_ items: [[UInt8]]) -> [UInt8] { [0x90 | UInt8(items.count)] + items.flatMap { $0 } }

func fields(_ entries: [[UInt8]]) -> LxmfFields {
    LxmfFieldsDecoder.decode(Data([0x80 | UInt8(entries.count)] + entries.flatMap { $0 }))
}

let groupId = "9f8e7d6c5b4a39281706f5e4d3c2b1a0"
let transferKey = String(repeating: "0123456789abcdef", count: 8)
let join = arr([str("join"), str("news"), [0x00]])

@main
enum DistroControlNoChatTests {
    static func main() {
        // MARK: The rule

        let channel = fields([key(0xFB) + str("rfed.distro.channel"), key(0xFC) + join])
        check(channel.distroControlType == "rfed.distro.channel" && channel.isMisroutedDistroControl,
              "a channel sync on the device address is dropped")
        check(fields([key(0xFB) + str("rfed.distro.channel")]).isMisroutedDistroControl,
              "a channel sync without its 0xFC is dropped")
        check(fields([key(0xFB) + str("rfed.distro.group")]).isMisroutedDistroControl,
              "a group sync on the device address is dropped")
        let newer = fields([key(0xFB) + str("rfed.distro.newer"), key(0xFC) + str("x")])
        check(newer.distroControlType == "rfed.distro.newer" && newer.isMisroutedDistroControl,
              "a kind a later build adds is dropped")
        check(fields([key(0xFB) + bin8("rfed.distro.newer")]).isMisroutedDistroControl,
              "the type as bin is read the same")

        for type in ["rfed.distro.channel", "rfed.distro.group", "rfed.distro.newer"] {
            let grouped = fields([key(0xFB) + str(type), key(0xA0) + str(groupId)])
            check(grouped.groupId == groupId && !grouped.isMisroutedDistroControl,
                  "\(type) beside a group id is still the group's")
        }
        let transfer = fields([key(0xFB) + str("rfed.distro.transfer"), key(0xFC) + str(transferKey)])
        check(transfer.distroTransferKey == transferKey && !transfer.isMisroutedDistroControl,
              "a transfer is still offered")
        check(!fields([key(0xFB) + str("rfed.distro.transfer")]).isMisroutedDistroControl,
              "a transfer marker without a usable key stays a DM, as on Android and the web")
        let sent = fields([key(0xFB) + str(DistroSent.customType)])
        check(sent.isDistroSentCopy && sent.distroControlType == DistroSent.customType,
              "a sent copy is a Distro control message (dropped earlier, by its own rule)")
        for type in ["rfed.distro", "rfed.distrox", "Rfed.distro.newer", "x.rfed.distro.newer", ""] {
            let other = fields([key(0xFB) + str(type)])
            check(other.distroControlType == nil && !other.isMisroutedDistroControl, "\"\(type)\" is no Distro control message")
        }
        check(LxmfFieldsDecoder.decode(Data([0x80])).distroControlType == nil, "no fields, no type")

        // MARK: Where each reader drops it

        let repo = source("Retichat/Services/ChatRepository.swift")
        let incoming = span(repo, from: "private func handleIncomingMessage(", to: "if let groupId = fields.groupId {")
        check(before(incoming, "if fields.isDistroSentCopy {", "if fields.isMisroutedDistroControl {"),
              "handleIncomingMessage: after the sent-copy drop")
        check(before(incoming, "if fields.isMisroutedDistroControl {", "LxmfClient.decodeDisplayName"),
              "handleIncomingMessage: before the name is read and the group branch")
        check(span(incoming, from: "if fields.isMisroutedDistroControl {", to: "}").contains("return"),
              "handleIncomingMessage: it returns")

        let imported = span(repo, from: "func importNSEMessages()", to: "let reason = msg.unverifiedReason")
        check(before(imported, "if fields.isDistroSentCopy {", "if fields.isMisroutedDistroControl {"),
              "importNSEMessages: after the sent-copy drop, before the name and the store")
        check(span(imported, from: "if fields.isMisroutedDistroControl {", to: "}").contains("continue"),
              "importNSEMessages: it skips the message")

        let nse = span(source("NotificationService/NotificationService.swift"),
                       from: "private func nseHandOffForm(", to: "\n}\n")
        check(before(nse, "if fields.isDistroSentCopy {", "if fields.isMisroutedDistroControl {"),
              "nseHandOffForm: after the sent-copy drop")
        check(before(nse, "if fields.isMisroutedDistroControl {", "distroTransferKey"),
              "nseHandOffForm: before the transfer is stashed and the message stored")
        check(span(nse, from: "if fields.isMisroutedDistroControl {", to: "}").contains("return nil"),
              "nseHandOffForm: neither stored nor shown")

        let unwrap = span(source("Retichat/Services/RfedDistroClient.swift"),
                          from: "nonisolated private static func unwrapAndDeliver(", to: "private func deliver(")
        let drop = "} else if let type = LxmfFieldsDecoder.decode(parsed.fieldsRaw ?? Data()).distroControlType {"
        for earlier in ["DistroChannelSync.read(", "inbound = .transfer(", "inbound = .sentCopy(", "inbound = .notification"] {
            check(before(unwrap, earlier, drop), "the distro unwrap: after \(earlier)")
        }
        check(before(unwrap, drop, "var message = DistroMessage(unwrapped:"), "the distro unwrap: before it is filed as a message")
        check(span(unwrap, from: drop, to: "} else {").contains("return false"), "the distro unwrap: it is dropped")

        let pulled = span(source("NotificationService/NSEDistroPull.swift"),
                          from: "if m.sent_by != nil || !(m.distro_transfer_key", to: "var content = m.content ?? \"\"")
        check(span(pulled, from: "if let type = fields.distroControlType {", to: "}").contains("return nil"),
              "the NSE's distro pull: never shown as a message")

        if failures.isEmpty {
            print("all tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
