// RfedLinkPublishTests.swift
//
// Self-contained Swift test script — no XCTest target required.
// Run with:
//
//     swift Retichat-ios/tests/RfedLinkPublishTests.swift
//
// Exits with status 0 on success, 1 on any failure.
//
// What it covers
// ──────────────
// The `/channel/publish` request on rfed.link carries the post as a msgpack
// bin (RFed-spec/Link.md: the payload is the legacy SEND packet's bytes). A
// request's data is a msgpack value: Reticulum-rust hands a bin's bytes to
// the handler and re-encodes anything else (link.rs, "if outer[2] is
// Binary"). Until 2026-10-18 iOS sent the bare bytes, so they were read as
// msgpack and rewritten: a channel hash starting 0x9a is a 10-element array,
// its 0xd2 (int32) came back as 0xce (uint32), and rfed fanned the post out
// to a channel nobody holds (staging, 2026-10-18 16:11).
//
//   1. `msgpackBin` encodes every length: bin8, bin16 and bin32 (a post is
//      often over 255 bytes; the bin8-only helper trapped on UInt8(count)).
//      A copy of the production helper in RfedChannelClient.swift: change
//      them together.
//   2. The publish request sends `Self.msgpackBin(payload)`.

import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print("\(ok ? "PASS" : "FAIL"): \(what)")
    if !ok { failures += 1 }
}

// ── copy of RfedChannelClient.msgpackBin ──
func msgpackBin(_ data: Data) -> Data {
    let n = data.count
    var out: Data
    if n <= 0xff {
        out = Data([0xc4, UInt8(n)])
    } else if n <= 0xffff {
        out = Data([0xc5, UInt8(n >> 8), UInt8(n & 0xff)])
    } else {
        out = Data([0xc6, UInt8((n >> 24) & 0xff), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)])
    }
    out.append(data)
    return out
}

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let src = try! String(contentsOf: here.appendingPathComponent("../Retichat/Services/RfedChannelClient.swift"), encoding: .utf8)

// 1. The copy matches production.
let prodHelper = src.components(separatedBy: "nonisolated static func msgpackBin(_ data: Data) -> Data {").dropFirst().first?
    .components(separatedBy: "\n    }\n").first ?? ""
let copySrc = try! String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
let copyHelper = copySrc.components(separatedBy: "func msgpackBin(_ data: Data) -> Data {").dropFirst().first?
    .components(separatedBy: "\n}\n").first ?? ""
func squash(_ s: String) -> String { s.filter { !$0.isWhitespace } }
check(!prodHelper.isEmpty && squash(prodHelper) == squash(copyHelper), "the copy of msgpackBin matches RfedChannelClient.swift")

check(msgpackBin(Data(repeating: 1, count: 16)).prefix(2) == Data([0xc4, 16]), "16 bytes: bin8")
check(msgpackBin(Data(repeating: 1, count: 255)).prefix(2) == Data([0xc4, 0xff]), "255 bytes: bin8")
let b300 = msgpackBin(Data(repeating: 1, count: 300))
check(b300.prefix(3) == Data([0xc5, 0x01, 0x2c]) && b300.count == 303, "300 bytes: bin16")
let b70k = msgpackBin(Data(repeating: 1, count: 70_000))
check(b70k.prefix(5) == Data([0xc6, 0x00, 0x01, 0x11, 0x70]) && b70k.count == 70_005, "70000 bytes: bin32")

// The staging post's channel hash: bare, it is msgpack (0x9a = a 10-array),
// so only the bin keeps its bytes.
let hash = Data([0x9a, 0x5e, 0x1b, 0xed, 0x3d, 0x16, 0x82, 0xf2, 0x55, 0xf4, 0x11, 0xd2, 0x15, 0xc2, 0x23, 0x62])
check(msgpackBin(hash).dropFirst(2) == hash, "the bin carries the channel hash unchanged")

// 2. The publish request wraps its payload.
let send = src.components(separatedBy: "path: \"/channel/publish\"").dropFirst().first?.prefix(120) ?? ""
check(send.contains("payload: Self.msgpackBin(payload)"), "the /channel/publish request sends its payload as a msgpack bin")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
