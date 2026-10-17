//
//  Reactions.swift
//  Retichat
//
//  Message reactions (REACTIONS-DESIGN.md, approved by James 2026-10-17): what a message's
//  reactions hold, how a reaction is applied to them, what the chips under a bubble show, and
//  the Group post id. The field itself is read by LxmfFieldsDecoder (Reaction) and written by
//  LxmfClient.messageSetReaction; the receive paths, the sends and the storage are
//  ChatRepository's.
//
//  Foundation and Security only, so tests/ReactionsTests.swift runs it for real.
//

import Foundation
import Security

nonisolated enum Reactions {
    /// The quick reactions offered on a bubble (§7). Any other received reaction (short text up to
    /// 64 bytes) is shown as it is.
    static let quick = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

    /// One reactor's reaction as MessageEntity.reactionsJson keeps it (§6):
    /// `{"<reactor 32 hex>": {"e": "👍", "t": <ms>}}`, `"e": ""` a removal.
    struct Entry: Codable, Equatable, Sendable {
        let e: String
        let t: Int64
    }

    /// The reactions a message holds, by reactor; empty for nil or anything unreadable.
    static func decode(_ json: String?) -> [String: Entry] {
        guard let json, let data = json.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return map
    }

    static func encode(_ map: [String: Entry]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(map), let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    /// A message timestamp (seconds) as the milliseconds a reaction is ordered by.
    static func ms(_ seconds: Double) -> Int64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int64(min(seconds * 1000, 9_007_199_254_740_991).rounded(.down))
    }

    /// apply_reaction (§3): the reactions after `reactor`'s `emoji` at `atMs`, or nil when nothing
    /// changes because the reactor's held one is as new or newer (an older or repeated one). A
    /// newer one replaces it; "" is kept as a removal, so a late older one cannot bring it back.
    static func apply(_ json: String?, reactor: String, emoji: String, atMs: Int64) -> String? {
        var map = decode(json)
        let key = reactor.lowercased()
        if let old = map[key], old.t >= atMs { return nil }
        map[key] = Entry(e: emoji, t: atMs)
        return encode(map)
    }

    /// One chip under a bubble: a reaction, how many hold it, and whether one of them is me.
    struct Chip: Equatable, Identifiable, Sendable {
        let emoji: String
        let count: Int
        let mine: Bool
        var id: String { emoji }
    }

    /// The chips (§3 "Display"): the reactions grouped by non-empty emoji, each counted, in the
    /// order each emoji was first given; highlighted when one of its reactors is in `me` (any
    /// address the user sends that chat as).
    static func chips(_ json: String?, me: Set<String>) -> [Chip] {
        var count: [String: Int] = [:]
        var first: [String: Int64] = [:]
        var mine: Set<String> = []
        for (reactor, entry) in decode(json) where !entry.e.isEmpty {
            count[entry.e, default: 0] += 1
            first[entry.e] = min(first[entry.e] ?? .max, entry.t)
            if me.contains(reactor) { mine.insert(entry.e) }
        }
        return count.keys
            .sorted { (first[$0]!, $0) < (first[$1]!, $1) }
            .map { Chip(emoji: $0, count: count[$0]!, mine: mine.contains($0)) }
    }

    /// The user's own reaction now: the newest held by any address in `me` ("" when the newest is
    /// a removal), nil when none of them reacted.
    static func current(_ json: String?, me: Set<String>) -> String? {
        decode(json).filter { me.contains($0.key) }.max { $0.value.t < $1.value.t }?.value.e
    }

    /// What to send when the user picks `picked` (James, 2026-10-17): one reaction per person per
    /// message, so another one replaces it, and the same one again removes it ("").
    static func toggled(current: String?, picked: String) -> String {
        current == picked ? "" : picked
    }

    /// REACTION_TO for a message (§2, §4), or nil when no reaction is offered on it: in a Group its
    /// post id (16 bytes; nil for a post from an older client, which has none), in a direct chat
    /// its LXMF hash (32 bytes): `lxmfHash`, else the id when it is one (the router's messages and
    /// the user's own sends are filed under their hash).
    static func target(isGroup: Bool, id: String, lxmfHash: String?, postId: String?) -> Data? {
        if isGroup { return postId.flatMap { hexBytes($0, count: 16) } }
        return lxmfHash.flatMap { hexBytes($0, count: 32) } ?? hexBytes(id, count: 32)
    }

    /// `hex` as exactly `count` bytes, or nil.
    static func hexBytes(_ hex: String, count: Int) -> Data? {
        let utf8 = Array(hex.utf8)
        guard utf8.count == 2 * count else { return nil }
        var out = Data(capacity: count)
        var i = 0
        while i < utf8.count {
            guard let hi = nibble(utf8[i]), let lo = nibble(utf8[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x41...0x46: return c - 0x41 + 10
        case 0x61...0x66: return c - 0x61 + 10
        default: return nil
        }
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// A new Group post id (§4): 16 random bytes from SecRandomCopyBytes, 32 lowercase hex. Nil,
    /// for the caller to log, when the system gives no random bytes: the post then goes without
    /// one and offers no reactions, as a post from an older client.
    static func newPostId() -> String? {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return hex(Data(bytes))
    }
}
