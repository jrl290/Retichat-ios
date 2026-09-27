// ChannelNameRules.swift
//
// The rules of the New Channel form (NewChannelForm in NewConversationView.swift),
// kept Foundation-only so tests/ChannelNameRulesTests.swift runs them with swiftc.
//
// A channel name is "<root>.<name>". Public channels use the root "public".
// A private channel's root is editable: it defaults to 16 random lowercase hex
// characters (64 bits from the system CSPRNG), and anyone can type the root of
// a channel someone shared with them, including the 8-hex roots older clients
// generated. The web and Android clients apply the same rules; the character
// rule (lowercase, NFC, Unicode L*/N* plus "." and "-") is the web client's
// filterChannelChars byte for byte.

import Foundation

enum ChannelNameRules {

    static let publicRoot = "public"

    /// Hex characters in a freshly generated private root (8 random bytes).
    static let defaultRootHexLength = 16

    // MARK: Characters

    /// The characters the name part may hold: letters and digits (Unicode
    /// general categories L* and N*, after lowercasing), "." between segments,
    /// and "-". Checked per Unicode scalar, like Retichat-js's
    /// filterChannelChars (`[^\p{L}\p{N}.-]`), so a combining mark that NFC
    /// cannot compose is dropped on both clients.
    static func isNameScalar(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return s == "." || s == "-"
        }
    }

    /// Lowercased, then NFC, then filtered: the web client's order. NFC matters
    /// because the channel hash is taken over the name's UTF-8 bytes, and a
    /// decomposed "e\u{301}" (which the clipboard can carry) would otherwise
    /// name a different channel than the "\u{e9}" the web client produces.
    private static func filtered(_ text: String, keep: (Unicode.Scalar) -> Bool) -> String {
        var out = String.UnicodeScalarView()
        out.append(contentsOf: text.lowercased().precomposedStringWithCanonicalMapping
            .unicodeScalars.filter(keep))
        return String(out)
    }

    /// The name part, lowercased and NFC, with every other character dropped.
    static func filterName(_ text: String) -> String {
        filtered(text, keep: isNameScalar)
    }

    /// A root, filtered like the name part except that "." is not allowed:
    /// the root is everything before the first dot.
    static func filterRoot(_ text: String) -> String {
        filtered(text) { isNameScalar($0) && $0 != "." }
    }

    /// Byte equality. Swift's String == is canonical equivalence, so an NFD
    /// field compares equal to its NFC filter; the form uses this to decide
    /// whether to write the filtered value back.
    static func sameBytes(_ a: String, _ b: String) -> Bool {
        a.utf8.elementsEqual(b.utf8)
    }

    // MARK: Name field edits

    /// What an edit of the NAME field leaves in the root and name fields.
    ///
    /// Private: an edit that brings a "." into a name that had none, or pastes
    /// over the start of a dotted name (see editSplitsTheRoot), moves
    /// everything before the first "." into the root and keeps the rest as the
    /// name, so a shared "root.name" can be pasted (or typed) in one go. Other
    /// edits of a name that already holds a "." (the rest of a pasted
    /// "root.team.ops") leave it alone, so editing it does not move another
    /// segment into the root, and the form's own write-back of the rest is not
    /// split a second time. An empty part before the first "." keeps the
    /// current root.
    ///
    /// Public: a leading "public." is always dropped (the root is already
    /// "public"), as Retichat-android's ChannelNameForm.onNameInput does; any
    /// other "x.y" stays in the name part as typed.
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
        // Every leading "public.": the form writes the result back into the
        // field, which runs this again, so stripping them all here gives the
        // same answer as stripping one per pass, in one step.
        let dup = publicRoot + "."
        var name = Substring(filtered)
        while name.hasPrefix(dup) { name = name.dropFirst(dup.count) }
        return (root, String(name))
    }

    /// Whether a Private name edit moves a root out of the name.
    ///
    /// The field gives only the text before and after the edit, not the
    /// selection it replaced, so the edited range is inferred: the longest
    /// common prefix and suffix are taken as kept. A select-all paste whose
    /// text happens to start or end like the old name ("tango.foo" over
    /// "team.ops", "c0ffee12.eu" over "news.eu") shows up as a smaller edit,
    /// so the rule for a dotted old name does not ask whether the inferred
    /// insertion holds the ".":
    ///
    ///   - Old name without a ".": the edit split iff it inserted one.
    ///   - Pure insertion before the whole old name: split iff the inserted
    ///     text holds a "." ("x.y" pasted at the start).
    ///   - The edit starts after the old first "." (the old first segment and
    ///     its dot are kept): never split. Editing "team.ops" into
    ///     "team.eu.west" leaves the root alone.
    ///   - Otherwise the edit rewrote the old first segment or its dot: split
    ///     iff it inserted two or more characters (a paste, not a keystroke or
    ///     a deletion). A paste over just the first segment ("squad" over the
    ///     "team" of "team.ops") therefore also splits; without the selection
    ///     it cannot be told from a select-all paste of "squad.ops".
    ///
    /// Android's onNameInput takes the selection and needs none of this; the
    /// iOS 17 TextField does not report one.
    static func editSplitsTheRoot(old: String, new: String) -> Bool {
        let o = Array(old), n = Array(new)
        var prefix = 0
        while prefix < o.count, prefix < n.count, o[prefix] == n[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < o.count - prefix, suffix < n.count - prefix,
              o[o.count - 1 - suffix] == n[n.count - 1 - suffix] { suffix += 1 }
        let inserted = n[prefix..<(n.count - suffix)]
        guard let oldDot = o.firstIndex(of: ".") else { return inserted.contains(".") }
        if suffix == o.count { return inserted.contains(".") }
        if prefix > oldDot { return false }
        return inserted.count >= 2
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
    /// NFC, whatever the fields hold: the channel hash is over these bytes.
    static func fullName(isPrivate: Bool, root: String, name: String) -> String {
        let name = name.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping
        let root = root.precomposedStringWithCanonicalMapping
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
