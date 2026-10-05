// DisplayNamesTests.swift
//
// Display names on iOS (LXMF-rust/DISPLAY_NAMES.md, agreed 2026-09-27): the
// rules the app applies to the names the Rust side cleans and decodes, the
// settings migration, and the wiring on every path that yields a message,
// every surface that shows a name, and the NSE. Until then iOS read field
// 0x10 only as msgpack str while every native sender wrote bin (audit H2),
// kept one name slot that the first name seen filled for good, froze names
// into system messages, and labelled channel posters and NSE titles by hash.
//
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/display-names \
//     Retichat-ios/Retichat/Bridge/LxmfFields.swift \
//     Retichat-ios/Retichat/Services/UserPreferences.swift \
//     Retichat-ios/Retichat/Services/PendingNotification.swift \
//     Retichat-ios/tests/DisplayNamesTests.swift && \
//     /private/tmp/claude-501/display-names
//
// DisplayNames (in LxmfFields.swift, compiled into the app and the NSE) runs
// for real, and the digest is checked against the vectors the Rust suite
// runs (LXMF-rust/tests/display_name_vectors.json). Cleaning and decoding
// 0xD1 are Rust's and tested there. The wiring needs SwiftData, UIKit and
// the FFI, so it is asserted on the source, like NSEChannelPullTests.swift.

import Foundation
import Combine

// UserPreferences.swift uses the app's Data hex helpers
// (PropagationNodeManager.swift), which need the whole app; the same two here.
extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var out = Data()
        var i = hexString.startIndex
        while i < hexString.endIndex {
            let j = hexString.index(i, offsetBy: 2)
            guard let b = UInt8(hexString[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        self = out
    }
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

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

/// `a` appears, and before `b`.
func before(_ text: String, _ a: String, _ b: String) -> Bool {
    guard let ra = text.range(of: a), let rb = text.range(of: b) else { return false }
    return ra.lowerBound < rb.lowerBound
}

/// The body of `func name` in `text`, up to the next "\n    func " or
/// "\n    private func " at the same depth (enough for these files).
func body(_ text: String, _ signature: String) -> String {
    guard let start = text.range(of: signature) else { return "" }
    let rest = text[start.upperBound...]
    let ends = ["\n    func ", "\n    private func ", "\n    @MainActor func ", "\n    // MARK: -"]
        .compactMap { rest.range(of: $0)?.lowerBound }
    return String(rest[..<(ends.min() ?? rest.endIndex)])
}

let alice = "1a2b3c4d5e6f708192a3b4c5d6e7f801"

// MARK: - Decoding (§2.1, §3)

func testTheNameStateBufferParses() {
    check(DisplayNames.parseNameState(Data([0, 0, 0])) == .absent, "state 0 is absent")
    check(DisplayNames.parseNameState(Data([1, 0, 0])) == .clear, "state 1 is a clear")
    let name = Data("Zoë".utf8)
    check(DisplayNames.parseNameState(Data([2, 0, UInt8(name.count)]) + name) == .name("Zoë"),
          "state 2 carries the UTF-8 name, length u16 big-endian")
    check(DisplayNames.parseNameState(Data([2, 0, 9]) + name) == nil, "a name running past the buffer is malformed")
    check(DisplayNames.parseNameState(Data([2, 0, 0])) == nil, "state 2 without a name is malformed")
    check(DisplayNames.parseNameState(Data([2, 0, 1, 0xFF])) == nil, "a name that is not UTF-8 is malformed")
    check(DisplayNames.parseNameState(Data([7, 0, 0])) == nil, "an unknown state is malformed")
    check(DisplayNames.parseNameState(Data([0, 0])) == nil, "a short buffer is malformed")
}

/// {0x10: bin "Alice", 0xA0: str "g"} as lxmf_message_add_field writes keys.
func testTheRetiredFieldNoLongerStopsTheParse() {
    var map = Data([0x82, 0x10, 0xC4, 0x05]) + Data("Alice".utf8)
    map += Data([0xCC, 0xA0, 0xA1]) + Data("g".utf8)
    let fields = LxmfFieldsDecoder.decode(map)
    check(fields.groupId == "g",
          "a bin value at 0x10 is skipped and the fields after it still decode (audit H2)")
    let lxmf = source("Retichat/Bridge/LxmfFields.swift")
    check(!lxmf.contains("senderName"), "0x10 is neither a field key nor a decoded field any more (§2.1)")
}

// MARK: - Accepting 0xD1 (§5.2)

func testTheAcceptTable() {
    typealias C = DisplayNames.Change
    func accept(_ f: DisplayNames.NameField, _ reason: Int, _ current: String?) -> C {
        DisplayNames.acceptMessageName(f, unverifiedReason: reason, current: current,
                                       currentAt: nil, messageTime: 1_800_000_000)
    }
    check(accept(.name("Alice"), 0, nil) == .set("Alice"), "validated name: set")
    check(accept(.name("Alice"), 0, "Old") == .set("Alice"), "validated name: replaces the one held")
    check(accept(.name("Alice"), 0, "Alice") == .set("Alice"),
          "validated same name: accepted, so its timestamp is recorded (§5.2)")
    check(accept(.clear, 0, "Alice") == .set(nil), "validated clear: messageName = none")
    check(accept(.clear, 0, nil) == .set(nil),
          "validated clear with nothing held: accepted, so its timestamp is recorded")
    check(accept(.name("Alice"), 1, nil) == .fill("Alice"),
          "source unknown: set only if none is held, as a fill that records no timestamp")
    check(accept(.name("Mallory"), 1, "Alice") == .keep, "source unknown: never replaces a name")
    check(accept(.clear, 1, "Alice") == .keep, "source unknown: a clear is ignored")
    check(accept(.name("Mallory"), 2, nil) == .keep, "invalid signature: a name is ignored")
    check(accept(.clear, 2, "Alice") == .keep, "invalid signature: a clear is ignored")
    check(accept(.absent, 0, "Alice") == .keep, "no 0xD1: nothing changes")
    check(accept(.name("X"), 7, nil) == .keep, "an unknown reason counts as invalid")
}

/// §5.2's ordering rule: a 0xD1 counts only from a message newer than
/// messageNameAt, and accepting one records the message's timestamp.
func testTheAcceptOrder() {
    typealias C = DisplayNames.Change
    let t = 1_800_000_000.0
    func accept(_ f: DisplayNames.NameField, _ reason: Int, _ current: String?, at: Double?, _ time: Double) -> C {
        DisplayNames.acceptMessageName(f, unverifiedReason: reason, current: current, currentAt: at, messageTime: time)
    }
    check(accept(.name("Old"), 0, "New", at: t, t - 60) == .keep,
          "an older message's name never replaces a newer one (a propagated copy landing late)")
    check(accept(.clear, 0, "New", at: t, t - 60) == .keep, "nor does an older clear")
    check(accept(.name("Old"), 0, nil, at: t, t - 60) == .keep,
          "nor an older name after a newer clear")
    check(accept(.name("New"), 0, "New", at: t, t) == .keep, "the same timestamp is not newer")
    check(accept(.name("Newer"), 0, "New", at: t, t + 1) == .set("Newer"), "a newer message's name replaces")
    check(accept(.name("Alice"), 0, "Old", at: nil, 0) == .set("Alice"),
          "a name held from before the rule (no timestamp) takes any message")
    check(accept(.name("Alice"), 1, nil, at: t, t - 60) == .keep,
          "an unknown source's first name is ordered too")
    check(accept(.name("Alice"), 1, nil, at: t, t + 60) == .fill("Alice"),
          "and, taken, is a fill: its timestamp is the unverified sender's claim")
    for bad in [Double.nan, .infinity, -.infinity] {
        check(accept(.name("Alice"), 0, nil, at: nil, bad) == .keep,
              "a timestamp that is not finite (\(bad)) cannot be ordered and never counts")
    }
    check(!DisplayNames.isNewer(.nan, than: nil) && DisplayNames.isNewer(t, than: .nan),
          "nor is it newer than anything, and a non-finite held time orders nothing")

    // The app's fold (ChatRepository.applyMessageName) over messages in
    // arrival order: name and messageNameAt after each accepted change. A
    // fill writes the name and leaves messageNameAt.
    func fold(_ arrivals: [(DisplayNames.NameField, Int, Double)]) -> (String?, Double?) {
        var name: String? = nil, at: Double? = nil
        for (f, reason, time) in arrivals {
            switch accept(f, reason, name, at: at, time) {
            case .set(let n): name = n; at = time
            case .fill(let n): name = n
            case .keep: break
            }
        }
        return (name, at)
    }
    let late = fold([(.name("Ann B"), 0, t + 10), (.name("Ann"), 0, t)])
    check(late.0 == "Ann B" && late.1 == t + 10,
          "a direct message's new name survives the propagated copy of an older one arriving after it")
    let repeated = fold([(.name("Ann"), 0, t), (.name("Ann"), 0, t + 20), (.name("Old"), 0, t + 10)])
    check(repeated.0 == "Ann" && repeated.1 == t + 20,
          "a repeat of the current name advances the timestamp, so an older rename between them loses")
    let cleared = fold([(.clear, 0, t + 5), (.name("Ann"), 0, t)])
    check(cleared.0 == nil && cleared.1 == t + 5, "a newer clear holds against an older name")
    // Review ios-order-1: a forged message from a source we hold no key
    // for, dated far ahead, must not pin its name against the real source.
    let forged = fold([(.name("Mallory"), 1, 4e9), (.name("Alice"), 0, t)])
    check(forged.0 == "Alice" && forged.1 == t,
          "a source-unknown name dated far ahead does not hold off the source's validated name")
    let forgedThenClear = fold([(.name("Mallory"), 1, 4e9), (.clear, 0, t)])
    check(forgedThenClear.0 == nil && forgedThenClear.1 == t, "nor its validated clear")
    let unknownFirst = fold([(.name("Ann"), 1, t + 5), (.name("Old"), 0, t)])
    check(unknownFirst.0 == "Old" && unknownFirst.1 == t,
          "a validated name replaces a source-unknown fill whatever their dates (§5.2's table)")
    let fillAfterClear = fold([(.clear, 0, t), (.name("Ann"), 1, t - 5), (.name("Ann"), 1, t + 5)])
    check(fillAfterClear.0 == "Ann" && fillAfterClear.1 == t,
          "a fill is still ordered against the last validated change, and does not move its time")
}

// MARK: - Resolving (§5.3)

func testTheResolver() {
    check(DisplayNames.shortHash("1A2B3C4D5E6F") == "1a2b3c4d\u{2026}", "shortHash: 8 hex and an ellipsis, lowercase")
    check(DisplayNames.contactLabel(hash: alice, local: "Mum", message: "Alice", announce: "A.") == "Mum",
          "localName first")
    check(DisplayNames.contactLabel(hash: alice, local: nil, message: "Alice", announce: "A.") == "Alice",
          "then messageName")
    check(DisplayNames.contactLabel(hash: alice, local: "", message: nil, announce: "A.") == "A.",
          "then announceName; an empty slot is no name")
    check(DisplayNames.contactLabel(hash: alice, local: nil, message: nil, announce: nil) == "1a2b3c4d\u{2026}",
          "then the short hash")
    check(DisplayNames.contactName(local: nil, message: nil, announce: nil) == nil, "no slot, no name")

    // The channel resolver (§5.3, James 2026-09-27): a local name leads and
    // the channel name goes to the grey spot; a channel name alone has the
    // short hash beside it; no channel name, the contact resolver, alone.
    typealias SN = DisplayNames.SharedName
    let fromChannel = DisplayNames.channelLabel(hash: alice, channelName: "Wizard",
                                                contact: SN(name: "Alice", slot: .message))
    check(fromChannel == .init(label: "Wizard", secondary: .shortHash("1a2b3c4d\u{2026}")),
          "a channelName, no localName: the channel name, with the standard short hash beside it")
    check(fromChannel.secondary == "1a2b3c4d\u{2026}" && fromChannel.secondaryIsHash,
          "that secondary text is the hash, set in monospace")
    let localFirst = DisplayNames.channelLabel(hash: alice, channelName: "Wizard",
                                               contact: SN(name: "Mum", slot: .local))
    check(localFirst == .init(label: "Mum", secondary: .channelName("Wizard")),
          "a channelName and a localName: the local name leads, the channel name is the secondary text")
    check(localFirst.secondary == "Wizard" && !localFirst.secondaryIsHash,
          "that secondary text is the channel name, not a hash")
    for slot in [DisplayNames.NameSlot.message, .announce, .legacy] {
        check(DisplayNames.channelLabel(hash: alice, channelName: "Wizard", contact: SN(name: "Alice", slot: slot))
                == .init(label: "Wizard", secondary: .shortHash("1a2b3c4d\u{2026}")),
              "only a local-slot name leads a channel name, not a \(slot.rawValue) one")
    }
    check(DisplayNames.channelLabel(hash: alice, channelName: "Wizard", contact: SN(name: "", slot: .local))
            == .init(label: "Wizard", secondary: .shortHash("1a2b3c4d\u{2026}")),
          "an empty local name is no local name")
    check(DisplayNames.channelLabel(hash: alice, channelName: "Wizard", contact: nil)
            == .init(label: "Wizard", secondary: .shortHash("1a2b3c4d\u{2026}")),
          "a channel name from a stranger has the hash beside it")
    check(DisplayNames.channelLabel(hash: alice, channelName: nil, contact: SN(name: "Alice", slot: .message))
            == .init(label: "Alice", secondary: nil), "no channelName: the contact's name, no secondary")
    check(DisplayNames.channelLabel(hash: alice, channelName: nil, contact: SN(name: "Mum", slot: .local))
            == .init(label: "Mum", secondary: nil), "a local name alone has no secondary either")
    check(DisplayNames.channelLabel(hash: alice, channelName: "", contact: nil)
            == .init(label: "1a2b3c4d\u{2026}", secondary: nil), "then the short hash, alone")
    check(DisplayNames.channelNotificationTitle(channelName: "public.general", label: fromChannel)
            == "#public.general (Wizard \u{00B7} 1a2b3c4d\u{2026})", "a channel-name notification shows the hash too")
    check(DisplayNames.channelNotificationTitle(channelName: "public.general", label: localFirst)
            == "#public.general (Mum \u{00B7} Wizard)",
          "a notification names the poster by the main label: the local name, then the channel name")
    check(DisplayNames.channelNotificationTitle(channelName: "public.general",
                                                label: .init(label: "Alice", secondary: nil))
            == "#public.general (Alice)", "a contact-named one has no secondary")

    // The NSE's channel title (review ios-order-2): §5.2's ordering per
    // (channel, sender), against the app's shared channelNameAtMs.
    typealias SC = DisplayNames.SharedChannelName
    let ms = 1_800_000_000_000.0
    let old = SC(name: "Old", atMs: ms)
    check(DisplayNames.channelName(afterPost: .name("New"), postMs: ms + 1, stored: old) == "New",
          "a newer post's name replaces")
    check(DisplayNames.channelName(afterPost: .clear, postMs: ms + 1, stored: old) == nil, "a newer post's clear clears")
    check(DisplayNames.channelName(afterPost: .absent, postMs: ms + 1, stored: old) == "Old",
          "a post without 0xD1 keeps it")
    check(DisplayNames.channelName(afterPost: .name("Older"), postMs: ms - 1, stored: old) == "Old",
          "an older post (uploaded late) does not rename its sender in the title, as the app keeps the newer name")
    check(DisplayNames.channelName(afterPost: .clear, postMs: ms - 1, stored: old) == "Old", "nor clear it")
    check(DisplayNames.channelName(afterPost: .name("Same"), postMs: ms, stored: old) == "Old",
          "the same post time is not newer")
    check(DisplayNames.channelName(afterPost: .name("Older"), postMs: ms - 1, stored: SC(name: nil, atMs: ms)) == nil,
          "a newer clear holds against an older post's name")
    check(DisplayNames.channelName(afterPost: .name("New"), postMs: 0, stored: SC(name: "Old")) == "New",
          "a name with no time (an older app's file) takes any post")
    check(DisplayNames.channelName(afterPost: .name("New"), postMs: ms, stored: nil) == "New",
          "nothing stored takes the post's name")

    let token = DisplayNames.subjectToken
    for id in ["inv_0123456789abcdef", "acc_01234567_89abcdef", "left_" + alice] {
        check(DisplayNames.systemText("\(token) joined the group", messageId: id, subject: "Alice") == "Alice joined the group",
              "a system message (\(id.prefix(4))) is named when shown")
    }
    check(DisplayNames.systemText("hello", messageId: "inv_0123", subject: "Alice") == "hello", "other text is untouched")
    // Review IOS-DN-2: iOS keeps U+FFFC where an attachment was in text
    // copied from Notes or Mail, so a received message can hold the token.
    check(DisplayNames.systemText("see \(token) below", messageId: alice, subject: "Alice") == "see \(token) below",
          "a message's own U+FFFC is never replaced by its sender's name")
    check(DisplayNames.systemText("Group invite from \(token): \"a\(token)b\"", messageId: "inv_0123", subject: "Alice")
            == "Group invite from Alice: \"a\(token)b\"",
          "only the subject's token is named, not one in the inviter's group name")
    check(!DisplayNames.isSystemMessageId(alice) && !DisplayNames.isSystemMessageId(""),
          "a message hash is never a system message id")
}

func testTheNotificationServiceTitle() {
    typealias S = DisplayNames.SharedName
    let t = 1_800_000_000.0
    func title(app: S?, _ field: DisplayNames.NameField, _ reason: Int, time: Double = t, announce: String?) -> String {
        DisplayNames.notificationName(hash: alice, appName: app, messageName: field,
                                      unverifiedReason: reason, messageTime: time, announceName: announce)
    }
    let local = S(name: "Mum", slot: .local)
    check(title(app: local, .name("Alice"), 0, announce: "A.") == "Mum", "the user's localName always wins")
    check(title(app: nil, .name("Alice"), 0, announce: "A.") == "Alice", "then the message's validated name")
    check(title(app: nil, .name("Alice"), 1, announce: nil) == "Alice", "a first name from an unknown source")
    check(title(app: nil, .name("Mallory"), 2, announce: "A.") == "A.", "never an invalid message's name")
    check(title(app: nil, .absent, 0, announce: nil) == "1a2b3c4d\u{2026}", "then the short hash")

    // Consistency item 11: a newer 0xD1 beats an app name that is not the
    // user's own, as the app will once it imports the message.
    let heldMessage = S(name: "Ann", slot: .message, messageNameAt: t - 60)
    check(title(app: heldMessage, .name("Ann B"), 0, announce: nil) == "Ann B",
          "a validated name beats the app's older message name")
    check(title(app: S(name: "A.", slot: .announce), .name("Ann"), 0, announce: nil) == "Ann",
          "and the app's announce name")
    check(title(app: S(name: "A.", slot: .announce), .name("Ann"), 1, announce: nil) == "Ann",
          "a source-unknown name beats an announce name (the app holds no messageName)")
    check(title(app: heldMessage, .name("Mallory"), 1, announce: nil) == "Ann",
          "but not the app's message name: an unknown source never replaces one")
    check(title(app: heldMessage, .name("Old"), 0, time: t - 120, announce: nil) == "Ann",
          "nor does a message older than the app's messageNameAt")
    check(title(app: heldMessage, .name("Mallory"), 2, announce: nil) == "Ann", "nor an invalid one")
    check(title(app: heldMessage, .clear, 0, announce: "A.") == "A.",
          "a validated clear drops the app's message name, down to the announce name")
    check(title(app: heldMessage, .absent, 0, announce: "A.") == "Ann", "no 0xD1: the app's name stands")
    check(title(app: S(name: "A.", slot: .announce), .absent, 0, announce: "Stale") == "A.",
          "the app's announce name before the recalled one")
    check(title(app: S(name: "Mum", slot: .legacy), .name("Ann"), 0, announce: nil) == "Mum",
          "a name of unknown origin (an old chat_names.json) keeps winning: it may have been typed")
}

/// chat_names.json records each name's slot; old files (hash → name) read.
func testTheChatNamesFile() {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("chat-names-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    typealias S = DisplayNames.SharedName
    let names = ["a": S(name: "Mum", slot: .local), "b": S(name: "Ann", slot: .message, messageNameAt: 1_800_000_000.5),
                 "c": S(name: "A.", slot: .announce)]
    check(PendingNotification.writeChatNames(names, in: dir) && PendingNotification.readChatNames(in: dir) == names,
          "the NSE reads back each name with its slot and messageNameAt")
    let old = try? JSONEncoder().encode(["a": "Mum", "b": "Ann"])
    try? old?.write(to: dir.appendingPathComponent("chat_names.json"))
    check(PendingNotification.readChatNames(in: dir) == ["a": S(name: "Mum", slot: .legacy), "b": S(name: "Ann", slot: .legacy)],
          "a file from an older build (bare names) still reads, each name as legacy")
    check(PendingNotification.writeChatNames(names, in: dir), "rewritten")
    let written = String(decoding: (try? Data(contentsOf: dir.appendingPathComponent("chat_names.json"))) ?? Data(), as: UTF8.self)
    check(written.contains("\"slot\":\"local\"") && written.contains("\"name\":\"Mum\""),
          "entries are objects with name and slot", written)
    check(DisplayNames.contactNameAndSlot(local: nil, message: "Ann", announce: "A.")! == ("Ann", .message),
          "the slot is the resolver's")
    check(DisplayNames.contactNameAndSlot(local: "", message: nil, announce: "A.")! == ("A.", .announce),
          "an empty slot is skipped")
}

/// channel_sender_names.json carries each sender's post time, cleared
/// names included (review ios-order-2); old files (bare names) read.
func testTheChannelSenderNamesFile() {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("channel-names-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    typealias SC = DisplayNames.SharedChannelName
    let names = ["chan": ["a": SC(name: "Wizard", atMs: 1_800_000_000_123), "b": SC(name: nil, atMs: 1_800_000_000_456)]]
    check(PendingNotification.writeChannelSenderNames(names, in: dir)
            && PendingNotification.readChannelSenderNames(in: dir) == names,
          "the NSE reads back each sender's name and post time, a clear included")
    let old = try? JSONEncoder().encode(["chan": ["a": "Wizard"]])
    try? old?.write(to: dir.appendingPathComponent("channel_sender_names.json"))
    check(PendingNotification.readChannelSenderNames(in: dir) == ["chan": ["a": SC(name: "Wizard")]],
          "a file from an older build (bare names) still reads, with no time")

    let client = source("Retichat/Services/RfedChannelClient.swift")
    let note = body(client, "private func noteSender(")
    check(note.contains("sharedSenderNames[channel, default: [:]][sender] =\n            DisplayNames.SharedChannelName(name: newName, atMs: postMs)\n        shareSenderNames()")
            && before(note, "guard DisplayNames.isNewer(", "sharedSenderNames[channel"),
          "every accepted post updates the NSE's copy with its time, also when only the time moved")
    check(body(client, "private func shareSenderNames(").contains("let snapshot = sharedSenderNames"),
          "the NSE gets the names with their times")
    check(body(client, "private func loadSenderNames(").contains("if row.channelName != nil || row.channelNameAtMs != nil {"),
          "a cleared name is shared too, so its time holds off older posts")
}

// MARK: - Channel posts (§4.2)

func testTheChannelRule() {
    let day = DisplayNames.channelNameRefreshSecs
    let now = 1_800_000_000.0
    let d = DisplayNames.digest("Alice")
    func post(_ name: String?, _ last: Data?, _ at: Double?, newSender: Bool = false, now t: Double = now)
        -> DisplayNames.NameField {
        DisplayNames.channelPostName(current: name, lastDigest: last, lastIncludedAt: at,
                                     newSenderSinceIncluded: newSender, now: t)
    }
    check(day == 86_400, "CHANNEL_NAME_REFRESH_SECS is 24 hours")
    check(post("Alice", nil, nil) == .name("Alice"), "the first post carries the name")
    check(post("Alice", DisplayNames.digest("Old"), now - 10) == .name("Alice"), "a changed name goes out")
    check(post("Alice", d, now - 10) == .absent, "an unchanged name recently sent stays out")
    check(post("Alice", d, now - 10, newSender: true) == .name("Alice"), "a new sender since brings it back")
    check(post("Alice", d, now - day) == .absent, "exactly 24 hours is not more than 24 hours")
    check(post("Alice", d, now - day - 1) == .name("Alice"), "after 24 hours it is refreshed")
    check(post(nil, d, now - 10) == .clear, "unset after a real name: clear once")
    check(post(nil, DisplayNames.digest(nil), now - 10) == .absent, "and only once")
    check(post(nil, nil, nil) == .absent, "never named: nothing")
    check(post("", d, now - 10) == .clear, "an empty name is unset")
}

func testTheDigestMatchesTheRustVectors() {
    let url = workspace.appendingPathComponent("LXMF-rust/tests/display_name_vectors.json")
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let vectors = json["digest"] as? [[String: Any]], !vectors.isEmpty else {
        check(false, "the shared vectors load", url.path)
        return
    }
    for v in vectors {
        guard let input = v["input"] as? String, let hex = v["digest_hex"] as? String else { continue }
        let got = DisplayNames.digest(input.isEmpty ? nil : input).hexString
        check(got == hex, "digest \(v["name"] ?? "?") matches lxmf_rust::display_name::digest", got)
    }
}

// MARK: - Distro unwrap

func testTheDistroUnwrapKeys() {
    check(DisplayNames.distroNameField(state: 2, name: "Alice") == .name("Alice"), "state 2 is the name")
    check(DisplayNames.distroNameField(state: 1, name: nil) == .clear, "state 1 is a clear")
    check(DisplayNames.distroNameField(state: 0, name: "x") == .absent, "state 0 is absent")
    check(DisplayNames.distroNameField(state: nil, name: nil) == .absent, "an older FFI (no keys) names nobody")
    check(DisplayNames.distroNameField(state: 2, name: nil) == .absent, "state 2 without a name is absent")
    check(DisplayNames.distroReason(validated: true, unverifiedReason: 1) == 0, "validated is reason 0")
    check(DisplayNames.distroReason(validated: false, unverifiedReason: 1) == 1, "source unknown kept")
    check(DisplayNames.distroReason(validated: false, unverifiedReason: nil) == 2,
          "not validated without a reason is invalid")
    check(DisplayNames.distroReason(validated: nil, unverifiedReason: nil) == 2, "no keys at all is invalid")
}

// MARK: - Migration (§5.4)

func testTheContactMigration() {
    func m(_ v: String, recalled: String? = nil) -> DisplayNames.LegacyName {
        DisplayNames.migrateLegacyName(v, hash: alice, recalledAnnounceName: recalled)
    }
    // §5.4's list: hash forms of the contact's own hash (8 to 32 hex, with or
    // without "?" or "…"), "Retichat", "Retichat Web", "Anonymous Peer", any case.
    check(m("1a2b3c4d\u{2026}") == .drop, "the 8-hex placeholder is dropped")
    check(m("1a2b3c4d5e6f7081\u{2026}") == .drop, "the 16-hex picker placeholder is dropped")
    check(m("1A2B3C4D") == .drop, "8 hex, any case, no ellipsis")
    check(m(alice) == .drop && m(alice.uppercased() + "\u{2026}") == .drop, "the whole hash, 32 hex")
    check(m("?" + alice) == .drop && m("?1a2b3c4d") == .drop, "the web's ?hash form")
    check(m("deadbeef") == .localName("deadbeef") && m("20260927") == .localName("20260927")
            && m("?deadbeef") == .localName("?deadbeef"),
          "hex that is not the contact's own hash may have been typed: kept")
    check(m("   ") == .drop, "an empty name is dropped")
    for placeholder in ["Retichat", "RETICHAT", "Retichat Web", "retichat web", "Anonymous Peer", "anonymous PEER"] {
        check(m(placeholder) == .drop, "the app placeholder \"\(placeholder)\" is dropped")
    }
    check(m("1a2b3c4") == .localName("1a2b3c4"), "7 hex is not a hash form")
    check(m(alice + "0") == .localName(alice + "0"), "33 hex is not a hash form")
    check(m("1A2B3C4D...") == .localName("1A2B3C4D..."), "three dots are not in the list")
    check(m("??1a2b3c4d") == .localName("??1a2b3c4d") && m("1a2b3c4d\u{2026}\u{2026}") == .localName("1a2b3c4d\u{2026}\u{2026}"),
          "one \"?\" and one \"…\" at most")
    check(m("Retichat Fan") == .localName("Retichat Fan") && m("Anonymous") == .localName("Anonymous"),
          "only the exact placeholder names")
    check(m("Alice", recalled: "Alice") == .announceName("Alice"), "equal to the recalled announce name")
    check(m("Mum", recalled: "Alice") == .localName("Mum"), "anything else was typed: localName")
    check(m("Cafe", recalled: nil) == .localName("Cafe"), "no recalled name: localName")
}

func testTheContactMigrationWiring() {
    let repo = source("Retichat/Services/ChatRepository.swift")
    let migrate = body(repo, "private func migrateLegacyContactNamesIfNeeded(")
    check(migrate.contains("guard !prefs.contactNamesMigrated") && migrate.contains("self.prefs.contactNamesMigrated = true"),
          "the contact migration runs once, guarded by a persisted flag")
    check(before(migrate, "ffiQueue.async", "client.recallDisplayName(for: data)"),
          "its announce-name recalls run off the main thread")
    check(migrate.contains("if contact.localName == nil { contact.localName = name")
            && migrate.contains("if contact.announceName == nil { contact.announceName = name"),
          "a slot filled since is never overwritten")
    check(migrate.contains("LxmfClient.cleanDisplayName(value)"), "old names are cleaned as saved names are")
    check(body(repo, "private func finishStartService(").contains("migrateLegacyContactNamesIfNeeded(client: client)"),
          "it runs when the stack is up (the recall needs it)")
    check(body(repo, "private func sharedName(").contains("if !prefs.contactNamesMigrated, !DisplayNames.isPlaceholder(c.displayName, ownHash: c.destHash)"),
          "until then an old non-placeholder name is still shown")
}

func testTheSettingsMigration() {
    let suite = "display-names-test-\(UUID().uuidString)"
    guard let d = UserDefaults(suiteName: suite) else { check(false, "a scratch defaults suite"); return }
    defer { d.removePersistentDomain(forName: suite) }
    d.set("Alice", forKey: "display_name")
    d.set("Chan", forKey: "channel_display_name")
    UserPreferences.migrateDisplayName(d)
    check(d.string(forKey: "message_display_name") == "Alice", "the old display name becomes the Message Display Name")
    check(d.string(forKey: "display_name") == nil, "the old key is gone, so it runs once")
    check(d.string(forKey: "announce_display_name") == nil, "the Announce Display Name starts empty")
    check(d.string(forKey: "channel_display_name") == "Chan", "the channel name stays")
    d.set("Later", forKey: "display_name")
    UserPreferences.migrateDisplayName(d)
    check(d.string(forKey: "message_display_name") == "Alice", "a message name already set is never overwritten")
}

// MARK: - Wiring (source)

func testTheReceivePaths() {
    let repo = source("Retichat/Services/ChatRepository.swift")
    let incoming = body(repo, "private func handleIncomingMessage(")
    check(before(incoming, "if let key = fields.distroTransferKey", "LxmfClient.decodeDisplayName(fieldsRaw: fieldsRaw)"),
          "transfers and sent copies are dropped before any name is read")
    check(before(incoming, "guard let standing = admitGroupMessage(", "applyMessageName(nameField, unverifiedReason: unverifiedReason, sourceHex: srcHex,\n                             messageTime: timestamp)\n            handleGroupMessage("),
          "a group message's 0xD1 names its LXMF source, only when the group policy accepts it (audit H11), ordered by its timestamp")
    check(before(incoming, "guard allowlist.isAllowed else", "applyMessageName(nameField, unverifiedReason: unverifiedReason, sourceHex: srcHex,\n                         messageTime: timestamp)\n        storeIncomingDirect("),
          "a DM's 0xD1 is applied after the allowlist and before the bubble and notification, ordered by its timestamp")
    let nse = body(repo, "func importNSEMessages()")
    check(nse.contains("let reason = msg.unverifiedReason ?? (msg.signatureValid ? 0 : 2)"),
          "the NSE import decides on the stored reason; older files count as invalid")
    check(nse.components(separatedBy: "applyMessageName(nameField, unverifiedReason: reason, sourceHex: srcHex,").count == 3
            && nse.components(separatedBy: "messageTime: msg.timestamp)").count == 3,
          "NSE-imported group messages and DMs both apply the name (audit M4), ordered by their timestamps")
    check(before(nse, "guard allowlist.isAllowed else", "applyMessageName(nameField, unverifiedReason: reason, sourceHex: srcHex,\n                             messageTime: msg.timestamp)\n            // As for"),
          "an NSE-imported DM applies it only past the allowlist")
    let distro = body(repo, "private func handleDistroMessage(")
    check(distro.contains("applyMessageName(m.displayName, unverifiedReason: m.unverifiedReason, sourceHex: srcHex,\n                         messageTime: m.timestamp)")
            && distro.contains("signatureValid: m.unverifiedReason == 0"),
          "distro messages carry their name, signature result (audit H7) and timestamp")
    check(repo.components(separatedBy: "applyMessageName(").count == 7,
          "those five calls are every accept path (and the definition)")
    let apply = body(repo, "private func applyMessageName(")
    check(apply.contains("DisplayNames.acceptMessageName(field, unverifiedReason: unverifiedReason")
            && apply.contains("contact.messageName = name") && !apply.contains("localName"),
          "0xD1 writes messageName only, by the §5.2 table")
    check(apply.contains("currentAt: existing?.messageNameAt,") && apply.contains("messageTime: messageTime)")
            && apply.contains("if case .set = change { contact.messageNameAt = messageTime }")
            && apply.contains("case .fill(let n): name = n"),
          "the stored messageNameAt orders it, and an accepted 0xD1 records its message's timestamp (§5.2)")
    check(source("Retichat/Models/Models.swift").contains("    var messageName: String?\n")
            && source("Retichat/Models/Models.swift").contains("    var messageNameAt: Double?\n"),
          "ContactEntity.messageNameAt is optional, so SwiftData migrates lightly")
    check(apply.contains("!isOwnAddress(sourceHex)"), "this device's own addresses are never named from a message")
    let announce = body(repo, "private func handleAnnounce(")
    check(announce.contains("contact.announceName = announceName") && !announce.contains("localName")
            && !announce.contains("messageName"),
          "an announce replaces announceName (none when it has none) and nothing else")
    check(!repo.contains("updateContactNameIfEmpty"), "no first-name-wins-forever write is left (audit M5)")

    let distroClient = source("Retichat/Services/RfedDistroClient.swift")
    check(distroClient.contains("let display_name_state: Int?") && distroClient.contains("let unverified_reason: Int?")
            && distroClient.contains("displayName: parsed.nameField,"),
          "the distro unwrap's new JSON keys reach the message")
    let nsePull = source("NotificationService/NSEDistroPull.swift")
    check(nsePull.contains("let display_name_state: Int?") && nsePull.contains("DisplayNames.distroReason("),
          "the NSE's distro unwrap reads them too")

    let bridge = source("Retichat/Bridge/RetichatBridge.swift")
    check(bridge.contains("    signatureValid: Int32,\n    unverifiedReason: Int32,\n    fieldsRaw:"),
          "the app's delivery trampoline takes unverified_reason after signature_valid (CRetichatFFI.h)")
    let service = source("NotificationService/NotificationService.swift")
    check(service.contains("    signatureValid: Int32,\n    unverifiedReason: Int32,\n    fieldsRaw:")
            && service.contains("unverifiedReason: Int(unverifiedReason)"),
          "the NSE's does too, and stores it for the app")
}

func testTheSurfaces() {
    let repo = source("Retichat/Services/ChatRepository.swift")
    check(!repo.contains("contactDisplayName(for: srcHex)): \\\"")
            && repo.contains("content: \"Group invite from \\(DisplayNames.subjectToken): ")
            && repo.contains("content: accepted ? \"\\(DisplayNames.subjectToken) joined the group\"")
            && repo.contains(": \"\\(DisplayNames.subjectToken) left the group\","),
          "system messages store the subject's hash (senderHash) and a token, never a name (audit L2)")
    check(repo.contains("let inviteMsgId = \"inv_\\(groupId.prefix(16))\"")
            && repo.contains("let sysId = accepted ? \"acc_\\(memberHex.prefix(8))_\\(groupId.prefix(8))\" : leaveMsgId")
            && repo.contains("leaveMsgId: \"left_\" + hash.hexString"),
          "each system message's id has a DisplayNames.systemMessageIdPrefixes prefix (review IOS-DN-2)")
    let messages = body(repo, "func messages(forChatId chatId: String")
    check(messages.contains("content: DisplayNames.systemText(entity.content, messageId: entity.id, subject: senderName)"),
          "bubbles name the subject when shown, system messages only")
    let refresh = body(repo, "func refreshChats()")
    check(refresh.contains("shownText($0.content, id: $0.id, senderHash: $0.senderHash, names: names)")
            && refresh.contains("previewByChat[m.chatId] = (m.id, m.content, m.senderHash)"),
          "so does the chat-list preview, by the message's id")
    check(refresh.contains("let entries = contactNameEntries()") && refresh.contains("let snapshot = entries")
            && !refresh.contains("chatNameMap[chat.peerHash]"),
          "chat_names.json holds every named contact's resolved name, keyed by contact, never a placeholder (audit M3)")
    check(body(repo, "private func sharedName(").contains("DisplayNames.SharedName(name: resolved.name, slot: resolved.slot,")
            && body(repo, "private func sharedName(").contains("messageNameAt: c.messageNameAt"),
          "with the slot the name came from and messageNameAt, for the NSE")
    let contacts = body(repo, "func contacts() -> [Contact]")
    check(contacts.contains("!groupIds.contains($0.destHash)") && contacts.contains("!isOwnAddress($0.destHash)"),
          "the pickers never list a group id or this device (audit L4)")
    let create = body(repo, "func createGroupChat(")
    check(!create.contains("ensureAllowlistedContact(destHash: groupId)")
            && create.contains("guard memberHash != ownHashHex else { continue }"),
          "creating a group makes no contact for its id or for this device")
    check(!body(repo, "func acceptGroupInvite(").contains("ensureAllowlistedContact(destHash: groupId)"),
          "nor does accepting one")
    check(body(repo, "func createDirectChat(").contains("refreshAnnounceNameFromCache(destHash: normalizedHash)"),
          "a new chat takes the announce name already cached (audit M10)")
    let local = body(repo, "func setLocalName(")
    check(local.contains("contact.localName = LxmfClient.cleanDisplayName(name)"),
          "a local name is saved cleaned; empty cleans to none, which clears it")

    let view = source("Retichat/Views/Conversation/ConversationView.swift")
    check(view.contains("case .dm:              return repository.chats.first(where: { $0.id == chatId })?.displayName"),
          "the header follows the chat list's resolved name, not a copy taken on appear (audit L3)")
    check(view.contains(".onReceive(repository.$namesVersion) { version in")
            && view.contains("viewModel.refreshMessages(chatId: id, repository: repository, namesVersion: version)"),
          "an open chat reloads its bubbles on a name change, with the version it was sent (review IOS-DN-3)")
    check(source("Retichat/Views/Conversation/ConversationViewModel.swift").contains(
            "let currentNames = sent ?? repository.namesVersion"),
          "which the refresh compares, not the repository's, still the old one in willSet")
    check(source("Retichat/Views/Conversation/ConversationViewModel.swift").contains(
            "let changed = namesChanged || page.count != messages.count"),
          "and the 3 s refresh does too")
    check(view.contains("renameText = isGroup ? title : (slots?.local ?? \"\")")
            && view.contains("repository.setLocalName(destHash: peerHash, name: trimmed)")
            && !view.contains("guard !trimmed.isEmpty else { return }\n        if isGroup"),
          "the rename field holds only the local name, and saving it empty clears it (audit M5)")
    check(view.contains("channelClient.senderLabel(\n                            channelHashHex: channel.id, senderHashHex: msg.senderHash,")
            && view.contains("senderSecondary: label?.secondary,")
            && view.contains("senderSecondaryIsHash: label?.secondaryIsHash ?? false,"),
          "channel bubbles use the channel resolver, with its secondary text and its kind (audit H10)")
    check(view.contains("contact: repository.contactSharedName(for: msg.senderHash))"),
          "with the contact's name and slot, so a local name leads a channel name (§5.3)")
    let bubble = source("Retichat/Views/Components/GlassComponents.swift")
    check(bubble.contains("if let secondary = message.senderSecondary {"),
          "the bubble shows the secondary text, hash or channel name")
    check(bubble.contains(".font(message.senderSecondaryIsHash\n                                      ? .system(.caption2, design: .monospaced) : .caption2)"),
          "a hash in monospace, a channel name in the plain caption font")
    let channelClient = source("Retichat/Services/RfedChannelClient.swift")
    check(channelClient.contains("contact: contactEntry?(senderHashHex))")
            && source("Retichat/RetichatApp.swift").contains("repo?.contactSharedName(for: hash)"),
          "app channel notifications get the contact's slot too, so they use the same main label")
    check(source("NotificationService/NotificationService.swift").contains("contact: chatNames[shown.senderHash])"),
          "NSE channel titles pass the chat_names.json entry, whose slot says whether it is a local name")
    for picker in ["NewChat/NewChatView.swift", "NewChat/NewGroupView.swift", "NewChat/NewConversationView.swift"] {
        check(!source("Retichat/Views/" + picker).contains("prefix(16)"),
              "\(picker) shows the resolved name, not a 16-hex placeholder")
    }

    let service = source("NotificationService/NotificationService.swift")
    check(service.contains("DisplayNames.notificationName(") && !service.contains("senderName = msg.title"),
          "NSE titles use the resolver order and never the LXMF title (audit M3)")
    check(service.contains("messageTime: timestamp,") && service.contains("reason,\n                                            m.timestamp)))")
            && service.contains("$0.unverifiedReason, $0.timestamp))"),
          "each NSE title is decided with its message's timestamp, from the sync and the distro pull")
    check(service.contains("PendingNotification.readChannelSenderNames()[channelPull.channelHex]"),
          "NSE channel titles know the stored channel names")
    check(service.contains("DisplayNames.channelName(afterPost: shown.displayName, postMs: shown.timestampMs,")
            && source("NotificationService/NSEChannelPull.swift").contains("timestampMs: Double(message.timestampMs),"),
          "and order the post against them by its time in ms, as the app's channelNameAtMs")
}

func testTheChannelSend() {
    let client = source("Retichat/Services/RfedChannelClient.swift")
    let rule = body(client, "private func channelPostName(for channel: Channel)")
    check(rule.contains("LxmfClient.cleanDisplayName(prefs.channelDisplayName)") && !rule.contains("messageDisplayName"),
          "posts carry the Channel Display Name only, never the Message Display Name (§1)")
    let send = body(client, "private func trySend(")
    check(before(send, "let postName = channelPostName(for: channel)", "displayName: postName)"),
          "the pack gets the §4.2 decision")
    check(before(send, "let ok = await ConnectionStateManager.shared.appLinkSendData(", "recordPostName(postName, channelHashHex: channel.id)")
            && before(send, "if !ok {", "recordPostName(postName"),
          "the name is recorded only after RFed took the post")
    let note = body(client, "private func noteSender(")
    check(note.contains("guard DisplayNames.isNewer(postMs, than: row.channelNameAtMs) else {")
            && before(note, "guard DisplayNames.isNewer(", "row.channelNameAtMs = postMs"),
          "an older post pulled later does not undo a newer name; the same ordering rule as messages (§5.2)")
    check(DisplayNames.isNewer(2, than: 1) && !DisplayNames.isNewer(1, than: 1) && !DisplayNames.isNewer(0, than: 1)
            && DisplayNames.isNewer(0, than: nil), "newer means strictly later; nothing held takes anything")
    check(body(client, "private func dispatchVerifiedLxmf(").contains("if !isOutgoing {\n            noteSender("),
          "only other senders' verified posts are noted")
    check(source("Retichat/Models/Models.swift").contains("var nameLastDigestHex: String?")
            && source("Retichat/RetichatApp.swift").contains("ChannelSenderEntity.self"),
          "the channel state is persisted (§4.2)")
}

func testTheSettings() {
    let settings = source("Retichat/Views/Settings/SettingsView.swift")
    for hint in ["Public. Sent in your announces to the whole network, including other Reticulum apps. Leave empty to stay anonymous.",
                 "Sent inside your messages, only to the people you message.",
                 "Shown on your channel posts. Anyone who can read a channel can see it. Leave empty to post without a name."] {
        check(settings.contains(hint), "Settings shows the §6 text: \(hint.prefix(30))…")
    }
    check(!settings.contains("If blank, uses your Display Name"), "the channel name no longer claims a fallback (audit H9)")
    check(settings.contains("guard needsRestart, repository.serviceRunning else { return }")
            && settings.contains("repository.applyDisplayNames(announceChanged: announceChanged)"),
          "names apply through the setters; only settings read at start restart the stack (audit M7)")
    let vm = source("Retichat/Views/Settings/SettingsViewModel.swift")
    let restart = body(vm, "var needsRestart: Bool")
    check(!restart.contains("DisplayName"), "no name is a restart setting")
    check(vm.contains("announceDisplayName = LxmfClient.cleanDisplayName(announceDisplayName, announce: true) ?? \"\"")
            && vm.contains("messageDisplayName = LxmfClient.cleanDisplayName(messageDisplayName) ?? \"\""),
          "names are saved cleaned, as the router cleans them")
    let repo = source("Retichat/Services/ChatRepository.swift")
    let finish = body(repo, "private func finishStartService(")
    check(before(finish, "self.lxmfClient = client", "applyDisplayNames(announceChanged: false)")
            && before(finish, "applyDisplayNames(announceChanged: false)", "_ = publishClient.publish(refreshSecs: 30 * 60)"),
          "the names are set on the stack's queue before the first announce")
    let apply = body(repo, "func applyDisplayNames(")
    check(before(apply, "ffiQueue.async {", "client.setAnnounceDisplayName(announce)"),
          "the setters run on ffiQueue, in order with the publish, never on the main thread")
    check(before(apply, "PendingNotification.writeAnnounceDisplayName(announce)", "guard let client = running else { return }"),
          "the Announce Display Name is shared with the NSE, stack or not (review IOS-DN-1)")
    let start = body(repo, "private func continueStartService(")
    check(before(start, "let result = Result { try LxmfClient.start(config: config) }", "!client.setAnnounceDisplayName(announceName)")
            && before(start, "!client.setAnnounceDisplayName(announceName)", "cont.resume(returning: result)"),
          "the app sets it in the start's own ffiQueue turn: path responses carry it from registration on")
    let service = source("NotificationService/NotificationService.swift")
    let nseStart = body(service, "private func startStack()")
    check(before(nseStart, "let client = try LxmfClient.start(config: config)",
                 "client.setAnnounceDisplayName(PendingNotification.readAnnounceDisplayName())")
            && before(nseStart, "client.setAnnounceDisplayName(PendingNotification.readAnnounceDisplayName())",
                      "client.setDeliveryCallback(nseDeliveryTrampoline)"),
          "the NSE's copy of the delivery destination answers path requests with the name (review IOS-DN-1)")
    check(source("Retichat/Services/RfedDistroClient.swift").contains(
            "announceName: UserPreferences.shared.announceDisplayName"),
          "the distro's pre-signed announce carries it too (§2.2)")
}

// MARK: - Review fixes

/// IOS-DN-1: the Announce Display Name reaches the NSE through the App Group.
func testTheAnnounceNameIsSharedWithTheNSE() {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("display-names-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    check(PendingNotification.readAnnounceDisplayName(in: dir) == "", "none until the app shares one")
    check(PendingNotification.writeAnnounceDisplayName("Ålice 👩‍💻", in: dir)
            && PendingNotification.readAnnounceDisplayName(in: dir) == "Ålice 👩‍💻", "the NSE reads what the app wrote")
    check(PendingNotification.writeAnnounceDisplayName("", in: dir)
            && PendingNotification.readAnnounceDisplayName(in: dir) == "", "an emptied name is shared too")
    check(!PendingNotification.writeAnnounceDisplayName("x", in: dir.appendingPathComponent("missing")),
          "a failed write is reported")
}

/// IOS-DN-3: why the conversation passes the version it was sent. This is
/// what @Published does: subscribers run in willSet.
final class Versioned: ObservableObject { @Published var version = 0 }

func testPublishedSendsBeforeTheValueChanges() {
    let model = Versioned()
    var seen: [(sent: Int, stored: Int)] = []
    let sub = model.$version.dropFirst().sink { seen.append(($0, model.version)) }
    model.version &+= 1
    check(seen.count == 1 && seen[0].sent == 1 && seen[0].stored == 0,
          "a subscriber is sent the new version while the property still holds the old one")
    _ = sub
}

/// IOS-DN-4: an announce-cache hit brings a stale announceName up to date.
func testTheAnnounceCacheReplacesAStaleName() {
    check(DisplayNames.announceNameFromCache(recalled: "Robert", stored: "Bob", announcedSinceLookup: false) == .set("Robert"),
          "a newer cached announce name replaces the stored one (§5.1)")
    check(DisplayNames.announceNameFromCache(recalled: "Robert", stored: nil, announcedSinceLookup: false) == .set("Robert"),
          "and fills an empty one, as before")
    check(DisplayNames.announceNameFromCache(recalled: "Bob", stored: "Bob", announcedSinceLookup: false) == .keep,
          "the same name changes nothing")
    check(DisplayNames.announceNameFromCache(recalled: nil, stored: "Bob", announcedSinceLookup: false) == .keep,
          "a miss is not an announce without a name")
    check(DisplayNames.announceNameFromCache(recalled: "Bob", stored: "Robert", announcedSinceLookup: true) == .keep,
          "an announce handled after the lookup began wins")
    let repo = source("Retichat/Services/ChatRepository.swift")
    let refresh = body(repo, "private func refreshAnnounceNameFromCache(")
    check(before(refresh, "let generation = announceGeneration[destHash, default: 0]", "ffiQueue.async")
            && refresh.contains("DisplayNames.announceNameFromCache(")
            && !refresh.contains("contact.announceName == nil else"),
          "the refresh replaces through that rule, and no longer only fills")
    let announce = body(repo, "private func handleAnnounce(")
    check(before(announce, "announceGeneration[hex, default: 0] &+= 1", "guard let ctx = modelContext else { return }"),
          "every handled announce is counted before any early return")
}

@main
enum DisplayNamesTests {
    static func main() {
        testTheNameStateBufferParses()
        testTheRetiredFieldNoLongerStopsTheParse()
        testTheAcceptTable()
        testTheAcceptOrder()
        testTheResolver()
        testTheNotificationServiceTitle()
        testTheChatNamesFile()
        testTheChannelSenderNamesFile()
        testTheChannelRule()
        testTheDigestMatchesTheRustVectors()
        testTheDistroUnwrapKeys()
        testTheContactMigration()
        testTheContactMigrationWiring()
        testTheSettingsMigration()
        testTheReceivePaths()
        testTheSurfaces()
        testTheChannelSend()
        testTheSettings()
        testTheAnnounceNameIsSharedWithTheNSE()
        testPublishedSendsBeforeTheValueChanges()
        testTheAnnounceCacheReplacesAStaleName()
        if failures.isEmpty {
            print("all display name tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
