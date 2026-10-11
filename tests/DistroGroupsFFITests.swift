// DistroGroupsFFITests.swift
//
// Groups for distro holders (GROUPS-DISTRO-DESIGN.md §7, §10, §17.2), against the REAL library:
// the xcframework's static library through RetichatBridge and the C header, called as the app
// calls them, with the shared vectors (rust/retichat-ffi/tests/data/distro_group_sync_vectors.json,
// made by the Python reference). What the other tests cannot reach:
//  - a sealed G and a member's group message to D, unwrapped by retichat_distro_unwrap with D's
//    key, decode into the app's DistroUnwrapped, route as the distro path routes them, and their
//    group sync reading passes the app's own rules (§11.1) as the shared layer read it;
//  - the app's writer JSON (DistroGroupSync.writerJSON), through messageSetDistroGroupSync and the
//    pack, writes the very fields bytes the Python reference packs for each op, signed by D, from
//    D to D; sealed for D, it reads back as the same G on a sibling;
//  - the writer refuses what a receiver's form check would drop, and a message not from D to D;
//  - a message that repeats a key (RFed SPEC §17.14 "Repeated keys") is refused whole by the
//    distro unwrap and by the direct path's unpack, with an error the app knows as the refusal
//    LXMF-rust logged; a G whose source is not D is ignored by rule 1.
//
// It runs as a command-line binary on this Mac, built for Mac Catalyst against the
// xcframework's Catalyst slice (as tests/DistroChannelsFFITests.swift): no simulator, no app, no
// network. Needs ./build_rust.sh first.
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
//     -o /private/tmp/claude-501/distro-groups-ffi \
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
//     Retichat-ios/tests/DistroGroupsFFITests.swift \
//     Retichat-ios/Frameworks/RetichatFFI.xcframework/ios-arm64_x86_64-maccatalyst/libretichat_ffi.a \
//     -Xlinker -framework -Xlinker CoreBluetooth -Xlinker -framework -Xlinker IOKit \
//     -Xlinker -framework -Xlinker Security -Xlinker -framework -Xlinker SystemConfiguration \
//     -Xlinker -framework -Xlinker CoreFoundation -lc++ -lresolv -lz -lbz2 && \
//   /private/tmp/claude-501/distro-groups-ffi

import CryptoKit
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

let GV: [String: Any] = {
    let url = root.appendingPathComponent("rust/retichat-ffi/tests/data/distro_group_sync_vectors.json")
    guard let raw = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
        fatalError("the group sync vectors are not readable at \(url.path)")
    }
    return json
}()

func gv(_ key: String) -> [String: Any] { GV[key] as! [String: Any] }
func gvList(_ key: String) -> [[String: Any]] { GV[key] as! [[String: Any]] }

/// An identity handle from the vectors' private key (X25519 private | Ed25519 seed).
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

/// retichat_distro_unwrap, as RfedDistroClient.unwrapAndDeliver calls it: the JSON and its decode.
func unwrap(_ handle: UInt64, _ blob: Data) -> (json: [String: Any], parsed: DistroUnwrapped)? {
    var outLen: UInt32 = 0
    let ptr = blob.withUnsafeBytes { raw -> UnsafeMutablePointer<UInt8>? in
        retichat_distro_unwrap(handle, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(blob.count), &outLen)
    }
    guard let ptr else { return nil }
    let data = Data(bytes: ptr, count: Int(outLen))
    rns_free_bytes(ptr, outLen)
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let parsed = try? JSONDecoder().decode(DistroUnwrapped.self, from: data) else { return nil }
    return (json, parsed)
}

func reading(_ object: Any) -> DistroGroupSync.Reading? {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
    return try? JSONDecoder().decode(DistroGroupSync.Reading.self, from: data)
}

/// The fields map of a packed message: dest | src | signature | [f64, bin, bin, fields].
func fieldsOf(_ packed: Data) -> Data? {
    let bytes = [UInt8](packed.dropFirst(96))
    guard bytes.count > 14, bytes[0] == 0x94, bytes[1] == 0xcb, bytes[10] == 0xc4 else { return nil }
    // 0x94, f64 (9 bytes), the title bin8 (2 + its length), the content bin8 (2 + its length).
    var at = 10 + 2 + Int(bytes[11])
    guard at + 1 < bytes.count, bytes[at] == 0xc4 else { return nil }
    at += 2 + Int(bytes[at + 1])
    return Data(bytes[at...])
}

// MARK: - The unwrap

func aSealedGroupSyncAndAMembersGroupMessagesUnwrapRouteAndPassTheAppsRulesAsTheSharedLayerReadThem() {
    let d = identity("distro")
    check(d != 0, "D's identity loads")
    for v in gvList("sealed") {
        let name = v["name"] as! String
        let expected = v["expected"] as! [String: Any]
        let hash = v["hash_hex"] as! String
        guard let (json, u) = unwrap(d, unhexData(v["blob_hex"] as! String)) else {
            check(false, "\(name): unwrapped and decoded")
            continue
        }
        checkEqual(u.hash, hash, "\(name): its LXMF hash")
        checkEqual(u.signature_validated, expected["signature_validated"] as? Bool, "\(name): the signature verdict")
        checkEqual(u.unverified_reason, expected["unverified_reason"] as? Int, "\(name): the reason")
        if let sync = expected["group_sync"] as? [String: Any] {
            checkEqual(u.groupRoute, .groupSync(hash: hash), "\(name): a group sync, on its hash")
            checkEqual(u.group_sync, reading(sync), "\(name): the reading the shared layer gives")
            check(json["group_sync"] is [String: Any], "\(name): group_sync is an object")
            if case .apply(let form, let sibling) = DistroGroupSync.disposition(
                sourceHex: u.source_hash, distroHex: D, signatureValidated: u.signature_validated ?? false,
                reading: u.group_sync ?? DistroGroupSync.Reading(), deviceHex: THIS) {
                checkEqual(sibling, SIB, "\(name): its 0xFD is a sibling")
                checkEqual(form.groupId, GID, "\(name): its group")
            } else {
                check(false, "\(name): applied on a sibling")
            }
            checkEqual(DistroGroupSync.disposition(sourceHex: u.source_hash, distroHex: D, signatureValidated: u.signature_validated ?? false,
                                                   reading: u.group_sync ?? DistroGroupSync.Reading(), deviceHex: SIB),
                       .ownEcho, "\(name): its writer's own echo")
            check(!u.is_delivery_notification || u.group_sync != nil, "\(name): judged before the delivery-notification test")
        } else {
            checkEqual(u.groupRoute, .group(hash: hash, groupId: GID), "\(name): a group message, on its hash, never a DM")
            checkEqual(u.group_action, expected["group_action"] as? String, "\(name): the action")
            checkEqual(u.sender_key, expected["sender_key_hex"] as? String, "\(name): the key the receipt binds")
            checkEqual(u.packedData != nil, expected["packed"] as? Bool ?? false, "\(name): the packed copy")
            let signature = DeliveryPolicy.Signature.reason(valid: u.signature_validated ?? false, unverifiedReason: u.unverified_reason)
            let verdict = GroupFirstRules.check(signature: signature, sourceHex: u.source_hash, groupSender: nil,
                                                selfAddresses: [D, THIS], distros: [D], siblings: [])
            checkEqual(verdict == .forged, signature == DeliveryPolicy.Signature.invalid, "\(name): forged only when invalid")
        }
    }
}

// MARK: - The writer

func theAppsWriterJSONThroughTheBridgeWritesTheReferenceFieldsSignedByDAndASiblingReadsTheSameSync() {
    let d = identity("distro")
    let dHash = unhexData(D)
    var pub = [UInt8](repeating: 0, count: 64)
    check(retichat_identity_public_key(d, &pub, 64) == 64, "D's public key")
    let key = try? Curve25519.Signing.PublicKey(rawRepresentation: Data(pub[32...]))
    for v in gvList("ops") {
        let name = v["name"] as! String
        let s = v["sync"] as! [String: Any]
        let op = DistroGroupSync.Op(rawValue: s["op"] as! String)!
        let json = DistroGroupSync.writerJSON(op: op, groupId: s["group_id"] as! String,
                                              atMs: (s["at_ms"] as! NSNumber).uint64Value,
                                              name: s["name"] as? String, membersCsv: s["members"] as? String,
                                              keys: s["keys"] as? [String], creator: s["creator"] as? String,
                                              text: s["text"] as? String, left: s["left"] as! [String])
        let msg = bridge.messageCreate(destHash: dHash, sourceHash: dHash, content: "", title: "",
                                       method: LxmfMethod.direct, identityHandle: d)
        check(msg != 0, "\(name): a message from D to D")
        check(bridge.messageSetDistroGroupSync(handle: msg, syncJson: json, dHex: D, deviceHex: SIB), "\(name): the writer takes the app's JSON")
        guard let packed = bridge.messagePack(handle: msg) else { check(false, "\(name): packed"); continue }
        checkEqual(hexOf(packed.prefix(16)), D, "\(name): to D")
        checkEqual(hexOf(packed.dropFirst(16).prefix(16)), D, "\(name): from D")
        check(fieldsOf(packed).map(hexOf) == v["fields_hex"] as? String, "\(name): the reference's very fields bytes")
        // Signed by D: LXMF signs dest | src | payload | hash.
        let payload = packed.dropFirst(96)
        let signed = Data(packed.prefix(32)) + payload
        let hash = Data(SHA256.hash(data: signed))
        check(key?.isValidSignature(Data(packed.dropFirst(32).prefix(64)), for: signed + hash) ?? false, "\(name): signed by D")
        // Sealed for D, a sibling reads the same G.
        guard let sealed = bridge.distroSeal(distroHandle: d, packed: packed) else { check(false, "\(name): sealed"); continue }
        guard let (_, u) = unwrap(d, sealed.sealed) else { check(false, "\(name): a sibling unwraps it"); continue }
        checkEqual(u.groupRoute, .groupSync(hash: hexOf(hash)), "\(name): a group sync, on its hash")
        checkEqual(u.group_sync, reading(v["expected"]!), "\(name): read as the reference reads it")
    }
}

func theWriterRefusesWhatAReceiverWouldDropAndAMessageNotFromDToD() {
    let d = identity("distro")
    let dHash = unhexData(D)
    func attempt(_ json: String, dest: Data? = nil) -> Bool {
        let msg = bridge.messageCreate(destHash: dest ?? dHash, sourceHash: dHash, content: "", title: "",
                                       method: LxmfMethod.direct, identityHandle: d)
        guard msg != 0 else { return false }
        return bridge.messageSetDistroGroupSync(handle: msg, syncJson: json, dHex: D, deviceHex: SIB)
    }
    let good = DistroGroupSync.writerJSON(op: .accept, groupId: GID, atMs: 1, name: "n", membersCsv: "\(D),\(M)",
                                          keys: [], creator: M, left: [])
    check(attempt(good), "a well-formed accept is written")
    check(!attempt(DistroGroupSync.writerJSON(op: .accept, groupId: GID, atMs: 1, name: "n", membersCsv: M, keys: [], creator: M, left: [])),
          "members that do not name D are refused")
    check(!attempt(DistroGroupSync.writerJSON(op: .accept, groupId: GID, atMs: 1, name: "n", membersCsv: "\(D),\(M)", keys: [], creator: D, left: [])),
          "creator D is refused")
    check(!attempt(DistroGroupSync.writerJSON(op: .leave, groupId: GID, atMs: 1, left: (0..<33).map { String(format: "%032x", $0) })),
          "33 ids in left are refused")
    check(!attempt(good, dest: unhexData(M)), "a message not to D is refused")
}

// MARK: - The vectors given as fields bytes (LXMF-rust 16a9902; RFed SPEC §17.14 "Repeated keys")

/// D's Ed25519 key, from the vectors' private key (X25519 private | Ed25519 seed).
let dSigningKey: Curve25519.Signing.PrivateKey = {
    let bytes = unhexData(gv("distro")["private_key_hex"] as! String)
    return try! Curve25519.Signing.PrivateKey(rawRepresentation: bytes.suffix(32))
}()

/// The Ed25519 key of the vectors' identity `who` ("distro", "member", "forger").
func signingKey(_ who: String) -> Curve25519.Signing.PrivateKey {
    let bytes = unhexData(gv(who)["private_key_hex"] as! String)
    return try! Curve25519.Signing.PrivateKey(rawRepresentation: bytes.suffix(32))
}

/// A message from `source` to D whose fields map is `fieldsHex` exactly as given (an ext of an
/// unknown type, a bin GROUP_ID), packed as LXMF packs it, [1790000000.5, "", "x", fields], and
/// signed by `key` as LXMF signs: dest | src | payload | SHA-256(dest | src | payload).
func packedToD(from source: String, key: Curve25519.Signing.PrivateKey, fieldsHex: String) -> Data {
    let dHash = unhexData(D)
    let src = unhexData(source)
    var payload = unhexData("94cb41daac4ee0200000c400c40178")
    payload.append(unhexData(fieldsHex))
    let signed = dHash + src + payload
    let hash = Data(SHA256.hash(data: signed))
    let signature = try! key.signature(for: signed + hash)
    return dHash + src + signature + payload
}

/// A message from D to D (packedToD), signed by D.
func packedFromD(fieldsHex: String) -> Data {
    packedToD(from: D, key: dSigningKey, fieldsHex: fieldsHex)
}

/// `packed` sealed for D (retichat_distro_seal) and unwrapped with D's key, as a sibling gets it.
func throughTheDistro(_ d: UInt64, _ packed: Data) -> (json: [String: Any], parsed: DistroUnwrapped)? {
    guard let sealed = bridge.distroSeal(distroHandle: d, packed: packed) else { return nil }
    return unwrap(d, sealed.sealed)
}

/// variants: each G of the reference (the web's int-64 at_ms, a members csv with a combining mark
/// after its last comma, a 0xFD that is an int or an array, ...) reaches a sibling, is read
/// as the shared layer reads it, and passes the app's own rules.
func everyVariantReachesASiblingAndPassesTheAppsRulesAsTheSharedLayerReadsIt() {
    let d = identity("distro")
    checkEqual(gvList("variants").count, 15, "the variants of 16a9902")
    for v in gvList("variants") {
        let name = v["name"] as! String
        guard let (_, u) = throughTheDistro(d, unhexData(v["packed_hex"] as! String)) else {
            check(false, "\(name): sealed and unwrapped")
            continue
        }
        checkEqual(u.hash, v["hash_hex"] as? String, "\(name): its LXMF hash")
        checkEqual(u.groupRoute, .groupSync(hash: v["hash_hex"] as! String), "\(name): a group sync, on its hash")
        checkEqual(u.group_sync, reading(v["expected"]!), "\(name): the reading the shared layer gives")
        if case .apply(let form, let sibling) = DistroGroupSync.disposition(
            sourceHex: u.source_hash, distroHex: D, signatureValidated: u.signature_validated ?? false,
            reading: u.group_sync ?? DistroGroupSync.Reading(), deviceHex: THIS) {
            checkEqual(sibling, DeliveryPolicy.hash(u.group_sync?.by), "\(name): its 0xFD, when it has one, is a sibling")
            checkEqual(form.groupId, GID, "\(name): its group")
            if form.op == .create || form.op == .accept {
                checkEqual(form.members, DeliveryPolicy.members(LxmfFieldsDecoder.groupCsv(form.membersCsv)), "\(name): the members")
                check(form.members.contains(D), "\(name): the members name D")
            }
        } else {
            check(false, "\(name): applied on a sibling")
        }
    }
}

/// rejects: each is a G the shared layer reads with its problem named, and the app's rules
/// never apply it. A members csv whose combining mark comes before D's entry names no D, by the
/// app's own rule 4 too.
func everyRejectReachesASiblingAsAGroupSyncTheAppNeverApplies() {
    let d = identity("distro")
    checkEqual(gvList("rejects").count, 53, "the rejects of 16a9902")
    for v in gvList("rejects") {
        let name = v["name"] as! String
        guard let (_, u) = throughTheDistro(d, packedFromD(fieldsHex: v["fields_hex"] as! String)) else {
            check(false, "\(name): sealed and unwrapped")
            continue
        }
        checkEqual(u.signature_validated, true, "\(name): signed by D")
        guard let r = u.group_sync, case .groupSync = u.groupRoute else {
            check(false, "\(name): a group sync")
            continue
        }
        check(r.problem != nil, "\(name): the shared layer names its problem")
        switch DistroGroupSync.disposition(sourceHex: u.source_hash, distroHex: D, signatureValidated: u.signature_validated ?? false,
                                           reading: r, deviceHex: THIS) {
        case .malformed: break
        case let other: check(false, "\(name): dropped by rule 4, got \(other)")
        }
    }
    var r = reading(gvList("ops").first { $0["name"] as? String == "accept_empty_left" }!["expected"]!)!
    r.members = "\(M),\u{301}\(D)"
    if case .success = DistroGroupSync.form(r, distroHex: D) {
        check(false, "members naming D only after a combining mark do not name D")
    }
}

/// group_entries: each fields map (none repeats a key: those are `refused`), an unknown ext
/// skipped and a bin GROUP_ID, through the distro unwrap the app calls, decoded into the app's
/// DistroUnwrapped and routed as the distro path routes it.
func everyGroupEntriesVectorThroughTheDistroIsDecodedAndRoutedAsTheSharedLayerReadsIt() {
    let d = identity("distro")
    checkEqual(gvList("group_entries").count, 21, "the group_entries of 16a9902")
    for v in gvList("group_entries") {
        let name = v["name"] as! String
        let e = v["expected"] as! [String: Any]
        guard let (_, u) = throughTheDistro(d, packedFromD(fieldsHex: v["fields_hex"] as! String)) else {
            check(false, "\(name): sealed and unwrapped")
            continue
        }
        let isG = e["group_sync"] as! Bool
        let hasId = e["has_group_id"] as! Bool
        let id = e["group_id"] as? String
        checkEqual(u.has_group_id ?? false, hasId, "\(name): has_group_id")
        checkEqual(u.group_id, id, "\(name): group_id")
        checkEqual(u.group_action, e["group_action"] as? String, "\(name): group_action")
        checkEqual(u.group_name, e["group_name"] as? String, "\(name): group_name")
        checkEqual(u.group_sync != nil, isG, "\(name): a G")
        guard let hash = u.hash else { check(false, "\(name): its hash"); continue }
        let route: DistroGroupRoute = isG ? .groupSync(hash: hash)
            : !hasId ? .other
            : id.map { .group(hash: hash, groupId: $0) } ?? .dropped("its GROUP_ID is not 32 hex characters")
        checkEqual(u.groupRoute, route, "\(name): the route")
    }
}

/// RFed SPEC §17.14 "Repeated keys" (James, 2026-10-11: parity): each `refused` vector and each
/// `key_equality` pair the reference refuses is refused whole by the library on both paths the
/// app takes, as Python LXMF refuses it. The distro unwrap returns nothing, with an error the app
/// knows as the refusal LXMF-rust has already logged (RepeatedKeys.isRefusal: the app says
/// nothing more, so the refusal is logged once); the group receipt's unpack, the direct path's
/// LXMessage unpack that the router also runs before any delivery, returns nothing, and the app's
/// native layer (FFIGroupNative, what reads a creator's status) knows it as a refusal, so the skip
/// names it "refused whole", never "not an LXMF message". Nothing reaches a reader of the fields,
/// so nothing is shown, stored or applied. Each pair the reference reads is unwrapped and unpacked.
func everyMessageThatRepeatsAKeyIsRefusedWholeOnTheDistroPathAndTheDirectPath() {
    let d = identity("distro")
    checkEqual(gvList("refused").count, 11, "the refused vectors of 16a9902")
    checkEqual(gvList("key_equality").count, 22, "the key_equality pairs of 16a9902")
    var refusals = 0
    for v in gvList("refused") + gvList("key_equality") {
        let name = v["name"] as! String
        let refuse = (v["refused"] as? Bool) ?? true
        let packed = unhexData(v["packed_hex"] as! String)
        guard let sealed = bridge.distroSeal(distroHandle: d, packed: packed) else {
            check(false, "\(name): sealed for D")
            continue
        }
        _ = bridge.rnsLastError()
        var outLen: UInt32 = 0
        let ptr = sealed.sealed.withUnsafeBytes { raw -> UnsafeMutablePointer<UInt8>? in
            retichat_distro_unwrap(d, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(sealed.sealed.count), &outLen)
        }
        let error = bridge.rnsLastError()
        let element = MainActor.assumeIsolated { FFIGroupNative(bridge: bridge).unpack(packed) }
        if refuse {
            refusals += 1
            check(ptr == nil, "\(name): the distro unwrap refuses it whole")
            check(RepeatedKeys.isRefusal(error) && (error ?? "").contains("repeats a key"),
                  "\(name): the app knows the unwrap's error as the refusal already logged (\(error ?? "no error"))")
            checkEqual(element, .refused, "\(name): the direct path's unpack refuses it whole, and the app knows it as the refusal")
        } else {
            check(ptr != nil && outLen > 0, "\(name): the reference reads it, and so does the unwrap (\(error ?? "no error"))")
            check(element.message != nil, "\(name): and the direct path's unpack (\(element))")
        }
        if let ptr { rns_free_bytes(ptr, outLen) }
    }
    checkEqual(refusals, 11 + 15, "every message the reference refuses")
}

/// RFed SPEC §17.14 rule 1: a G whose unwrapped source is not D (a member's, a stranger's), sealed
/// for D and fanned out, reaches a sibling as a well-formed group sync on its hash, and is ignored
/// whatever its signature is worth: rule 1 decides before rule 2, so its `left` is never applied
/// and its 0xFD never learnt. The same G from D is applied.
func aGroupSyncWhoseSourceIsNotDIsIgnoredByRuleOne() {
    let d = identity("distro")
    let leave = gvList("ops").first { $0["name"] as? String == "leave_full_left" }!
    let fieldsHex = leave["fields_hex"] as! String
    for who in ["member", "forger"] {
        let source = gv(who)["lxmf_delivery_hash_hex"] as! String
        guard let (_, u) = throughTheDistro(d, packedToD(from: source, key: signingKey(who), fieldsHex: fieldsHex)) else {
            check(false, "\(who): sealed and unwrapped")
            continue
        }
        checkEqual(u.source_hash, source, "\(who): the unwrapped source")
        guard let hash = u.hash, let r = u.group_sync else {
            check(false, "\(who): a group sync with its hash")
            continue
        }
        checkEqual(u.groupRoute, .groupSync(hash: hash), "\(who): routed as a group sync, on its hash")
        check(r.problem == nil, "\(who): well formed: only its source is wrong")
        for validated in [u.signature_validated ?? false, true, false] {
            checkEqual(DistroGroupSync.disposition(sourceHex: u.source_hash, distroHex: D, signatureValidated: validated,
                                                   reading: r, deviceHex: THIS),
                       .notFromDistro, "\(who): ignored by rule 1 (signature validated: \(validated))")
        }
    }
    guard let (_, fromD) = throughTheDistro(d, packedFromD(fieldsHex: fieldsHex)), let r = fromD.group_sync else {
        check(false, "the control from D: sealed and unwrapped")
        return
    }
    if case .apply = DistroGroupSync.disposition(sourceHex: fromD.source_hash, distroHex: D,
                                                 signatureValidated: fromD.signature_validated ?? false,
                                                 reading: r, deviceHex: THIS) {} else {
        check(false, "the control: the same G from D, signed by D, is applied")
    }
}

let allTests: [(String, () -> Void)] = [
    ("a sealed group sync and a member's group messages unwrap, route and pass the app's rules as the shared layer read them",
     aSealedGroupSyncAndAMembersGroupMessagesUnwrapRouteAndPassTheAppsRulesAsTheSharedLayerReadThem),
    ("the app's writer JSON through the bridge writes the reference's fields, signed by D, and a sibling reads the same sync",
     theAppsWriterJSONThroughTheBridgeWritesTheReferenceFieldsSignedByDAndASiblingReadsTheSameSync),
    ("the writer refuses what a receiver would drop, and a message not from D to D",
     theWriterRefusesWhatAReceiverWouldDropAndAMessageNotFromDToD),
    ("every variant reaches a sibling and passes the app's rules as the shared layer reads it",
     everyVariantReachesASiblingAndPassesTheAppsRulesAsTheSharedLayerReadsIt),
    ("every reject reaches a sibling as a group sync the app never applies",
     everyRejectReachesASiblingAsAGroupSyncTheAppNeverApplies),
    ("every group_entries vector through the distro is decoded and routed as the shared layer reads it",
     everyGroupEntriesVectorThroughTheDistroIsDecodedAndRoutedAsTheSharedLayerReadsIt),
    ("every message that repeats a key is refused whole on the distro path and the direct path",
     everyMessageThatRepeatsAKeyIsRefusedWholeOnTheDistroPathAndTheDirectPath),
    ("a group sync whose source is not D is ignored by rule 1",
     aGroupSyncWhoseSourceIsNotDIsIgnoredByRuleOne),
]

@main
enum DistroGroupsFFITests {
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
