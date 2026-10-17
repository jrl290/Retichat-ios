// ReactionsFFITests.swift
//
// Message reactions (REACTIONS-DESIGN.md, approved by James 2026-10-17) against the REAL library:
// the xcframework's static library through RetichatBridge, LxmfClient and the C header, called as
// the app calls them. What tests/ReactionsTests.swift cannot reach:
//  - lxmf_message_set_reaction (LXMF-rust 600ed00) writes {0x40: {0x00: bin, 0x01: bin}}, which
//    the app's decoder reads back as the same reaction, for a direct message (a 32-byte LXMF hash)
//    and a Group envelope (a 16-byte post id beside GROUP_POST_ID, key 11); a reaction over 64
//    bytes is refused and leaves the message as it was;
//  - the Distro Sync of a send (RFed SPEC §17.11) as DistroOutboxRuntime.oweSentCopy builds it,
//    with M's hash (key 12) and M's 0x40, sealed for D and unwrapped on a sibling: still a sent
//    copy, and its fields give the app M's hash and the reaction;
//  - the `react` Distro Sync of Group actions and a `post` with its post id, from the app's writer
//    JSON through the writer, sealed and unwrapped on a sibling: read with the reaction, the post
//    id, a removal's empty text, and passing the app's rules; one without a post id is refused.
//
// Built for Mac Catalyst against the xcframework's Catalyst slice, as
// tests/DistroGroupsFFITests.swift: no simulator, no app, no network. Needs ./build_rust.sh first.
//
// Run from the workspace root with:
//
//   { echo 'import Foundation'; \
//     sed -n '/^\/\/ BEGIN DistroInbound/,/^\/\/ END DistroInbound/p' \
//     Retichat-ios/Retichat/Services/RfedDistroClient.swift; } \
//     > /private/tmp/claude-501/DistroInbound.swift && \
//   swiftc -parse-as-library -target arm64-apple-ios17.6-macabi \
//     -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
//     -import-objc-header Retichat-ios/Retichat/Bridge/CRetichatFFI.h \
//     -o /private/tmp/claude-501/reactions-ffi \
//     /private/tmp/claude-501/DistroInbound.swift \
//     Retichat-ios/Retichat/Bridge/RetichatBridge.swift \
//     Retichat-ios/Retichat/Bridge/LxmfFields.swift \
//     Retichat-ios/Retichat/Services/DistroGroupSync.swift \
//     Retichat-ios/Retichat/Services/LxmfClient.swift \
//     Retichat-ios/Retichat/Services/PendingNotification.swift \
//     Retichat-ios/Retichat/Services/PropagationNodeManager.swift \
//     Retichat-ios/Retichat/Services/DistroOutbox.swift \
//     Retichat-ios/Retichat/Services/DistroChannelSync.swift \
//     Retichat-ios/Retichat/Services/DeliveryPolicy.swift \
//     Retichat-ios/Retichat/Services/GroupStatuses.swift \
//     Retichat-ios/Retichat/Services/GroupEnvelopes.swift \
//     Retichat-ios/Retichat/Services/Reactions.swift \
//     Retichat-ios/tests/ReactionsFFITests.swift \
//     Retichat-ios/Frameworks/RetichatFFI.xcframework/ios-arm64_x86_64-maccatalyst/libretichat_ffi.a \
//     -Xlinker -framework -Xlinker CoreBluetooth -Xlinker -framework -Xlinker IOKit \
//     -Xlinker -framework -Xlinker Security -Xlinker -framework -Xlinker SystemConfiguration \
//     -Xlinker -framework -Xlinker CoreFoundation -lc++ -lresolv -lz -lbz2 && \
//   /private/tmp/claude-501/reactions-ffi

import Foundation

nonisolated(unsafe) var failures: [String] = []
nonisolated(unsafe) var checks = 0
nonisolated(unsafe) var currentTest = ""

func check(_ ok: Bool, _ what: String, line: UInt = #line) {
    checks += 1
    if !ok {
        failures.append("\(currentTest): \(what)")
        print("FAIL: \(currentTest): \(what) (line \(line))")
    }
}

func checkEqual<T: Equatable>(_ a: T, _ b: T, _ what: String, line: UInt = #line) {
    check(a == b, "\(what): got \(a), want \(b)", line: line)
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func unhexData(_ s: String) -> Data {
    Data((0..<s.count / 2).map { i in
        let at = s.index(s.startIndex, offsetBy: 2 * i)
        return UInt8(s[at..<s.index(at, offsetBy: 2)], radix: 16)!
    })
}

func hexOf(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

/// The identities of the shared group sync vectors (made by the Python reference).
let GV: [String: Any] = {
    let url = root.appendingPathComponent("rust/retichat-ffi/tests/data/distro_group_sync_vectors.json")
    guard let raw = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
        fatalError("the group sync vectors are not readable at \(url.path)")
    }
    return json
}()

func gv(_ key: String) -> [String: Any] { GV[key] as! [String: Any] }

func identity(_ key: String) -> UInt64 {
    let bytes = unhexData(gv(key)["private_key_hex"] as! String)
    return bytes.withUnsafeBytes { retichat_identity_from_bytes($0.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(bytes.count)) }
}

let D = gv("distro")["lxmf_delivery_hash_hex"] as! String
let M = gv("member")["lxmf_delivery_hash_hex"] as! String
let SIB = GV["device_hex"] as! String
let THIS = String(repeating: "11", count: 16)
let GID = gv("group")["group_id"] as! String
let bridge = RetichatBridge.shared
let target = Data((0..<32).map { UInt8($0 * 3) })
let POST = String(repeating: "9c", count: 16)

func unwrap(_ handle: UInt64, _ blob: Data) -> DistroUnwrapped? {
    var outLen: UInt32 = 0
    let ptr = blob.withUnsafeBytes { raw -> UnsafeMutablePointer<UInt8>? in
        retichat_distro_unwrap(handle, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(blob.count), &outLen)
    }
    guard let ptr else { return nil }
    let data = Data(bytes: ptr, count: Int(outLen))
    rns_free_bytes(ptr, outLen)
    return try? JSONDecoder().decode(DistroUnwrapped.self, from: data)
}

/// The fields map of a packed message: dest | src | signature | [f64, bin, bin, fields].
func fieldsOf(_ packed: Data) -> Data? {
    let bytes = [UInt8](packed.dropFirst(96))
    guard bytes.count > 14, bytes[0] == 0x94, bytes[1] == 0xcb, bytes[10] == 0xc4 else { return nil }
    var at = 10 + 2 + Int(bytes[11])
    guard at + 1 < bytes.count, bytes[at] == 0xc4 else { return nil }
    at += 2 + Int(bytes[at + 1])
    return Data(bytes[at...])
}

/// A message from D to `dest`, as the app creates one.
func message(to dest: String, _ d: UInt64) -> UInt64 {
    bridge.messageCreate(destHash: unhexData(dest), sourceHash: unhexData(D), content: "", title: "",
                         method: LxmfMethod.direct, identityHandle: d)
}

// MARK: - The reaction field

func theLibraryWritesAReactionTheAppReadsBack() {
    let d = identity("distro")
    check(d != 0, "D's identity loads")
    // A direct reaction: REACTION_TO the target's 32-byte hash.
    let direct = message(to: M, d)
    check(LxmfClient.messageSetReaction(direct, to: target, content: "👍"), "the setter takes a 32-byte target")
    guard let packed = bridge.messagePack(handle: direct), let raw = fieldsOf(packed) else {
        check(false, "packed"); return
    }
    checkEqual(LxmfFieldsDecoder.decode(raw).reaction, .react(to: target, content: "👍"), "read back as the same reaction")
    let content = Data("👍".utf8)
    checkEqual(hexOf(raw), "81" + "40" + "82" + "00" + "c420" + hexOf(target) + "01" + "c4" + String(format: "%02x", content.count) + hexOf(content),
               "the bytes are {0x40: {0x00: bin, 0x01: bin}}, Columba's form")

    // A removal.
    let removal = message(to: M, d)
    check(LxmfClient.messageSetReaction(removal, to: target, content: ""), "an empty reaction is taken")
    checkEqual(bridge.messagePack(handle: removal).flatMap(fieldsOf).map { LxmfFieldsDecoder.decode($0).reaction },
               .react(to: target, content: ""), "and read back as a removal")

    // Over 64 bytes: refused, the message unchanged.
    let long = message(to: M, d)
    check(!LxmfClient.messageSetReaction(long, to: target, content: String(repeating: "a", count: 65)), "65 bytes are refused")
    check(LxmfClient.messageSetReaction(long, to: target, content: String(repeating: "a", count: 64)), "64 bytes are taken")

    // A Group envelope: GROUP_POST_ID (key 11) and a reaction to a post id (16 bytes).
    let envelope = message(to: M, d)
    let post = unhexData(POST)
    check(LxmfClient.messageSetGroupPostId(envelope, POST), "key 11 is written")
    check(LxmfClient.messageSetReaction(envelope, to: post, content: "❤️"), "the setter takes a 16-byte post id")
    let fields = bridge.messagePack(handle: envelope).flatMap(fieldsOf).map(LxmfFieldsDecoder.decode)
    checkEqual(fields?.groupPostId, POST, "the post id read back")
    checkEqual(fields?.reaction, .react(to: post, content: "❤️"), "the reaction read back")
}

// MARK: - The Distro Sync of a send (§5.2)

func theDistroSyncOfASendCarriesTheHashAndTheReactionToASibling() {
    let d = identity("distro")
    let sentHash = String(repeating: "4e", count: 32)
    // As DistroOutboxRuntime.oweSentCopy's fields closure builds it.
    let copy = message(to: D, d)
    check(LxmfClient.messageAddField(copy, key: LxmfFieldKey.customType, value: DistroSent.customType)
            && LxmfClient.messageAddField(copy, key: LxmfFieldKey.customData, value: M)
            && LxmfClient.messageAddField(copy, key: LxmfFieldKey.customMeta, value: SIB)
            && LxmfClient.messageSetSentHash(copy, sentHash)
            && LxmfClient.messageSetReaction(copy, to: target, content: "😂"),
          "the copy's fields are set")
    guard let packed = bridge.messagePack(handle: copy),
          let sealed = bridge.distroSeal(distroHandle: d, packed: packed),
          let u = unwrap(d, sealed.sealed) else {
        check(false, "packed, sealed and unwrapped"); return
    }
    checkEqual(u.sent_to, M, "still a sent copy, to M")
    checkEqual(u.sent_by, SIB, "from the sibling that sent it")
    let fields = u.fieldsRaw.map(LxmfFieldsDecoder.decode)
    checkEqual(fields?.sentHash, sentHash, "M's hash, key 12")
    checkEqual(fields?.reaction, .react(to: target, content: "😂"), "M's 0x40")
    checkEqual(fields?.isDistroSentCopy, true, "the decoder knows it as a sent copy")

    // A plain send's copy: key 12, no reaction.
    let plain = message(to: D, d)
    check(LxmfClient.messageAddField(plain, key: LxmfFieldKey.customType, value: DistroSent.customType)
            && LxmfClient.messageAddField(plain, key: LxmfFieldKey.customData, value: M)
            && LxmfClient.messageSetSentHash(plain, sentHash), "a plain copy's fields are set")
    let plainFields = bridge.messagePack(handle: plain)
        .flatMap { bridge.distroSeal(distroHandle: d, packed: $0) }
        .flatMap { unwrap(d, $0.sealed) }?.fieldsRaw.map(LxmfFieldsDecoder.decode)
    checkEqual(plainFields?.sentHash, sentHash, "a plain copy carries M's hash")
    checkEqual(plainFields?.reaction, nil, "and no reaction")
}

// MARK: - The react group sync (§5.3)

func theReactAndPostGroupSyncsReachASiblingWithThePostId() {
    let d = identity("distro")
    func throughTheWriter(_ json: String) -> DistroUnwrapped? {
        let msg = message(to: D, d)
        guard msg != 0, bridge.messageSetDistroGroupSync(handle: msg, syncJson: json, dHex: D, deviceHex: SIB),
              let packed = bridge.messagePack(handle: msg),
              let sealed = bridge.distroSeal(distroHandle: d, packed: packed) else { return nil }
        return unwrap(d, sealed.sealed)
    }
    func applied(_ u: DistroUnwrapped?) -> DistroGroupSync.Form? {
        guard let u, let reading = u.group_sync,
              case .apply(let form, let sibling) = DistroGroupSync.disposition(
                sourceHex: u.source_hash, distroHex: D, signatureValidated: u.signature_validated ?? false,
                reading: reading, deviceHex: THIS) else { return nil }
        checkEqual(sibling, SIB, "its 0xFD is the sibling")
        return form
    }
    let react = applied(throughTheWriter(DistroGroupSync.writerJSON(op: .react, groupId: GID, atMs: 1_790_000_000_123,
                                                                    text: "👍", left: [], postId: POST)))
    checkEqual(react?.op, .react, "a react G reaches a sibling and passes the app's rules")
    checkEqual(react?.text, "👍", "with the reaction")
    checkEqual(react?.postId, POST, "and the post it reacts to")
    checkEqual(react.map { DistroGroupSync.step($0.op, standing: .joined, ownMemberIsD: true, pendingMatches: false) },
               .applyOwnReaction, "applied in a joined group")
    let removal = applied(throughTheWriter(DistroGroupSync.writerJSON(op: .react, groupId: GID, atMs: 1_790_000_000_124,
                                                                      text: "", left: [], postId: POST)))
    checkEqual(removal?.text, "", "a removal reaches a sibling as an empty text")
    let post = applied(throughTheWriter(DistroGroupSync.writerJSON(op: .post, groupId: GID, atMs: 1_790_000_000_125,
                                                                   text: "hi", left: [], postId: POST)))
    checkEqual(post?.postId, POST, "a post G carries its post id")
    let older = applied(throughTheWriter(DistroGroupSync.writerJSON(op: .post, groupId: GID, atMs: 1_790_000_000_126,
                                                                    text: "hi", left: [])))
    check(older != nil && older?.postId == nil, "a post G without one is read as before")
    check(throughTheWriter(DistroGroupSync.writerJSON(op: .react, groupId: GID, atMs: 1, text: "👍", left: [])) == nil,
          "a react G without a post id is refused by the writer")
    check(throughTheWriter(DistroGroupSync.writerJSON(op: .react, groupId: GID, atMs: 1, text: "👍", left: [],
                                                      postId: String(POST.dropLast()))) == nil,
          "and one whose post id is not 32 hex")
}

let allTests: [(String, () -> Void)] = [
    ("the library writes a reaction the app reads back", theLibraryWritesAReactionTheAppReadsBack),
    ("the Distro Sync of a send carries the hash and the reaction to a sibling", theDistroSyncOfASendCarriesTheHashAndTheReactionToASibling),
    ("the react and post group syncs reach a sibling with the post id", theReactAndPostGroupSyncsReachASiblingWithThePostId),
]

@main
enum ReactionsFFITests {
    static func main() {
        for (name, run) in allTests {
            currentTest = name
            let before = failures.count
            run()
            print(failures.count == before ? "ok    - \(name)" : "FAIL  - \(name)")
        }
        print("\n\(allTests.count) tests, \(checks) checks, \(failures.count) failure(s)")
        exit(failures.isEmpty ? 0 : 1)
    }
}
