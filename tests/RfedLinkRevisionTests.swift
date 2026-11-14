// RfedLinkRevisionTests.swift
//
// The 2026-11-13 revision of rfed.link (RFed-spec/Link.md), on iOS. A port of
// Retichat-android's RfedLinkTest (the revision's tests there).
//
// Run with:
//
//     swift Retichat-ios/tests/RfedLinkRevisionTests.swift
//
// Exits with status 0 on success, 1 on any failure.
//
// What it covers
// ──────────────
//   1. The channel push: both names are set up before the link exists and
//      both reach the channel client; `/channel/stream/open` carries the
//      fourth element 2 only to a node that announces protocol version 2.
//   2. LXMF propagation on rfed.link with such a node: the router's carrier
//      is synced when the link is set up and on every ACTIVE edge, each
//      request is answered once, the sync holds the link for its three
//      requests, and no identity of lxmf.propagation is waited for.
//   3. The distro outbox follows the propagation onto rfed.link: its uploads
//      are requests there, `true` is the proof, a loss keeps the link.
// The wiring needs the FFI and the stack, so it is pinned on the source.

import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print("\(ok ? "PASS" : "FAIL"): \(what)")
    if !ok { failures += 1 }
}

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
func read(_ path: String) -> String {
    (try? String(contentsOf: here.appendingPathComponent("../\(path)"), encoding: .utf8)) ?? ""
}
func squash(_ s: String) -> String { s.filter { !$0.isWhitespace } }

// ── copy of RfedChannelClient.channelStreamBind ──
func channelStreamBind(_ signed: Data, nodeProtocolVersion: UInt32) -> Data {
    guard nodeProtocolVersion >= 2, signed.first == 0x93 else { return signed }
    var out = Data([0x94])   // fixarray of 4
    out.append(signed.dropFirst())
    out.append(0x02)
    return out
}

let channel = read("Retichat/Services/RfedChannelClient.swift")
let link = read("Retichat/Services/RfedLink.swift")
let repository = read("Retichat/Services/ChatRepository.swift")
let outbox = read("Retichat/Services/DistroOutboxRuntime.swift")
let header = read("Retichat/Bridge/CRetichatFFI.h")

// 1. The channel push.
let prodBind = channel.components(separatedBy: "nonisolated static func channelStreamBind(_ signed: Data, nodeProtocolVersion: UInt32) -> Data {").dropFirst().first?
    .components(separatedBy: "\n    }\n").first ?? ""
let copySrc = (try? String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)) ?? ""
let copyBind = copySrc.components(separatedBy: "func channelStreamBind(_ signed: Data, nodeProtocolVersion: UInt32) -> Data {").dropFirst().first?
    .components(separatedBy: "\n}\n").first ?? ""
check(!prodBind.isEmpty && squash(prodBind) == squash(copyBind), "the copy of channelStreamBind matches RfedChannelClient.swift")

let signed = Data([0x93, 0xc4, 1, 0x41, 0xc4, 1, 0x42, 0xc4, 1, 0x43])
check(channelStreamBind(signed, nodeProtocolVersion: 0) == signed, "a node not heard: three elements")
check(channelStreamBind(signed, nodeProtocolVersion: 1) == signed, "a version-1 node: three elements")
let four = Data([0x94]) + signed.dropFirst() + Data([0x02])
check(channelStreamBind(signed, nodeProtocolVersion: 2) == four, "version 2: [value, pubkey, signature, 2], the signature untouched")
check(channelStreamBind(signed, nodeProtocolVersion: 3) == four, "a later version: the same")
check(channel.contains("nodeProtocolVersion: RfedLink.protocolVersion(nodeHex: nodeIdentityHashHex)"),
      "the bind asks the node's announced version")

check(link.contains("nonisolated static let pushChannelDelivery = \"/channel/delivery\""), "the new push name")
check(link.contains("paths: [Self.pushChannelDelivery, Self.pushDelivery, Self.pushLxmf, Self.pushNotify]"),
      "both push names are set up before the link exists")
check(link.contains("let taker = path == pushChannelDelivery ? pushDelivery : path"),
      "the channel push under either name goes to the channel client")

// 2. LXMF propagation on rfed.link.
check(header.contains("int32_t lxmf_client_sync_rfed_carrier(")
          && header.contains("int32_t lxmf_propagation_carrier_complete(")
          && header.contains("uint32_t lxmf_rfed_node_protocol_version("),
      "the C API is declared")
let ensure = link.components(separatedBy: "func ensure(nodeHex: String) -> Data? {").dropFirst().first?
    .components(separatedBy: "\n    }\n").first ?? ""
check(ensure.contains("RfedPropagationCarrier.shared.sync(nodeHex: node)"), "the carrier is synced when the link is set up")
let onStatus = link.components(separatedBy: "private func onStatus(node: String, status: UInt8) {").dropFirst().first?
    .components(separatedBy: "\n    }\n").first ?? ""
let syncAt = onStatus.range(of: "RfedPropagationCarrier.shared.sync(nodeHex: node)")
let bindersAt = onStatus.range(of: "binders[owner]?(node)")
check(syncAt != nil && bindersAt != nil && syncAt!.lowerBound < bindersAt!.lowerBound,
      "each ACTIVE edge syncs the carrier before the binders run")
let callback = link.components(separatedBy: "private let rfedCarrierRequest: lxmf_propagation_carrier_callback_t =").dropFirst().first ?? ""
check(callback.contains("RfedPropagationCarrier.complete(token: token, answer: nil)")
          && callback.contains("let answer = await RfedLink.shared.request(nodeHex: target.node, path: requestPath, payload: payload)")
          && callback.contains("RfedPropagationCarrier.complete(token: token, answer: answer)"),
      "every carrier request is sent on rfed.link and answered once")

check(link.contains("guard node == UserPreferences.shared.effectiveRfedNodeIdentityHash.lowercased() else { return false }"),
      "only the node this device propagates through decides the carrier, never a channel's node")
let polling = repository.components(separatedBy: "private func startPropagationPolling() {").dropFirst().first?
    .components(separatedBy: "\n    }\n").first ?? ""
let carrierAt = polling.range(of: "RfedPropagationCarrier.shared.sync(nodeHex: prefs.effectiveRfedNodeIdentityHash, client: client)")
let nodeAt = polling.range(of: "_ = client.setPropagationNode(nodeHash: nodeHash)")
check(carrierAt != nil && nodeAt != nil && carrierAt!.lowerBound < nodeAt!.lowerBound,
      "at start the carrier is synced before the router is given its node, so no lxmf.propagation link opens")
check(repository.contains("if RfedPropagationCarrier.shared.carries(nodeHash) { return nodeHash }"),
      "on rfed.link no identity of lxmf.propagation is waited for")
let poll = repository.components(separatedBy: "func pollPropagationNode(force: Bool = false) {").dropFirst().first?
    .components(separatedBy: "\n    }\n").first ?? ""
check(poll.contains("if RfedPropagationCarrier.shared.carries(nodeHash) {\n            Task { _ = await self.syncPropagationNode() }"),
      "a casual sync on rfed.link holds the link too")

// 3. The distro outbox.
check(outbox.contains("if let rfed = carrier() { return uploadOnRfedLink(rfed, upload: upload, sink: sink) }"),
      "an owed upload goes on rfed.link while it carries the propagation")
let upload = outbox.components(separatedBy: "private func uploadOnRfedLink(").dropFirst().first?
    .components(separatedBy: "/// RNS's link MDU").first ?? ""
check(upload.contains("guard let link = bridge.propagationLink(node: rfed.dest), link.active else {"), "only on an ACTIVE link")
check(upload.contains("path: \"/propagation/upload\", payload: payload)") && upload.contains("RfedChannelClient.msgpackBin(upload)"),
      "as a /propagation/upload request carrying the upload as a bin")
check(upload.contains("if answer == Data([0xc3]) {") && upload.contains("sink.proved()"), "true is the proof")
check(upload.contains("sink.lost()") && !upload.contains("teardown") && !upload.contains("closeAppLink"),
      "a loss keeps the link")
check(outbox.contains("PropagationLinkTarget.set(node: port.linkDest(), outbox: outbox)"),
      "the link events followed are the uploads' link's")
check(link.contains("DistroOutboxRuntime.linkChanged()"), "when the propagation's link changes, the outbox follows")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
