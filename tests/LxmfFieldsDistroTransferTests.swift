// LxmfFieldsDistroTransferTests.swift
//
// Regression tests for decoding the distro identity transfer (RFed SPEC §17.9):
// FIELD_CUSTOM_TYPE (0xFB) = "rfed.distro.transfer", FIELD_CUSTOM_DATA (0xFC)
// = the 128-hex private key, as str (Android) or bin (web). Field maps are
// hand-encoded with uint8 keys (0xCC 0xFB), exactly as lxmf_message_add_field
// writes them, so these bytes are what the decoder meets on the wire.
//
// Run with (from the workspace root):
//
//   swiftc -o /private/tmp/claude-501/lxmf-fields-distro \
//     Retichat-ios/Retichat/Bridge/LxmfFields.swift \
//     Retichat-ios/tests/LxmfFieldsDistroTransferTests.swift && \
//     /private/tmp/claude-501/lxmf-fields-distro

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

// MARK: - Hand encoders (msgpack)

func str(_ s: String) -> [UInt8] {
    let b = Array(s.utf8)
    if b.count < 32 { return [0xA0 | UInt8(b.count)] + b }
    precondition(b.count < 256)
    return [0xD9, UInt8(b.count)] + b          // str8 — a 128-hex key needs it
}

func bin8(_ s: String) -> [UInt8] {
    let b = Array(s.utf8)
    precondition(b.count < 256)
    return [0xC4, UInt8(b.count)] + b
}

func key(_ k: UInt8) -> [UInt8] { [0xCC, k] }  // uint8, as lxmf_message_add_field writes keys

func map(_ entries: [[UInt8]]) -> Data {
    precondition(entries.count < 16)
    return Data([0x80 | UInt8(entries.count)] + entries.flatMap { $0 })
}

let keyHex = String(repeating: "0123456789abcdef", count: 8)   // 128 hex

@main
enum LxmfFieldsDistroTransferTests {
    static func main() {
        check(keyHex.count == 128, "fixture key is 128 hex")
        check(key(LxmfFieldKey.customType) == [0xCC, 0xFB], "customType key encodes as 0xCC 0xFB")
        check(key(LxmfFieldKey.customData) == [0xCC, 0xFC], "customData key encodes as 0xCC 0xFC")

        // 1. str / str
        let asStr = LxmfFieldsDecoder.decode(map([
            key(0xFB) + str("rfed.distro.transfer"),
            key(0xFC) + str(keyHex),
        ]))
        check(asStr.customType == "rfed.distro.transfer", "str 0xFB decodes customType")
        check(asStr.distroTransferKey == keyHex, "str 0xFC gives distroTransferKey")

        // 2. 0xFC as bin8 (web client)
        let asBin = LxmfFieldsDecoder.decode(map([
            key(0xFB) + str("rfed.distro.transfer"),
            key(0xFC) + bin8(keyHex),
        ]))
        check(asBin.distroTransferKey == keyHex, "bin8 0xFC gives the same distroTransferKey")

        // 3. a different custom type is not a transfer
        let otherType = LxmfFieldsDecoder.decode(map([
            key(0xFB) + str("something.else"),
            key(0xFC) + str(keyHex),
        ]))
        check(otherType.customData == keyHex, "other type still decodes customData")
        check(otherType.distroTransferKey == nil, "other custom type gives no distroTransferKey")

        // 4. wrong-typed 0xFC is skipped and the parse stays in step
        let wrongType = LxmfFieldsDecoder.decode(map([
            key(0xFC) + [0x05],                       // positive fixint 5
            key(LxmfFieldKey.groupId) + str("g"),
        ]))
        check(wrongType.customData == nil, "int 0xFC leaves customData nil")
        check(wrongType.groupId == "g", "field after int 0xFC still decodes (parse in sync)")

        // Order reversed: a transfer after an unrelated known field.
        let afterGroup = LxmfFieldsDecoder.decode(map([
            key(LxmfFieldKey.groupId) + str("g"),
            key(0xFC) + bin8(keyHex),
            key(0xFB) + str("rfed.distro.transfer"),
        ]))
        check(afterGroup.groupId == "g" && afterGroup.distroTransferKey == keyHex,
              "transfer fields decode in any order alongside other fields")

        // Truncated 0xFC must not read past the buffer or invent a value.
        var truncated = [UInt8](map([key(0xFB) + str("rfed.distro.transfer")]))
        truncated[0] = 0x82
        truncated += key(0xFC) + [0xD9, 0x80] + Array("abc".utf8)
        let cut = LxmfFieldsDecoder.decode(Data(truncated))
        check(cut.customType == "rfed.distro.transfer" && cut.customData == nil,
              "truncated 0xFC yields nil without crashing")

        // A field key above 0xFF (LXMF's experimental range) must be skipped,
        // not crash the decoder: UInt8(key) trapped on it until 2026-09-24.
        let wideKey = LxmfFieldsDecoder.decode(map([
            [0xCD, 0x01, 0x00] + str("experimental"),      // key 0x100 as uint16
            key(0xFB) + str("rfed.distro.transfer"),
            key(0xFC) + str(keyHex),
        ]))
        check(wideKey.distroTransferKey == keyHex, "a key above 0xFF is skipped and later fields still decode")

        if failures.isEmpty {
            print("all tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
