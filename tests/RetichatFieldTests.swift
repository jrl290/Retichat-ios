// RetichatFieldTests.swift
//
// The Retichat field 0xD1 on iOS (LXMF-rust/DISPLAY_NAMES.md §2.1 and §10,
// agreed 2026-09-27): 0xD1 is a msgpack map, the name is key 0 (decoded by
// the Rust side), and the group entries move from the top-level fields
// 0xA0-0xA8 to keys 1-9. Readers take each entry from the map when it holds
// it with its type, else from the old field; senders write the form
// RetichatField.groupEntriesInRetichatField selects, false until the switch
// around 2026-10-26.
//
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/retichat-field \
//     Retichat-ios/Retichat/Bridge/LxmfFields.swift \
//     Retichat-ios/tests/RetichatFieldTests.swift && \
//     /private/tmp/claude-501/retichat-field
//
// The decoder (LxmfFieldsDecoder, compiled into the app and the NSE) runs
// for real against the shared vectors the Rust suite runs
// (LXMF-rust/tests/retichat_field_vectors.json). The send helper's pure
// part (GroupFieldWrite) runs for real against the file's encode cases; the
// bytes themselves are written by the Rust FFI and pinned by its tests. The
// wiring needs the FFI, so it is asserted on the source.

import Foundation

nonisolated(unsafe) var failures: [String] = []

func check(_ ok: Bool, _ what: String, _ detail: String = "") {
    if !ok {
        let message = detail.isEmpty ? what : "\(what) — \(detail)"
        failures.append(message)
        print("FAIL: \(message)")
    }
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let workspace = root.deletingLastPathComponent()

func source(_ path: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

func hex(_ s: String) -> Data {
    var out = Data()
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}

func loadVectors() -> [String: Any]? {
    let url = workspace.appendingPathComponent("LXMF-rust/tests/retichat_field_vectors.json")
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        check(false, "the shared vectors load", url.path)
        return nil
    }
    return json
}

/// The vectors' JSON name for each group entry, from keys[].
func entryNames(_ json: [String: Any]) -> [String: GroupEntry] {
    var out: [String: GroupEntry] = [:]
    for k in json["keys"] as? [[String: Any]] ?? [] {
        guard let key = k["key"] as? Int, let name = k["name"] as? String,
              let entry = GroupEntry(rawValue: UInt8(key)) else { continue }
        out[name] = entry
    }
    return out
}

/// A JSON value (string or bool) as a GroupValue. JSONSerialization gives
/// NSNumber for both bools and ints, so the bool is told by its type id.
func groupValue(_ any: Any?) -> GroupValue? {
    if let s = any as? String { return .str(s) }
    if let n = any as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
    return nil
}

// MARK: - Keys (§10's table)

func testTheKeysMatchTheSpecTable() {
    check(RetichatField.field == 0xD1, "FIELD_RETICHAT is 0xD1")
    check(RetichatField.displayNameKey == 0 && RetichatField.maxKey == 127, "key 0 is the name; keys are 0-127")
    guard let json = loadVectors() else { return }
    let keys = json["keys"] as? [[String: Any]] ?? []
    check(keys.count == 10, "the vectors list keys 0-9")
    for k in keys {
        guard let key = k["key"] as? Int else { continue }
        let type = k["type"] as? String
        if key == 0 {
            check(type == "name" && k["legacy_field"] is NSNull, "key 0 is the name, with no old field")
            continue
        }
        guard let entry = GroupEntry(rawValue: UInt8(key)) else {
            check(false, "GroupEntry has key \(key)")
            continue
        }
        check(Int(entry.legacyField) == k["legacy_field"] as? Int,
              "key \(key)'s old field is \(k["legacy_field"] ?? "?")", "\(entry.legacyField)")
        check(entry.isBool == (type == "bool"), "key \(key) is a \(type ?? "?")")
        check(GroupEntry(legacyField: entry.legacyField) == entry, "old field \(entry.legacyField) maps back to key \(key)")
    }
    check(GroupEntry.allCases.count == 9, "nine group entries")
    check(GroupEntry(legacyField: 0x9F) == nil && GroupEntry(legacyField: 0xA9) == nil
          && GroupEntry(legacyField: 0xD1) == nil, "no other field is a group field")
}

// MARK: - Reader (§10), the shared vectors

func testTheDecoderRunsTheSharedVectors() {
    guard let json = loadVectors() else { return }
    let names = entryNames(json)
    check(names.count == 9, "the vectors name all nine group entries")
    let cases = json["decode"] as? [[String: Any]] ?? []
    check(cases.count >= 33, "the decode cases load", "\(cases.count)")
    for c in cases {
        let name = c["name"] as? String ?? "?"
        guard let raw = c["fields_msgpack_hex"] as? String,
              let group = c["group"] as? [String: Any] else {
            check(false, "decode case \(name) is well formed")
            continue
        }
        check(group.count == 9, "\(name): all nine group entries are listed")
        var want: [GroupEntry: GroupValue] = [:]
        for (jsonName, value) in group {
            guard let entry = names[jsonName] else {
                check(false, "\(name): \(jsonName) is a group entry")
                continue
            }
            if let v = groupValue(value) { want[entry] = v }
        }
        let got = LxmfFieldsDecoder.decode(hex(raw)).groupEntries
        check(got == want, "decode: \(name)", "got \(got), want \(want)")
    }
}

/// The typed LxmfFields the app reads are the resolved entries, parsed as
/// before (members and relay-seen split on commas, member keys checked).
func testTheTypedFieldsComeFromTheResolvedEntries() {
    let groupId = "0123456789abcdef0123456789abcdef"
    let a = String(repeating: "1", count: 32), b = String(repeating: "2", count: 32)
    let pubKey = Data(repeating: 7, count: 64).base64EncodedString()
    // {0xD1: {1: id, 2: "a,b", 6: " b ", 8: true, 9: "a:<key>"}}, and an
    // old 0xA3 "leave" beside it.
    var map: [UInt8] = [0x01] + str(groupId) + [0x02] + str("\(a),\(b)") + [0x06] + str(" \(b) ,")
    map += [0x08, 0xC3, 0x09] + str("\(a):\(pubKey),\(a):\(pubKey),short:x")
    let fields = LxmfFieldsDecoder.decode(Data([0x82, 0xCC, 0xD1, 0x85] + map + [0xCC, 0xA3] + str("leave")))
    check(fields.groupId == groupId, "groupId from key 1")
    check(fields.groupMembers == [a, b], "groupMembers from key 2, split on commas")
    check(fields.groupRelaySeen == [b], "groupRelaySeen from key 6, trimmed, empties dropped")
    check(fields.groupRelayDone == true, "groupRelayDone from key 8")
    check(fields.groupAction == "leave", "groupAction from the old 0xA3")
    check(fields.groupMemberKeys == [a: pubKey],
          "groupMemberKeys from key 9: a repeated hash no longer traps (uniqueKeysWithValues did), malformed pairs dropped")
    check(fields.groupName == nil && fields.groupSender == nil && fields.groupRelayFor == nil, "absent entries are nil")
}

func str(_ s: String) -> [UInt8] {
    let b = Array(s.utf8)
    if b.count < 32 { return [0xA0 | UInt8(b.count)] + b }
    precondition(b.count < 256)
    return [0xD9, UInt8(b.count)] + b
}

/// Values of every shape around the group entries never desynchronise the
/// walk, and malformed input ends it without trapping or hanging.
func testTheWalkStaysInStep() {
    let transfer = [0xCC, 0xFB] + str("rfed.distro.transfer")
    // An old field of the wrong type (bin, map, ext, str32, float) before
    // other fields: each is consumed whole.
    let shapes: [[UInt8]] = [
        [0xC4, 0x02, 0x69, 0x64],                       // bin8
        [0x82, 0x01, 0xA1, 0x61, 0x02, 0x92, 0x01, 0x02], // map with a nested array
        [0xD6, 0x01, 1, 2, 3, 4],                       // fixext4
        [0xC7, 0x02, 0x05, 9, 9],                       // ext8
        [0xDB, 0, 0, 0, 1, 0x78],                       // str32 "x"
        [0xCB] + [UInt8](repeating: 0, count: 8),       // float64
        [0xDD, 0, 0, 0, 1, 0xC0],                       // array32 [nil]
        [0xDF, 0, 0, 0, 1, 0x01, 0xC0],                 // map32 {1: nil}
    ]
    for (i, shape) in shapes.enumerated() {
        let bytes = [0x83, 0xCC, 0xA2] + shape + transfer + [0xCC, 0xA0] + str("g")
        let fields = LxmfFieldsDecoder.decode(Data(bytes))
        check(fields.groupId == "g" && fields.customType == "rfed.distro.transfer",
              "shape \(i) at 0xA2 is skipped whole and the fields after it decode")
        check(fields.groupName == (i == 4 ? "x" : nil), "shape \(i) at 0xA2 gives a group name only when a str")
        let inMap = [0x83, 0xCC, 0xD1, 0x82, 0x03] + shape + [0x01] + str("h") + transfer + [0xCC, 0xA0] + str("g")
        let viaMap = LxmfFieldsDecoder.decode(Data(inMap))
        check(viaMap.groupId == "h" && viaMap.customType == "rfed.distro.transfer",
              "shape \(i) inside the map is skipped whole: key 1 after it wins, fields after the map decode")
    }
    // A str32 group name reads (the old decoder knew str8/str16 only).
    check(LxmfFieldsDecoder.decode(Data([0x81, 0xCC, 0xA2, 0xDB, 0, 0, 0, 2, 0x68, 0x69])).groupName == "hi",
          "a str32 value is a str")
    // map16 at the top level and inside 0xD1.
    let map16 = [0xDE, 0x00, 0x01, 0xCC, 0xD1, 0xDE, 0x00, 0x01, 0x03] + str("m")
    check(LxmfFieldsDecoder.decode(Data(map16)).groupName == "m", "map16 at both levels")

    // Deep nesting inside 0xD1 does not exhaust the stack.
    let deep = [0x82, 0xCC, 0xD1, 0x81, 0x05] + [UInt8](repeating: 0x91, count: 200_000) + [0xC0]
        + [0xCC, 0xA0] + str("g")
    check(LxmfFieldsDecoder.decode(Data(deep)).groupId == "g", "200000 nested arrays are skipped")
    // Counts and lengths far past the buffer end the walk.
    let huge: [[UInt8]] = [
        [0xDF, 0xFF, 0xFF, 0xFF, 0xFF, 0xCC, 0xA0],
        [0x81, 0xCC, 0xD1, 0xDF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01],
        [0x81, 0xCC, 0xA2, 0xDD, 0xFF, 0xFF, 0xFF, 0xFF, 0xC0],
        [0x81, 0xCC, 0xA2, 0xDB, 0xFF, 0xFF, 0xFF, 0xFF, 0x41],
        [0x81, 0xCC, 0xA2, 0xC9, 0xFF, 0xFF, 0xFF, 0xFF],
        [0x81, 0xCF, 0x00],
        [0x81, 0xCC, 0xD1, 0x81, 0xD3, 0x00],
    ]
    for (i, bytes) in huge.enumerated() {
        let fields = LxmfFieldsDecoder.decode(Data(bytes))
        check(fields.groupEntries.isEmpty, "truncated input \(i) yields nothing, without trapping or hanging")
    }
}

// MARK: - Sender (§10)

func testTheSendFormsMatchTheEncodeVectors() {
    guard let json = loadVectors() else { return }
    let cases = json["encode"] as? [[String: Any]] ?? []
    check(cases.count >= 5, "the encode cases load", "\(cases.count)")
    for c in cases {
        let name = c["name"] as? String ?? "?"
        guard let start = c["start_hex"] as? String, let legacyHex = c["legacy_hex"] as? String,
              let retichatHex = c["retichat_hex"] as? String,
              let list = c["entries"] as? [[String: Any]] else {
            check(false, "encode case \(name) is well formed")
            continue
        }
        var entries: [(GroupEntry, GroupValue)] = []
        for e in list {
            guard let key = e["key"] as? Int, let entry = GroupEntry(rawValue: UInt8(key)),
                  let value = groupValue(e["value"]) else {
                check(false, "\(name): entry \(e) is a group entry")
                continue
            }
            entries.append((entry, value))
        }
        // What the message ends up holding: the last value set for each entry.
        var final: [GroupEntry: GroupValue] = [:]
        for (entry, value) in entries { final[entry] = value }
        let startKeys = topLevelKeys(hex(start))

        for inRetichat in [false, true] {
            let form = inRetichat ? "the Retichat field" : "the old fields"
            let expected = hex(inRetichat ? retichatHex : legacyHex)
            let writes = entries.compactMap { GroupFieldWrite.of($0.0, $0.1, inRetichatField: inRetichat) }
            check(writes.count == entries.count, "\(name): every entry has a write in \(form)")

            // Where each write goes, against the bytes the Rust FFI produces.
            let top = topLevelKeys(expected)
            let mapKeys = retichatMapKeys(expected)
            if inRetichat {
                let keys = writes.compactMap { w -> UInt64? in
                    if case .retichat(let key, _) = w { return UInt64(key) }
                    return nil
                }
                check(keys.count == writes.count, "\(name): \(form) writes only map entries")
                check(Set(keys).isSubset(of: Set(mapKeys)), "\(name): each key is in the 0xD1 map", "\(mapKeys)")
                check(!top.contains { (0xA0...0xA8).contains($0) }, "\(name): no old field in \(form)")
            } else {
                var order: [UInt64] = []
                for w in writes {
                    guard case .topLevel(let field, _) = w else { continue }
                    if !order.contains(UInt64(field)) { order.append(UInt64(field)) }
                }
                check(order.count == Set(entries.map { $0.0 }).count, "\(name): \(form) writes only top-level fields")
                check(top == startKeys + order,
                      "\(name): old fields appended after the start in set order", "\(top) vs \(startKeys + order)")
            }
            // Whatever form was sent, the reader gets the same entries back.
            let read = LxmfFieldsDecoder.decode(expected).groupEntries
            check(read == final, "\(name): \(form) reads back as sent", "\(read)")
        }
    }
}

/// Top-level integer keys of a msgpack map, in order.
func topLevelKeys(_ data: Data) -> [UInt64] {
    let bytes = [UInt8](data)
    guard let first = bytes.first, first & 0xF0 == 0x80 else { return [] }
    var offset = 1
    var keys: [UInt64] = []
    for _ in 0..<Int(first & 0x0F) {
        if let k = LxmfFieldsDecoder.readKey(bytes, &offset) { keys.append(k) }
        LxmfFieldsDecoder.skipValue(bytes, &offset)
    }
    return keys
}

/// Keys of the fixmap at top-level key 0xD1, in order.
func retichatMapKeys(_ data: Data) -> [UInt64] {
    let bytes = [UInt8](data)
    guard let first = bytes.first, first & 0xF0 == 0x80 else { return [] }
    var offset = 1
    for _ in 0..<Int(first & 0x0F) {
        let k = LxmfFieldsDecoder.readKey(bytes, &offset)
        if k == 0xD1, offset < bytes.count, bytes[offset] & 0xF0 == 0x80 {
            let n = Int(bytes[offset] & 0x0F)
            offset += 1
            var keys: [UInt64] = []
            for _ in 0..<n {
                if let key = LxmfFieldsDecoder.readKey(bytes, &offset) { keys.append(key) }
                LxmfFieldsDecoder.skipValue(bytes, &offset)
            }
            return keys
        }
        LxmfFieldsDecoder.skipValue(bytes, &offset)
    }
    return []
}

/// The constant is false until the switch; the default form follows it, and
/// flipping it gives the other form (what the switch changes).
func testTheConstantSelectsTheForm() {
    check(RetichatField.groupEntriesInRetichatField == false,
          "groupEntriesInRetichatField is false until the switch around 2026-10-26")
    for entry in GroupEntry.allCases {
        let value: GroupValue = entry.isBool ? .bool(true) : .str("v")
        let now = GroupFieldWrite.of(entry, value)
        let asConstant = GroupFieldWrite.of(entry, value, inRetichatField: RetichatField.groupEntriesInRetichatField)
        check(now == asConstant, "\(entry): the default form is the constant's")
        check(GroupFieldWrite.of(entry, value, inRetichatField: false) == .topLevel(field: entry.legacyField, value: value),
              "\(entry): false writes old field \(entry.legacyField)")
        check(GroupFieldWrite.of(entry, value, inRetichatField: true) == .retichat(key: entry.key, value: value),
              "\(entry): true writes key \(entry.key) of 0xD1")
        let wrong: GroupValue = entry.isBool ? .str("true") : .bool(true)
        check(GroupFieldWrite.of(entry, wrong) == nil && GroupFieldWrite.of(entry, wrong, inRetichatField: true) == nil,
              "\(entry): the wrong type is refused in both forms")
    }
    // The same constant in every client (§10): the Rust one is false too.
    let rust = (try? String(contentsOf: workspace.appendingPathComponent("LXMF-rust/src/retichat_field.rs"),
                            encoding: .utf8)) ?? ""
    check(rust.contains("pub const GROUP_ENTRIES_IN_RETICHAT_FIELD: bool = false;"),
          "lxmf_rust's GROUP_ENTRIES_IN_RETICHAT_FIELD agrees")
}

// MARK: - Wiring (source)

/// Swift sources of the app and the NSE, with // comments removed.
func appSources() -> [(String, String)] {
    var out: [(String, String)] = []
    for dir in ["Retichat", "NotificationService"] {
        let base = root.appendingPathComponent(dir)
        guard let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let code = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
                guard let r = line.range(of: "//") else { return line }
                return line[..<r.lowerBound]
            }.joined(separator: "\n")
            out.append((url.path.replacingOccurrences(of: root.path + "/", with: ""), code))
        }
    }
    return out
}

func testEveryGroupWriteGoesThroughTheHelper() {
    let manager = source("Retichat/Services/GroupChatManager.swift")
    check(!manager.contains("messageAddField"), "GroupChatManager sets no top-level field itself")
    check(manager.components(separatedBy: "LxmfClient.messageSetGroupEntry(handle, ").count - 1 == 29,
          "GroupChatManager's 29 group entry writes all use messageSetGroupEntry")
    for entry in ["id", "members", "name", "action", "sender", "relaySeen", "relayFor", "relayDone", "memberKeys"] {
        check(manager.contains("messageSetGroupEntry(handle, .\(entry), "), "GroupChatManager writes .\(entry) through the helper")
    }
    let client = source("Retichat/Services/LxmfClient.swift")
    check(client.contains("guard let write = GroupFieldWrite.of(entry, value) else"),
          "messageSetGroupEntry takes its form from GroupFieldWrite.of, which follows the constant")
    check(client.contains("lxmf_message_set_retichat_string(msgHandle, Int32(key), $0)")
          && client.contains("lxmf_message_set_retichat_bool(msgHandle, Int32(key), value ? 1 : 0)"),
          "the Swift wrappers call the C setters")
    let header = source("Retichat/Bridge/CRetichatFFI.h")
    check(header.contains("int32_t lxmf_message_set_retichat_string(uint64_t msg, int32_t key, const char *value);")
          && header.contains("int32_t lxmf_message_set_retichat_bool(uint64_t msg, int32_t key, int32_t value);"),
          "the header declares the setters the wrappers call")

    for (path, code) in appSources() {
        check(!code.contains("LxmfFieldKey.group"), "\(path): no group field constant outside GroupEntry")
        if path.hasSuffix("LxmfClient.swift") || path.hasSuffix("Bridge/LxmfFields.swift") { continue }
        check(!code.contains("legacyField") && !code.contains("GroupFieldWrite"),
              "\(path): nothing but the helper picks a group entry's form")
        check(!code.contains("lxmf_message_set_retichat") && !code.contains("messageSetRetichat"),
              "\(path): nothing but the helper sets a Retichat field entry")
        // An old group field number as a field key (fixstr headers such as
        // `0xa0 | len` elsewhere are msgpack, not field numbers).
        let asKey = try! NSRegularExpression(
            pattern: #"(key:\s*|add_field(_bool)?\([^,]*,\s*)(UInt8\()?0x[aA][0-8]\b"#)
        let range = NSRange(code.startIndex..., in: code)
        check(asKey.firstMatch(in: code, range: range) == nil,
              "\(path): no field key 0xA0-0xA8 written as a literal (the numbers live in GroupEntry)")
    }
}

/// The name is key 0 of the map and only the Rust side decodes it: no Swift
/// code in the app or the NSE reads 0xD1 itself.
func testNothingReadsATopLevelNameInSwift() {
    for (path, code) in appSources() {
        if path.hasSuffix("Bridge/LxmfFields.swift") { continue }
        check(!code.contains("0xD1") && !code.contains("0xd1") && !code.contains("RetichatField.field"),
              "\(path): no code touches field 0xD1 directly")
    }
    let lxmf = source("Retichat/Bridge/LxmfFields.swift")
    check(lxmf.contains("retichatGroup = readRetichatGroupEntries(bytes, &offset)"),
          "the fields decoder reads only group entries out of 0xD1")
    check(!lxmf.contains("displayName = read"), "the fields decoder does not read the name")
    let client = source("Retichat/Services/LxmfClient.swift")
    check(client.contains("lxmf_display_name_decode("), "decodeDisplayName asks the Rust side (key 0 of the map)")
    // A map at 0xD1 with only a name in it: no group entries, fields after it decode.
    let named = Data([0x82, 0xCC, 0xD1, 0x81, 0x00, 0xC4, 0x03, 0x42, 0x6F, 0x62, 0xCC, 0xA0, 0xA1, 0x67])
    let fields = LxmfFieldsDecoder.decode(named)
    check(fields.groupId == "g" && fields.groupEntries.count == 1, "a name-only map is walked, the old 0xA0 after it reads")
}

@main
enum RetichatFieldTests {
    static func main() {
        testTheKeysMatchTheSpecTable()
        testTheDecoderRunsTheSharedVectors()
        testTheTypedFieldsComeFromTheResolvedEntries()
        testTheWalkStaysInStep()
        testTheSendFormsMatchTheEncodeVectors()
        testTheConstantSelectsTheForm()
        testEveryGroupWriteGoesThroughTheHelper()
        testNothingReadsATopLevelNameInSwift()
        if failures.isEmpty {
            print("all Retichat field tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
