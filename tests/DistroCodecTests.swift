// DistroCodecTests.swift
//
// Regression tests for the pure distro codec (RFed SPEC §17), mirroring
// Retichat-android app/src/test/.../DistroCodecTest.kt.
// Run with:
//
//   swiftc -o /private/tmp/claude-501/distro-codec \
//     Retichat-ios/Retichat/Services/DistroCodec.swift \
//     Retichat-ios/tests/DistroCodecTests.swift && \
//     /private/tmp/claude-501/distro-codec
//
// Not covered here: the "record the seen key only after the hand-off"
// ordering in RfedDistroClient.ingestBlob. It needs the FFI unwrap, so it is
// exercised by test-plan step 3 (staging run), not by this standalone binary.

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

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

let keyBytes = Data((0..<64).map { UInt8($0) })
let keyHex = hex(keyBytes)

@main
enum DistroCodecTests {
    static func main() {
        // parsePrivateKey — accepted forms
        check(DistroCodec.parsePrivateKey(keyHex) == keyBytes, "parse bare lowercase hex")
        check(DistroCodec.parsePrivateKey("RFED-DISTRO-PRIVATE-KEY://\(keyHex.uppercased())/") == keyBytes,
              "parse upper-case scheme + upper hex + trailing slash")
        check(DistroCodec.parsePrivateKey("rfed-distro-id://\(keyHex)") == keyBytes, "parse legacy scheme")
        check(DistroCodec.parsePrivateKey("  \n\(DistroCodec.privateKeyScheme)\(keyHex)\t ") == keyBytes,
              "parse with surrounding whitespace")

        // parsePrivateKey — rejected forms
        check(DistroCodec.parsePrivateKey(String(keyHex.dropLast())) == nil, "reject 127 chars")
        check(DistroCodec.parsePrivateKey(keyHex + "0") == nil, "reject 129 chars")
        check(DistroCodec.parsePrivateKey(String(keyHex.dropLast(2)) + "zz") == nil, "reject non-hex")
        check(DistroCodec.parsePrivateKey("lxma://\(String(keyHex.prefix(32))):\(keyHex)") == nil,
              "reject lxma:// contact link")
        check(DistroCodec.parsePrivateKey("") == nil, "reject empty")

        // isAffirmative
        check(DistroCodec.isAffirmative(Data([0xC3])), "affirmative: true")
        check(DistroCodec.isAffirmative(Data([0x91, 0xC3])), "affirmative: [true]")
        check(DistroCodec.isAffirmative(Data([0x92, 0xC3, 0xC0])), "affirmative: [true, nil]")
        check(!DistroCodec.isAffirmative(Data([0xC2])), "not affirmative: false")
        check(!DistroCodec.isAffirmative(Data([0x91, 0xC2])), "not affirmative: [false]")
        check(!DistroCodec.isAffirmative(Data([0x90])), "not affirmative: []")
        check(!DistroCodec.isAffirmative(Data()), "not affirmative: empty")
        check(!DistroCodec.isAffirmative(nil), "not affirmative: nil")
        // A slice whose startIndex is not 0 must still read its own bytes.
        let sliced = Data([0x00, 0x91, 0xC3]).dropFirst()
        check(DistroCodec.isAffirmative(sliced), "affirmative: non-zero-based slice")

        // msgpackNil
        check(DistroCodec.msgpackNil == Data([0xC0]), "msgpackNil is 0xC0")

        // pullErrorCode
        check(DistroCodec.pullErrorCode(Data([0xF1])) == 0xF1, "pull error: raw byte")
        check(DistroCodec.pullErrorCode(Data([0xCC, 0xF4])) == 0xF4, "pull error: msgpack uint8")
        // [[], false] — an empty pull envelope
        check(DistroCodec.pullErrorCode(Data([0x92, 0x90, 0xC2])) == nil, "pull envelope is not an error")

        // seenKey / appendSeen
        check(DistroCodec.seenKey(sourceHex: "ab", timestamp: 1.5) == "ab:1.5", "seenKey format")
        let seen1 = DistroCodec.appendSeen(["a", "b"], key: "c")
        check(seen1 == ["a", "b", "c"], "appendSeen appends in order")
        check(DistroCodec.appendSeen(seen1, key: "b") == seen1, "appendSeen ignores a duplicate")
        let full = (0..<500).map { "k\($0)" }
        let capped = DistroCodec.appendSeen(full, key: "new")
        check(capped.count == 500, "appendSeen caps at 500")
        check(capped.first == "k1" && capped.last == "new", "appendSeen drops the oldest")

        // messageId
        let id1 = DistroCodec.messageId(sourceHex: "aa", timestamp: 1.5, content: "hi")
        check(id1 == DistroCodec.messageId(sourceHex: "aa", timestamp: 1.5, content: "hi"), "messageId is stable")
        check(id1.count == 32 && id1.allSatisfy { $0.isHexDigit }, "messageId is 32 hex")
        check(id1 == "a587d96954d31863b885ab3aef12535b", "messageId matches SHA256 prefix")
        check(id1 != DistroCodec.messageId(sourceHex: "aa", timestamp: 1.5, content: "hi!"),
              "messageId changes with content")

        // identityHashHex — SHA256(bytes 0..63)[0..<16], precomputed with Python hashlib
        check(DistroCodec.identityHashHex(publicKey: keyBytes) == "fdeab9acf3710362bd2658cdc9a29e8f",
              "identityHashHex of a known key")
        check(DistroCodec.identityHashHex(publicKey: Data(count: 32)) == nil, "identityHashHex rejects 32 bytes")

        if failures.isEmpty {
            print("all tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
