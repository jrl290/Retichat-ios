// ReactionsTests.swift
//
// Message reactions (REACTIONS-DESIGN.md, approved by James 2026-10-17), the parts that run without
// the library:
//  - the upstream field 0x40 as LxmfFieldsDecoder reads it: REACTION_TO and REACTION_CONTENT as a
//    bin or a str, keys of any int width, a missing key or a reaction over 64 bytes refused with a
//    reason, anything but a map no reaction at all, and the walk kept in step either way;
//  - the Retichat field's keys 11 (GROUP_POST_ID) and 12 (SENT_HASH);
//  - apply_reaction's ordering (a newer t wins, an equal or older one is ignored, a removal is kept
//    as "e": ""), the chips, the toggle, the target a message names and the Group post id;
//  - the `react` group sync's form check, its step and its writer JSON;
//  - a reaction's notification (§3 "Notifications"): its words, the quote and where the NSE finds
//    it; an NSE run that stores every reaction for the app and shows only one it can word;
//  - the wiring, on the source: every receive path checks for a reaction before anything is stored,
//    counted or reordered; the target is looked for only in the chat the reaction came in on;
//    someone else's reaction to the user's own message is notified once, by the app or the NSE;
//    the sends carry what §4 and §5 say;
//  - the bubble's footer across it, sent or received: the time leading, the delivery icon and
//    reactions trailing.
// tests/ReactionsFFITests.swift runs the same fields through the real library.
//
// Run from the workspace root with:
//
//   swiftc -parse-as-library -o /private/tmp/claude-501/reactions \
//     Retichat-ios/Retichat/Bridge/LxmfFields.swift \
//     Retichat-ios/Retichat/Services/DeliveryPolicy.swift \
//     Retichat-ios/Retichat/Services/DistroGroupSync.swift \
//     Retichat-ios/Retichat/Services/PendingNotification.swift \
//     Retichat-ios/Retichat/Services/Reactions.swift \
//     Retichat-ios/tests/ReactionsTests.swift && \
//   /private/tmp/claude-501/reactions

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

func source(_ path: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

/// The text of the declaration that starts with `start`, to the closing brace at its own indent.
func body(_ code: String, _ start: String) -> String {
    guard let from = code.range(of: start) else { return "" }
    let lineStart = code[..<from.lowerBound].lastIndex(of: "\n").map { code.index(after: $0) } ?? code.startIndex
    let indent = String(code[lineStart..<from.lowerBound].prefix { $0 == " " })
    guard let end = code.range(of: "\n\(indent)}\n", range: from.upperBound..<code.endIndex) else { return "" }
    return String(code[from.lowerBound..<end.upperBound])
}

/// Whether `first` occurs in `code`, and before every occurrence of `second` (which must occur).
func before(_ code: String, _ first: String, _ second: String) -> Bool {
    guard let a = code.range(of: first), let b = code.range(of: second) else { return false }
    return a.lowerBound < b.lowerBound
}

// MARK: - msgpack, as the tests write it

func bin(_ d: Data) -> [UInt8] { [0xc4, UInt8(d.count)] + [UInt8](d) }
func bin(_ s: String) -> [UInt8] { bin(Data(s.utf8)) }
func str(_ s: String) -> [UInt8] {
    let u = [UInt8](s.utf8)
    return u.count < 32 ? [0xa0 | UInt8(u.count)] + u : [0xd9, UInt8(u.count)] + u
}
func map(_ pairs: [([UInt8], [UInt8])]) -> [UInt8] {
    [0x80 | UInt8(pairs.count)] + pairs.flatMap { $0.0 + $0.1 }
}
/// A top-level fields map.
func fields(_ pairs: [([UInt8], [UInt8])]) -> LxmfFields { LxmfFieldsDecoder.decode(Data(map(pairs))) }

let target = Data((0..<32).map { UInt8($0) })
let postId = String(repeating: "5a", count: 16)
let thumbs = "👍"

// MARK: - 0x40

func theReactionFieldIsReadAsUpstreamAndColumbaWriteIt() {
    // {0x40: {0x00: bin, 0x01: bin}}: what LXMF-rust and Columba write.
    let both = fields([([0x40], map([([0x00], bin(target)), ([0x01], bin(thumbs))]))])
    checkEqual(both.reaction, .react(to: target, content: thumbs), "bin REACTION_TO and bin REACTION_CONTENT")
    // Upstream reads either; a str of either is taken as its bytes.
    let strs = fields([([0x40], map([([0x00], [0xd9, 32] + [UInt8](target)), ([0x01], str(thumbs))]))])
    checkEqual(strs.reaction, .react(to: target, content: thumbs), "str forms")
    // Keys of any int width, in either order.
    let wide = fields([([0xcc, 0x40], map([([0xcd, 0x00, 0x01], bin(thumbs)), ([0xcc, 0x00], bin(target))]))])
    checkEqual(wide.reaction, .react(to: target, content: thumbs), "uint8 and uint16 keys, content first")
    // An empty REACTION_CONTENT is a removal (Retichat), a 16-byte target a Group post id.
    let removal = fields([([0x40], map([([0x00], bin(Data(repeating: 7, count: 16))), ([0x01], bin(""))]))])
    checkEqual(removal.reaction, .react(to: Data(repeating: 7, count: 16), content: ""), "a removal")
    checkEqual(fields([([0x41], bin("x"))]).reaction, nil, "no 0x40, no reaction")
}

func aReactionMissingAKeyOrOverSixtyFourBytesIsRefusedWithAReason() {
    func refused(_ r: Reaction?) -> String? { if case .refused(let why)? = r { return why } else { return nil } }
    checkEqual(refused(fields([([0x40], map([([0x01], bin(thumbs))]))]).reaction),
               "REACTION_TO is missing", "no REACTION_TO")
    checkEqual(refused(fields([([0x40], map([([0x00], bin(target))]))]).reaction),
               "REACTION_CONTENT is missing", "no REACTION_CONTENT")
    checkEqual(refused(fields([([0x40], map([([0x00], [0x05]), ([0x01], bin(thumbs))]))]).reaction),
               "REACTION_TO is not a bin or a str", "an int REACTION_TO")
    checkEqual(refused(fields([([0x40], map([([0x00], bin(target)), ([0x01], [0xc0])]))]).reaction),
               "REACTION_CONTENT is not a bin or a str", "a nil REACTION_CONTENT")
    let sixtyFour = String(repeating: "a", count: 64)
    checkEqual(fields([([0x40], map([([0x00], bin(target)), ([0x01], bin(sixtyFour))]))]).reaction,
               .react(to: target, content: sixtyFour), "64 bytes are taken")
    checkEqual(refused(fields([([0x40], map([([0x00], bin(target)), ([0x01], bin(sixtyFour + "a"))]))]).reaction),
               "REACTION_CONTENT is 65 bytes, more than 64", "65 bytes are refused")
    // 16 emoji of four bytes are 64 bytes; one more letter is 65.
    let emoji = String(repeating: "😀", count: 16)
    checkEqual(fields([([0x40], map([([0x00], bin(target)), ([0x01], str(emoji + "a"))]))]).reaction.flatMap(refused),
               "REACTION_CONTENT is 65 bytes, more than 64", "bytes, not characters")
    checkEqual(refused(fields([([0x40], map([([0x00], bin(target)), ([0x01], bin(Data([0xff, 0xfe])))]))]).reaction),
               "REACTION_CONTENT is not UTF-8", "not UTF-8")
}

func anythingButAMapIsNoReactionAndTheWalkStaysInStep() {
    // 0x40 as a bin, then a title-like field after it: no reaction, and the next field is read.
    let notMap = fields([([0x40], bin("x")), ([0xcc, 0xd1], map([([0x0b], str(postId))]))])
    checkEqual(notMap.reaction, nil, "a bin 0x40 is no reaction")
    checkEqual(notMap.groupPostId, postId, "the field after it is still read")
    // A bin whose declared length runs past its value refuses REACTION_TO, and the walk goes on.
    let short: [UInt8] = map([([0x00], [0xc4, 0x05, 1, 2]), ([0x01], bin(thumbs))])
    let walked = LxmfFieldsDecoder.decode(Data([0x82, 0x40] + short + [0xcc, 0xd1] + map([([0x0b], str(postId))])))
    check(walked.reaction != nil, "a truncated value is not taken as a reaction's bytes")
    if case .react? = walked.reaction { check(false, "a truncated REACTION_TO is never a target") }
}

// MARK: - 0xD1 keys 11 and 12

func theRetichatFieldCarriesThePostIdAndTheSentHash() {
    let hash = String(repeating: "ab", count: 32)
    let both = fields([([0xcc, 0xd1], map([([0x0b], str(postId)), ([0x0c], str(hash))]))])
    checkEqual(both.groupPostId, postId, "key 11, a str of 32 hex")
    checkEqual(both.sentHash, hash, "key 12, a str of 64 hex")
    let upper = fields([([0xcc, 0xd1], map([([0x0b], str(postId.uppercased())), ([0x0c], str(hash.uppercased()))]))])
    checkEqual(upper.groupPostId, postId, "an upper-case post id, lowercased")
    checkEqual(upper.sentHash, hash, "an upper-case hash, lowercased")
    let wrong = fields([([0xcc, 0xd1], map([([0x0b], str(String(postId.dropLast()))), ([0x0c], bin(Data(repeating: 1, count: 32)))]))])
    checkEqual(wrong.groupPostId, nil, "31 hex is no post id")
    checkEqual(wrong.sentHash, nil, "a bin is no sent hash (key 12 is a str)")
    checkEqual(fields([([0xcc, 0xd1], map([([0x0c], str(String(repeating: "g", count: 64)))]))]).sentHash, nil,
               "64 characters that are not hex are no sent hash")
    checkEqual(RetichatField.groupPostIdKey, 11, "GROUP_POST_ID is key 11")
    checkEqual(RetichatField.sentHashKey, 12, "SENT_HASH is key 12")
    checkEqual(ReactionField.field, 0x40, "FIELD_REACTION is 0x40")
}

// MARK: - apply_reaction and the chips

func aNewerReactionWinsAndAnEqualOrOlderOneIsIgnored() {
    let a = String(repeating: "a1", count: 16), b = String(repeating: "b2", count: 16)
    var json = Reactions.apply(nil, reactor: a, emoji: "👍", atMs: 100)
    checkEqual(Reactions.decode(json)[a], Reactions.Entry(e: "👍", t: 100), "the first reaction is held")
    checkEqual(Reactions.apply(json, reactor: a, emoji: "❤️", atMs: 100), nil, "an equal t changes nothing")
    checkEqual(Reactions.apply(json, reactor: a, emoji: "❤️", atMs: 99), nil, "an older one changes nothing")
    json = Reactions.apply(json, reactor: a.uppercased(), emoji: "❤️", atMs: 101)
    checkEqual(Reactions.decode(json)[a], Reactions.Entry(e: "❤️", t: 101), "a newer one replaces it, the reactor lowercased")
    checkEqual(Reactions.decode(json).count, 1, "one entry per reactor")
    json = Reactions.apply(json, reactor: a, emoji: "", atMs: 102)
    checkEqual(Reactions.decode(json)[a], Reactions.Entry(e: "", t: 102), "a removal is kept as \"e\": \"\"")
    checkEqual(Reactions.apply(json, reactor: a, emoji: "👍", atMs: 101), nil, "so a late older reaction cannot bring one back")
    json = Reactions.apply(json, reactor: b, emoji: "👍", atMs: 50)
    checkEqual(Reactions.decode(json).count, 2, "another reactor's is kept beside it")
    checkEqual(json, #"{"\#(a)":{"e":"","t":102},"\#(b)":{"e":"👍","t":50}}"#, "the stored form, sorted")
    checkEqual(Reactions.decode("not json"), [:], "unreadable JSON holds nothing")
    checkEqual(Reactions.ms(1_790_000_000.1234), 1_790_000_000_123, "seconds as milliseconds, rounded down")
}

func theChipsAreGroupedCountedAndMarkedMine() {
    var json: String?
    let me = "dd", sibling = "ee"
    for (who, e, t) in [("aa", "😂", 30), ("bb", "👍", 10), ("cc", "👍", 20), (me, "😂", 40), ("ff", "", 5)] as [(String, String, Int64)] {
        json = Reactions.apply(json, reactor: who, emoji: e, atMs: t)
    }
    let chips = Reactions.chips(json, me: [me, sibling])
    checkEqual(chips.map(\.emoji), ["👍", "😂"], "grouped by reaction, in the order each was first given, no removal")
    checkEqual(chips.map(\.count), [2, 2], "counted")
    checkEqual(chips.map(\.mine), [false, true], "marked where one of the reactors is me")
    checkEqual(Reactions.chips(json, me: [sibling]).map(\.mine), [false, false], "a sibling address marks only its own")
    checkEqual(Reactions.current(json, me: [me, sibling]), "😂", "my current reaction")
    json = Reactions.apply(json, reactor: sibling, emoji: "👍", atMs: 50)
    checkEqual(Reactions.current(json, me: [me, sibling]), "👍", "the newest of my addresses' reactions")
    checkEqual(Reactions.current(json, me: ["zz"]), nil, "none when I never reacted")
    checkEqual(Reactions.toggled(current: "👍", picked: "👍"), "", "the same one again removes it")
    checkEqual(Reactions.toggled(current: "👍", picked: "❤️"), "❤️", "another one replaces it")
    checkEqual(Reactions.toggled(current: nil, picked: "❤️"), "❤️", "a first one")
    checkEqual(Reactions.toggled(current: "", picked: "❤️"), "❤️", "after a removal")
    checkEqual(Reactions.quick, ["👍", "❤️", "😂", "😮", "😢", "🙏"], "the quick reactions of §7")
}

func theTargetIsThePostIdInAGroupAndTheLxmfHashInADirectChat() {
    let hash = String(repeating: "c4", count: 32)
    let other = String(repeating: "e5", count: 32)
    checkEqual(Reactions.target(isGroup: true, id: hash, lxmfHash: hash, postId: postId),
               Reactions.hexBytes(postId, count: 16), "a Group post: its post id, 16 bytes")
    checkEqual(Reactions.target(isGroup: true, id: hash, lxmfHash: hash, postId: nil), nil,
               "a Group post without one (an older client's) offers none, never its hash")
    checkEqual(Reactions.target(isGroup: false, id: "a-derived-id", lxmfHash: hash, postId: nil),
               Reactions.hexBytes(hash, count: 32), "a direct message: its LXMF hash")
    checkEqual(Reactions.target(isGroup: false, id: other, lxmfHash: nil, postId: nil),
               Reactions.hexBytes(other, count: 32), "else its id, when that is a hash")
    checkEqual(Reactions.target(isGroup: false, id: String(repeating: "c4", count: 16), lxmfHash: nil, postId: nil), nil,
               "a 32-hex id (a derived one) names nothing")
    checkEqual(Reactions.target(isGroup: false, id: "inv_x", lxmfHash: nil, postId: postId), nil, "nor does any other id")
    checkEqual(Reactions.hexBytes("zz", count: 1), nil, "not hex")
    let a = Reactions.newPostId(), b = Reactions.newPostId()
    check(a != nil && a != b, "a new post id each time")
    check(a.map { $0.count == 32 && $0 == $0.lowercased() && Reactions.hexBytes($0, count: 16) != nil } ?? false,
          "32 lowercase hex")
}

// MARK: - The react group sync

func reading(_ object: [String: Any]) -> DistroGroupSync.Reading? {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
    return try? JSONDecoder().decode(DistroGroupSync.Reading.self, from: data)
}

func theReactGroupSyncIsCheckedAppliedOnlyInAJoinedGroupAndWritten() {
    let d = String(repeating: "d1", count: 16)
    let gid = String(repeating: "6b", count: 16)
    func form(_ extra: [String: Any]) -> Result<DistroGroupSync.Form, DistroGroupSync.Problem>? {
        var o: [String: Any] = ["op": "react", "group_id": gid, "at_ms": 1_790_000_000_123, "left": [String]()]
        o.merge(extra) { $1 }
        return reading(o).map { DistroGroupSync.form($0, distroHex: d) }
    }
    if case .success(let f)? = form(["text": thumbs, "post_id": postId.uppercased()]) {
        checkEqual(f.op, .react, "the op")
        checkEqual(f.text, thumbs, "the reaction")
        checkEqual(f.postId, postId, "the post it reacts to, lowercased")
    } else {
        check(false, "a well-formed react passes rule 4")
    }
    if case .success(let f)? = form(["text": "", "post_id": postId]) {
        checkEqual(f.text, "", "a removal is a react with empty text")
    } else {
        check(false, "a removal passes rule 4")
    }
    for (name, extra) in [("no post_id", ["text": thumbs]), ("a 31-hex post_id", ["text": thumbs, "post_id": String(postId.dropLast())]),
                          ("no text", ["post_id": postId]),
                          ("65 bytes", ["text": String(repeating: "a", count: 65), "post_id": postId])] as [(String, [String: Any])] {
        if case .failure? = form(extra) {} else { check(false, "\(name) is malformed") }
    }
    // A post carries its post id when it has one; an older device's has none.
    var post: [String: Any] = ["op": "post", "group_id": gid, "at_ms": 1, "left": [String](), "text": "hi", "post_id": postId]
    if case .success(let f)? = reading(post).map({ DistroGroupSync.form($0, distroHex: d) }) {
        checkEqual(f.postId, postId, "a post's post id")
    } else { check(false, "a post with a post id passes") }
    post["post_id"] = nil
    if case .success(let f)? = reading(post).map({ DistroGroupSync.form($0, distroHex: d) }) {
        checkEqual(f.postId, nil, "an older device's post has none")
    } else { check(false, "a post without one passes") }

    checkEqual(DistroGroupSync.step(.react, standing: .joined, ownMemberIsD: true, pendingMatches: false),
               .applyOwnReaction, "applied in a joined group")
    for standing in [DistroGroupSync.Standing.notHeld, .pending, .closed] {
        if case .nothing = DistroGroupSync.step(.react, standing: standing, ownMemberIsD: true, pendingMatches: false) {} else {
            check(false, "nothing for a group \(standing) here (no reaction is held)")
        }
    }
    if case .nothing = DistroGroupSync.step(.react, standing: .joined, ownMemberIsD: false, pendingMatches: false) {} else {
        check(false, "nothing in a group held as the device's own address (rule 5)")
    }

    let react = DistroGroupSync.writerJSON(op: .react, groupId: gid, atMs: 5, text: thumbs, left: [], postId: postId)
    checkEqual(react, #"{"at_ms":5,"group_id":"\#(gid)","left":[],"op":"react","post_id":"\#(postId)","text":"👍"}"#,
               "the react writer JSON")
    check(DistroGroupSync.writerJSON(op: .react, groupId: gid, atMs: 5, text: "", left: [], postId: postId).contains(#""text":"""#),
          "a removal writes an empty text")
    check(DistroGroupSync.writerJSON(op: .post, groupId: gid, atMs: 5, text: "x", left: [], postId: postId).contains(#""post_id":"\#(postId)""#),
          "a post writes its post id")
    check(!DistroGroupSync.writerJSON(op: .post, groupId: gid, atMs: 5, text: "x", left: []).contains("post_id"),
          "and none without one, as before")
}

// MARK: - The NSE

func aReactionsNotificationCitesTheUsersMessage() {
    checkEqual(ReactionNotice.text(emoji: "👍", quote: "Hi there"), "Reacted 👍 to \"Hi there\"", "the words")
    checkEqual(ReactionNotice.text(emoji: "😂", quote: ""), "Reacted 😂 to your attachment", "a message with no text")
    checkEqual(ReactionNotice.quote("  See you\nat 6\n\ttomorrow "), "See you at 6 tomorrow", "the quote is one line")
    let exact = String(repeating: "x", count: ReactionNotice.quoteMax)
    checkEqual(ReactionNotice.quote(exact), exact, "kept whole at its length")
    checkEqual(ReactionNotice.quote(exact + "y"), exact + "…", "and cut past it")
    let family = "👨‍👩‍👧"
    checkEqual(ReactionNotice.quote(String(repeating: family, count: ReactionNotice.quoteMax + 1)),
               String(repeating: family, count: ReactionNotice.quoteMax) + "…", "an emoji counts as one, never split")
    checkEqual(ReactionNotice.quote(String(repeating: "a", count: ReactionNotice.quoteMax - 1) + " bc"),
               String(repeating: "a", count: ReactionNotice.quoteMax - 1) + "…", "no space before the …")

    // Where the NSE finds it: the chat the reaction came in on, and the target it names.
    let peer = String(repeating: "a", count: 32), gid = String(repeating: "b", count: 32)
    let hash = Data(repeating: 0xef, count: 32), postId = Data(repeating: 0x0f, count: 16)
    let quotes = [ReactionNotice.key(chatId: peer.uppercased(), target: String(repeating: "EF", count: 32)): "Hi there",
                  ReactionNotice.key(chatId: gid, target: String(repeating: "0f", count: 16)): ""]
    checkEqual(ReactionNotice.text(for: .react(to: hash, content: "👍"), chatId: peer, quotes: quotes),
               "Reacted 👍 to \"Hi there\"", "a direct chat's, by its LXMF hash")
    checkEqual(ReactionNotice.text(for: .react(to: postId, content: "❤️"), chatId: gid, quotes: quotes),
               "Reacted ❤️ to your attachment", "a Group's, by its post id")
    check(ReactionNotice.text(for: .react(to: hash, content: ""), chatId: peer, quotes: quotes) == nil, "never a take-back")
    check(ReactionNotice.text(for: .react(to: hash, content: "👍"), chatId: gid, quotes: quotes) == nil,
          "only in the chat it came in on")
    check(ReactionNotice.text(for: .react(to: Data(repeating: 1, count: 32), content: "👍"), chatId: peer, quotes: quotes) == nil,
          "not a message among the user's newest sends")
    check(ReactionNotice.text(for: .refused("x"), chatId: peer, quotes: quotes) == nil
            && ReactionNotice.text(for: nil, chatId: peer, quotes: quotes) == nil, "nor anything but a reaction")

    // The app keeps the quotes for the NSE, its newest sends, when they change.
    let write = body(repo, "private func writeNSESentQuotes(")
    check(write.contains("#Predicate { $0.isOutgoing == true }") && write.contains("desc.fetchLimit = ReactionNotice.sentQuotesLimit")
            && write.contains("Reactions.target(isGroup: groups.contains(m.chatId)")
            && write.contains("ReactionNotice.key(chatId: m.chatId, target: Reactions.hex(target))] = ReactionNotice.quote(m.content)")
            && write.contains("guard quotes != lastNSESentQuotes else { return }"), "the quotes the app writes")
    check(body(repo, "func refreshChats()").contains("writeNSESentQuotes(groups:"), "on every refresh")
}

func anNSERunStoresEveryReactionAndShowsOnlyOneItCanWord() {
    func message(_ n: Int, _ t: Double, quiet: Bool) -> PendingNotification.NSEMessage {
        PendingNotification.NSEMessage(messageHash: String(format: "%032x", n), senderHash: String(format: "%032x", n + 100),
                                       destHash: String(repeating: "d", count: 32), title: "", content: quiet ? "" : "m\(n)",
                                       timestamp: t, signatureValid: true, fieldsRawBase64: quiet ? "q" : "")
    }
    var stored: [String] = []
    let run = PendingNotification.NSERun(prepare: { $0 }, store: { stored.append($0.messageHash); return true },
                                         shows: { $0.fieldsRawBase64 != "q" })
    run.deliver(message(1, 10, quiet: false))
    run.deliver(message(2, 30, quiet: true))
    run.deliver(message(3, 20, quiet: false))
    run.deliver(message(4, 40, quiet: true))
    let s = run.summary()
    checkEqual(stored.count, 4, "every delivery is stored for the app")
    checkEqual(s.newest?.messageHash, String(format: "%032x", 3), "the newest shown is the newest that may be shown")
    checkEqual(s.others, 1, "a reaction is not counted in \"+N more\"")
    checkEqual(s.quiet, 2, "it is counted as quiet")
    let onlyQuiet = PendingNotification.NSERun(prepare: { $0 }, store: { _ in true }, shows: { _ in false })
    onlyQuiet.deliver(message(5, 1, quiet: true))
    check(onlyQuiet.summary().newest == nil && onlyQuiet.summary().quiet == 1, "a run of reactions alone shows nothing")

    let nse = source("NotificationService/NotificationService.swift")
    let handOff = body(nse, "private func nseHandOffForm(")
    check(handOff.contains("if case .refused(let why)? = fields.reaction {") && handOff.contains("return nil"),
          "the NSE drops a refused reaction, as the app does")
    check(nse.contains("PendingNotification.NSERun(prepare: nseHandOffForm, shows: nseShows)"), "every run asks nseShows")
    let shows = body(nse, "private func nseShows(")
    check(shows.contains("guard fields.reaction != nil else { return true }")
            && before(shows, "guard let notice = nseReactionNotice(msg, fields: fields) else {", "return false"),
          "nseShows: a reaction only as nseReactionNotice words it")
    check(shows.contains("if notice.group != nil { PendingNotification.recordNSECountedGroupHashes([msg.messageHash]) }"),
          "a Group reaction shown is counted, so the app does not notify it again")
    let notice = body(nse, "private func nseReactionNotice(")
    check(before(notice, "guard case .post(let id, let name) = outcome else { return nil }", "ReactionNotice.text(for: fields.reaction, chatId: group?.id ?? msg.senderHash,"),
          "in a Group only where a post from its source would show, and in that Group")
    check(nse.contains("if decoded.reaction != nil, let notice = nseReactionNotice(m, fields: decoded) {")
            && nse.contains("notice.group?.id ?? m.senderHash,") && nse.contains("notice.group.map { \"\\(title) (\\($0.name))\" } ?? title))"),
          "the newest, a reaction, in its words, a Group's titled and threaded as a post")
    check(nse.contains("} else if summary.dropped > 0 || summary.quiet > 0 || distro.pulled > 0 || channelPull.pulled > 0 {"),
          "reactions not shown, alone, suppress the alert")
    let pull = body(source("NotificationService/NSEDistroPull.swift"), "private static func unwrapToShow(")
    check(before(pull, "} else if let text = ReactionNotice.text(for: fields.reaction, chatId: groupId,", "group reaction from %@ not shown"),
          "the distro pull shows a Group reaction only as ReactionNotice words it")
    check(before(pull, "guard let text = ReactionNotice.text(for: reaction, chatId: m.source_hash,", "return Shown(senderHash: m.source_hash.lowercased(), title: m.title ?? \"\","),
          "and a direct one")
}

// MARK: - The wiring

let repo = source("Retichat/Services/ChatRepository.swift")

func everyReceivePathChecksForAReactionBeforeItStoresAnything() {
    let incoming = body(repo, "private func handleIncomingMessage(")
    check(before(incoming, "if tookReaction(fields, chatId: srcHex, reactor: srcHex,", "storeIncomingDirect("),
          "handleIncomingMessage, before it stores")
    let ahead = incoming.components(separatedBy: "if tookReaction(").first ?? ""
    check(incoming.contains("if tookReaction(") && !ahead.contains("ensureChat(") && !ahead.contains("ensureContact(")
            && body(repo, "private func storeIncomingDirect(").contains("ensureChat(id: chatId, peerHash: srcHex)"),
          "and before it makes a chat or a contact (storeIncomingDirect makes them)")
    check(incoming.contains("let nameField = fields.reaction == nil ? LxmfClient.decodeDisplayName(fieldsRaw: fieldsRaw) : .absent"),
          "and never takes a name from a reaction")
    let distro = body(repo, "private func handleDistroMessage(")
    check(before(distro, "path: \"handleDistroMessage\",", "DistroMessageStore.stored(m)")
            && before(distro, "path: \"handleDistroMessage\",", "storeIncomingDirect("), "handleDistroMessage")
    let sent = body(repo, "private func handleDistroSentCopy(")
    check(before(sent, "if tookReaction(fields, chatId: c.recipientHex, reactor: distroHex,", "MessageEntity("),
          "handleDistroSentCopy: reactor D, in the chat with the recipient, before it stores")
    check(sent.contains("lxmfHash: fields.sentHash"), "and a stored copy keeps M's hash (key 12)")
    let group = body(repo, "private func handleGroupMessage(")
    check(before(group, "if tookReaction(fields, chatId: chat.id, inGroup: true, reactor: author,", "handleGroupChatMessage("),
          "handleGroupMessage (relayed copies too: the author follows the post's rules)")
    let nse = body(repo, "func importNSEMessages()")
    check(before(nse, "if tookReaction(fields, chatId: srcHex, reactor: srcHex,", "ensureChat(id: chatId, peerHash: srcHex)")
            && before(nse, "if tookReaction(", "MessageEntity("), "importNSEMessages")
    check(nse.contains("let nameField = fields.reaction == nil ? LxmfClient.decodeDisplayName(fieldsRaw: fieldsData) : .absent"),
          "and no name from a reaction there either")
    let sync = body(repo, "private func applyGroupSync(")
    let own = sync.components(separatedBy: "case .applyOwnReaction:").dropFirst().first.map { String($0.prefix(600)) } ?? ""
    check(own.contains("applyReaction(to:") && own.contains("reactor: d,") && own.contains("inGroup: true")
            && !own.contains("MessageEntity("), "handleDistroGroupSync: reactor D, no bubble")
    let arrival = body(repo, "private func handleDistroGroupArrival(")
    check(arrival.contains("if fields.reaction != nil { a.displayName = .absent }"), "a Group reaction on the distro path takes no name")
    let relay = body(repo, "private func handleGroupRelayRequest(")
    check(relay.contains("let postId = fields.groupPostId") && relay.contains("postId: postId,")
            && relay.contains("reaction: reaction,"), "a relay carries the post id and the reaction")
    check(relay.contains("not relayed: reaction dropped:"), "a reaction this client refuses is not relayed")
}

func someoneElsesReactionToTheUsersMessageIsNotifiedOnce() {
    let took = body(repo, "private func tookReaction(")
    check(took.contains("reactor: reactor, timestamp: timestamp, path: path), notify {")
            && took.contains("notifyReaction(target, emoji: content, chatId: chatId, reactor: reactor, countedHash: countedHash)"),
          "notified only when applied (a repeat changes nothing) and asked for")
    let notify = body(repo, "private func notifyReaction(")
    check(notify.contains("guard !emoji.isEmpty, target.isOutgoing, let ctx = modelContext else { return }"),
          "never a take-back, never on someone else's message")
    check(notify.contains("!reactionSelf(chat).contains(reactor) else { return }"), "never the user's own")
    check(before(notify, "PendingNotification.takeNSECountedGroupHash(countedHash)", "notifManager.postMessageNotification("),
          "never a Group reaction the NSE showed")
    check(notify.contains("senderName: chat.isGroup ? \"\\(name) (\\(chat.groupName ?? \"Group\"))\" : name,")
            && notify.contains("content: ReactionNotice.text(emoji: emoji, quote: ReactionNotice.quote(target.content)))"),
          "titled as a message from the reactor would be, worded with the message")
    // Each path says whether the app notifies: the NSE decided what it delivered.
    check(body(repo, "private func handleIncomingMessage(").contains("path: \"handleIncomingMessage\",\n                        notify: true)"), "live: notified")
    check(body(repo, "private func handleDistroMessage(").contains("notify: !m.shownByNSE)"), "the distro: unless the NSE pulled it")
    check(body(repo, "private func handleDistroSentCopy(").contains("path: \"handleDistroSentCopy\", notify: false)"), "the user's own: never")
    check(body(repo, "func importNSEMessages()").contains("path: \"importNSEMessages\",\n                            notify: false)"), "from the NSE: never")
    check(body(repo, "private func handleGroupMessage(").contains("notify: true, countedHash: hash.hexString)"),
          "a Group: unless the NSE counted it")
}

func theTargetIsLookedForOnlyInTheChatTheReactionCameIn() {
    let find = body(repo, "private func reactionTarget(")
    check(find.contains("$0.chatId == chatId"), "every lookup is confined to the chat")
    check(!find.contains("ensureChat") && !find.contains("ensureContact") && !find.contains("insert("),
          "a reaction never makes a chat, a contact or a message")
    let apply = body(repo, "private func applyReaction(")
    check(apply.contains("not in") && apply.contains("one as new or newer is held"), "each drop says why")
    check(!apply.contains("notify") && !apply.contains("lastMessageTime") && !apply.contains("unread"),
          "no notification, no reordering, no unread change")
}

func theSendsCarryWhatSectionsFourAndFiveSay() {
    let direct = body(repo, "private func reactInDirectChat(")
    check(direct.contains("LxmfClient.messageSetReaction(") && direct.contains("sendMessageViaAppLinks("), "a direct reaction is sent")
    check(direct.contains("oweDistroSentCopy(") && direct.contains("reaction: (to, content)"),
          "with a Distro Sync of the send when signed as the Distro")
    check(!direct.contains("MessageEntity("), "and no bubble")
    let group = body(repo, "private func reactInGroup(")
    check(group.contains("reaction: (to, content)") && group.contains("oweGroupSync(.react,"), "a Group reaction fans out and owes a react sync")
    let afterFanout = group.components(separatedBy: "guard submitted > 0 else {").dropFirst().first ?? ""
    check(afterFanout.contains("self?.oweGroupSync(.react, groupId: chatId, signer: signer, atMs: atMs, text: content, postId: postId)"),
          "owed once an envelope was submitted")
    check(group.contains("if owesSync && targets.isEmpty {\n            oweGroupSync(.react,"), "or at once with no member to send to")
    check(body(repo, "private func sendGroupMessage(").contains("let postId = Reactions.newPostId()"), "every post gets a post id")
    let manager = source("Retichat/Services/GroupChatManager.swift")
    check(body(manager, "private func setPostIdAndReaction(").contains("LxmfClient.messageSetGroupPostId(handle, postId)"),
          "key 11 on every member copy")
    check(body(manager, "func performRelay(").contains("setPostIdAndReaction("), "and on every relayed copy")
    let outbox = source("Retichat/Services/DistroOutboxRuntime.swift")
    let owe = body(outbox, "func oweSentCopy(")
    check(owe.contains("LxmfClient.messageSetSentHash(handle, sentHash)")
            && owe.contains("LxmfClient.messageSetReaction(handle, to: $0.to, content: $0.content)"),
          "the Distro Sync of a send carries M's hash (key 12) and M's 0x40")
    let react = body(repo, "func react(messageId: String, chatId: String, emoji: String)")
    check(react.contains("DisplayNames.isSystemMessageId(target.id)") && react.contains("Reactions.target("),
          "no reaction on a system message or a message that names no target")
}

func theFooterSpansTheBubbleTheTimeLeadingTheRestTrailing() {
    let components = source("Retichat/Views/Components/GlassComponents.swift")
    let bubble = body(components, "private var bubble: some View {")
    check(bubble.contains("BubbleStack(contentTrailing: message.isOutgoing, spacing: 4) {"),
          "the bubble is a BubbleStack, its content on the sender's side (James, 2026-10-17)")
    check(before(bubble, "Text(message.content)", "Text(formatTime(message.timestamp))")
            && bubble.contains("                    reactionMarks\n                }\n            }\n        }\n        .padding(.horizontal, 12)"),
          "the footer (time, delivery icon, reactions) is its last subview")
    check(bubble.contains("Text(formatTime(message.timestamp))\n                    .font(.caption2)\n                    .foregroundColor(.retichatOnSurfaceVariant)\n                    .frame(maxWidth: .infinity, alignment: .leading)"),
          "the time takes the footer's width at its leading edge, the icon and reactions after it at the trailing edge")
    let stack = body(components, "struct BubbleStack: Layout {")
    check(stack.contains("var width = max(body.map(\\.width).max() ?? 0, footer.sizeThatFits(.unspecified).width)"),
          "the bubble is as wide as its widest subview, the footer's own width included, no wider")
    check(stack.contains("let x = contentTrailing && !footer ? bounds.maxX - size.width : bounds.minX")
            && stack.contains("proposal: ProposedViewSize(width: footer ? bounds.width : size.width, height: size.height)"),
          "and the footer is given the bubble's width, in every bubble")
}

let allTests: [(String, () -> Void)] = [
    ("the reaction field is read as upstream and Columba write it", theReactionFieldIsReadAsUpstreamAndColumbaWriteIt),
    ("a reaction missing a key or over 64 bytes is refused with a reason", aReactionMissingAKeyOrOverSixtyFourBytesIsRefusedWithAReason),
    ("anything but a map is no reaction, and the walk stays in step", anythingButAMapIsNoReactionAndTheWalkStaysInStep),
    ("the Retichat field carries the post id and the sent hash", theRetichatFieldCarriesThePostIdAndTheSentHash),
    ("a newer reaction wins, and an equal or older one is ignored", aNewerReactionWinsAndAnEqualOrOlderOneIsIgnored),
    ("the chips are grouped, counted and marked mine", theChipsAreGroupedCountedAndMarkedMine),
    ("the target is the post id in a Group and the LXMF hash in a direct chat", theTargetIsThePostIdInAGroupAndTheLxmfHashInADirectChat),
    ("the react group sync is checked, applied only in a joined group, and written", theReactGroupSyncIsCheckedAppliedOnlyInAJoinedGroupAndWritten),
    ("a reaction's notification cites the user's message", aReactionsNotificationCitesTheUsersMessage),
    ("an NSE run stores every reaction and shows only one it can word", anNSERunStoresEveryReactionAndShowsOnlyOneItCanWord),
    ("someone else's reaction to the user's message is notified once", someoneElsesReactionToTheUsersMessageIsNotifiedOnce),
    ("every receive path checks for a reaction before it stores anything", everyReceivePathChecksForAReactionBeforeItStoresAnything),
    ("the target is looked for only in the chat the reaction came in", theTargetIsLookedForOnlyInTheChatTheReactionCameIn),
    ("the sends carry what §4 and §5 say", theSendsCarryWhatSectionsFourAndFiveSay),
    ("the footer spans the bubble, the time leading and the rest trailing", theFooterSpansTheBubbleTheTimeLeadingTheRestTrailing),
]

@main
enum ReactionsTests {
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
