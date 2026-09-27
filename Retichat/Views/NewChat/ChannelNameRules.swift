// ChannelNameRules.swift
//
// The rules of the New Channel form (NewChannelForm in NewConversationView.swift),
// kept Foundation-only so tests/ChannelNameRulesTests.swift runs them with swiftc.
//
// A channel name is "<root>.<name>". Public channels use the root "public".
// A private channel's root is editable: it defaults to 16 random lowercase hex
// characters (64 bits from the system CSPRNG), and anyone can type the root of
// a channel someone shared with them, including the 8-hex roots older clients
// generated. The web and Android clients apply the same rules.

import Foundation

enum ChannelNameRules {

    static let publicRoot = "public"

    /// Hex characters in a freshly generated private root (8 random bytes).
    static let defaultRootHexLength = 16

    // MARK: Characters

    /// The characters the name part may hold: letters and digits (after
    /// lowercasing), "." between segments, and "-".
    static func isNameCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "." || c == "-"
    }

    /// The name part, lowercased, with every other character dropped.
    static func filterName(_ text: String) -> String {
        text.lowercased().filter(isNameCharacter)
    }

    /// A root, filtered like the name part except that "." is not allowed:
    /// the root is everything before the first dot.
    static func filterRoot(_ text: String) -> String {
        text.lowercased().filter { isNameCharacter($0) && $0 != "." }
    }

    // MARK: Name field edits

    /// What an edit of the NAME field leaves in the root and name fields.
    ///
    /// Private: an edit that brings a "." into a name that had none, or pastes
    /// text holding a "." over the start of the name, moves everything before
    /// the first "." into the root and keeps the rest as the name, so a shared
    /// "root.name" can be pasted (or typed) in one go. Other edits of a name
    /// that already holds a "." (the rest of a pasted "root.team.ops") leave it
    /// alone, so editing it does not move another segment into the root, and
    /// the form's own write-back of the rest is not split a second time.
    /// An empty part before the first "." keeps the current root.
    ///
    /// Public: a pasted "public.name" drops the duplicate "public." prefix;
    /// any other "x.y" stays in the name part as typed.
    static func applyNameEdit(old: String, new: String, isPrivate: Bool, root: String)
        -> (root: String, name: String)
    {
        let filtered = filterName(new)
        if isPrivate {
            guard let dot = filtered.firstIndex(of: "."),
                  editSplitsTheRoot(old: filterName(old), new: filtered) else {
                return (root, filtered)
            }
            let head = filterRoot(String(filtered[..<dot]))
            let rest = String(filtered[filtered.index(after: dot)...])
            return (head.isEmpty ? root : head, rest)
        }
        let dup = publicRoot + "."
        if filtered.hasPrefix(dup) && !filterName(old).hasPrefix(dup) {
            return (root, String(filtered.dropFirst(dup.count)))
        }
        return (root, filtered)
    }

    /// Whether a Private name edit moves a root out of the name: the text the
    /// edit inserted holds a ".", and either the old name had none or the edit
    /// replaced its start (a paste over the old value). The same rule as
    /// Retichat-android's ChannelNameForm.onNameInput.
    static func editSplitsTheRoot(old: String, new: String) -> Bool {
        let o = Array(old), n = Array(new)
        var prefix = 0
        while prefix < o.count, prefix < n.count, o[prefix] == n[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < o.count - prefix, suffix < n.count - prefix,
              o[o.count - 1 - suffix] == n[n.count - 1 - suffix] { suffix += 1 }
        let inserted = n[prefix..<(n.count - suffix)]
        return inserted.contains(".") && (!o.contains(".") || prefix == 0)
    }

    // MARK: Validation

    /// Why the root cannot be used, or nil when it can. Public mode always
    /// uses "public".
    static func rootProblem(isPrivate: Bool, root: String) -> String? {
        guard isPrivate else { return nil }
        if root.isEmpty {
            return "Enter a prefix, or regenerate one."
        }
        if root == publicRoot {
            return "\"public\" is the prefix of public channels. Choose Public, or use another prefix."
        }
        return nil
    }

    /// The full channel name, or "" while the form cannot start or join.
    static func fullName(isPrivate: Bool, root: String, name: String) -> String {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, rootProblem(isPrivate: isPrivate, root: root) == nil else { return "" }
        return "\(isPrivate ? root : publicRoot).\(name)"
    }

    static func canStart(isPrivate: Bool, root: String, name: String) -> Bool {
        !fullName(isPrivate: isPrivate, root: root, name: name).isEmpty
    }

    // MARK: Default root

    /// A fresh private root: 16 lowercase hex characters from the system CSPRNG
    /// (SystemRandomNumberGenerator is arc4random_buf on Apple platforms).
    static func randomRoot() -> String {
        var rng = SystemRandomNumberGenerator()
        return randomRoot(using: &rng)
    }

    static func randomRoot<G: RandomNumberGenerator>(using rng: inout G) -> String {
        let v = rng.next()
        let hex = String(v, radix: 16)
        return String(repeating: "0", count: defaultRootHexLength - hex.count) + hex
    }
}
