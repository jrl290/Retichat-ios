// PlaceholderVectorsTests.swift
//
// DISPLAY_NAMES.md §5.4 (added 2026-09-30), with §3's white space: the old
// web node defaults ("Retichat Web (" + anything + ")") and the old web
// announce suffix (" (" + the first 12 hex of the contact's own hash + ")")
// are placeholders. Pinned by the shared vectors that LXMF-rust, Retichat-js
// and Android run (LXMF-rust/tests/display_name_vectors.json, sections
// placeholder and own_hash_suffix), loaded here; a missing file fails.
//
// iOS keeps one rule for every stored name (any of them may have been
// typed): a hash form counts only when it prefixes the contact's own hash,
// but an old web node default is a placeholder everywhere, and a name that
// carried the suffix came from an announce, so what is left is judged as a
// name that was not typed. Every received announce name loses the suffix
// (handleAnnounce, the announce cache, the NSE's title), the first
// migration applies the rules, and a one-off second pass fixes the names
// already stored by devices that migrated before (as Android's database 12).
//
// Until 2026-10-05 iOS trimmed with .whitespacesAndNewlines (which also
// takes U+200B), kept "Retichat Web (retichat)" or "Alice (0123456789ab)"
// as a typed localName that led the contact's label for good, and stored
// announce names with the suffix.
//
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/placeholder-vectors \
//     Retichat-ios/Retichat/Bridge/LxmfFields.swift \
//     Retichat-ios/tests/PlaceholderVectorsTests.swift && \
//     /private/tmp/claude-501/placeholder-vectors

import Foundation

nonisolated(unsafe) var failures: [String] = []

func check(_ ok: Bool, _ what: String) {
    if ok {
        print("ok    - \(what)")
    } else {
        failures.append(what)
        print("FAIL  - \(what)")
    }
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func source(_ path: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

func body(_ text: String, _ signature: String) -> String {
    guard let start = text.range(of: signature) else { return "" }
    let rest = text[start.upperBound...]
    let ends = ["\n    func ", "\n    private func ", "\n    @MainActor func ", "\n    static func ",
                "\n    // MARK: -", "\n    /// "]
        .compactMap { rest.range(of: $0)?.lowerBound }
    return String(rest[..<(ends.min() ?? rest.endIndex)])
}

/// The shared vectors, from the LXMF-rust checkout next to this one.
func section(_ key: String) -> [[String: Any]] {
    let file = root.deletingLastPathComponent().appendingPathComponent("LXMF-rust/tests/display_name_vectors.json")
    guard let data = try? Data(contentsOf: file),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let list = json[key] as? [[String: Any]] else {
        check(false, "shared vectors section \(key) at \(file.path)")
        return []
    }
    check(list.count >= 20, "section \(key) holds its vectors (\(list.count))")
    return list
}

/// A hash form (8 to 32 hex, optional "?" before and "…" after), §3 white
/// space trimmed: the one placeholder that depends on whether a name may
/// have been typed.
func isHashForm(_ s: String) -> Bool {
    var v = Substring(DisplayNames.trimWhiteSpace(s).lowercased())
    if v.hasPrefix("?") { v = v.dropFirst() }
    if v.hasSuffix("\u{2026}") { v = v.dropLast() }
    return (8...32).contains(v.count) && v.allSatisfy { $0.isASCII && $0.isHexDigit }
}

func testThePlaceholderVectors() {
    for v in section("placeholder") {
        guard let input = v["input"] as? String, let own = v["own_hash"] as? String,
              let placeholder = v["placeholder"] as? Bool, let webDefault = v["web_node_default"] as? Bool else {
            check(false, "a well-formed placeholder vector: \(v)"); continue
        }
        let what = "\(v["name"] ?? "?"): \(input.debugDescription)"
        check(DisplayNames.isPlaceholder(input, ownHash: own, typed: false) == placeholder, "placeholder, not typed — \(what)")
        check(DisplayNames.isWebNodeDefault(input) == webDefault, "web node default — \(what)")
        // Where a name may have been typed (every iOS name), a hash form
        // counts only when it prefixes the contact's own hash (§5.4).
        let ownPrefix = { () -> Bool in
            var t = Substring(DisplayNames.trimWhiteSpace(input).lowercased())
            if t.hasPrefix("?") { t = t.dropFirst() }
            if t.hasSuffix("\u{2026}") { t = t.dropLast() }
            return own.lowercased().hasPrefix(String(t))
        }()
        let typed = placeholder && !(isHashForm(input) && !webDefault && !ownPrefix)
        check(DisplayNames.isPlaceholder(input, ownHash: own) == typed, "placeholder, typed — \(what)")
    }
}

func testTheOwnHashSuffixVectors() {
    for v in section("own_hash_suffix") {
        guard let input = v["input"] as? String, let own = v["own_hash"] as? String,
              let expected = v["expected"] as? String else {
            check(false, "a well-formed suffix vector: \(v)"); continue
        }
        let got = DisplayNames.stripOwnHashSuffix(input, ownHash: own)
        check(got == expected, "\(v["name"] ?? "?"): \(input.debugDescription) -> \(got.debugDescription)")
    }
}

func testWhiteSpaceIsSection3s() {
    check(DisplayNames.trimWhiteSpace("\u{0085}\t Alice\u{3000}\u{2028}") == "Alice", "§3 white space is trimmed")
    check(DisplayNames.trimWhiteSpace("\u{200B}Alice\u{FEFF}") == "\u{200B}Alice\u{FEFF}",
          "U+200B and U+FEFF are not white space (Foundation's set would take U+200B)")
    check(DisplayNames.trimWhiteSpace(" \n\t ") == "", "all white space trims to nothing")
}

let alice = "0123456789abcdef0123456789abcdef"

func testTheFirstMigration() {
    func m(_ v: String, recalled: String? = nil) -> DisplayNames.LegacyName {
        DisplayNames.migrateLegacyName(v, hash: alice, recalledAnnounceName: recalled)
    }
    check(m("Retichat Web (retichat)") == .drop && m("Retichat Web (selectiv) (0123456789ab)") == .drop,
          "an old web node default is dropped, typed or not")
    check(m("Alice (0123456789ab)") == .localName("Alice"),
          "a name with the old web announce suffix loses it")
    check(m("Alice (0123456789ab)", recalled: "Alice (0123456789ab)") == .announceName("Alice"),
          "and is compared with the recalled announce name without it")
    check(m("Retichat (0123456789ab)") == .drop && m("deadbeef (0123456789ab)") == .drop,
          "what is left of an announced name is judged as not typed: a placeholder is dropped")
    check(m("deadbeef") == .localName("deadbeef") && m("Bob (work)") == .localName("Bob (work)")
            && m("Alice (fedcba987654)") == .localName("Alice (fedcba987654)"),
          "a name that may have been typed is kept")
    check(m("Retichat\n") == .drop && m("\u{3000}Alice ") == .localName("Alice"), "§3 white space")
}

func testTheSecondPass() {
    func local(_ v: String?) -> String? { DisplayNames.remigratedName(v, ownHash: alice, isLocalName: true) }
    func announce(_ v: String?) -> String? { DisplayNames.remigratedName(v, ownHash: alice, isLocalName: false) }
    check(local("Retichat Web (retichat)") == nil && local(" Retichat Web (selectiv)\t") == nil,
          "a localName that is an old web node default is dropped")
    check(local("Alice (0123456789ab)") == "Alice" && announce("Alice (0123456789AB)") == "Alice",
          "a localName or announceName loses the old web announce suffix")
    check(local("Retichat (0123456789ab)") == nil && announce("Retichat Web (retichat) (0123456789ab)") == nil
            && announce("0123abcd (0123456789ab)") == nil,
          "what is left came from an announce: dropped when a placeholder of a name not typed")
    check(local("Alice") == "Alice" && local("deadbeef") == "deadbeef" && local("Bob (work)") == "Bob (work)"
            && local(nil) == nil && announce("Alice (fedcba987654)") == "Alice (fedcba987654)",
          "anything else is left as it is")
    check(announce("Retichat Web (retichat)") == "Retichat Web (retichat)",
          "an announceName without the suffix is the announce's, replaced by the next one (as Android)")
}

func testTheWiring() {
    let repo = source("Retichat/Services/ChatRepository.swift")
    let announce = body(repo, "private func handleAnnounce(")
    check(announce.contains("displayName.map { DisplayNames.stripOwnHashSuffix($0, ownHash: hex) }"),
          "every received announce name loses the old web announce suffix")
    check(body(repo, "private func refreshAnnounceNameFromCache(").contains(".map { DisplayNames.stripOwnHashSuffix($0, ownHash: destHash) }"),
          "so does the announce cache's")
    let pass = body(repo, "private func remigrateContactNamesIfNeeded(")
    check(pass.contains("guard !prefs.contactNamesPlaceholderPass") && pass.contains("prefs.contactNamesPlaceholderPass = true")
            && pass.contains("DisplayNames.remigratedName(contact.localName, ownHash: contact.destHash, isLocalName: true)")
            && pass.contains("DisplayNames.remigratedName(contact.announceName, ownHash: contact.destHash,"),
          "the second pass runs once, over localName and announceName")
    check(body(repo, "func configure(modelContext: ModelContext)").contains("remigrateContactNamesIfNeeded()"),
          "when the store is configured")
    let fields = source("Retichat/Bridge/LxmfFields.swift")
    check(body(fields, "static func notificationName(").contains("announceName.map { stripOwnHashSuffix($0, ownHash: hash) }"),
          "the NSE's title loses it from the recalled announce name")
    check(!body(fields, "static func isPlaceholder(").contains("whitespacesAndNewlines")
            && !body(fields, "static func migrateLegacyName(").contains("whitespacesAndNewlines"),
          "stored names are trimmed with §3's white space, never Foundation's")
    check(source("Retichat/Services/UserPreferences.swift").contains("static let contactNamesPlaceholderPass = \"contact_names_placeholder_pass_v1\""),
          "the pass has its own persisted flag")
}

@main
struct PlaceholderVectorsTestsMain {
    static func main() {
        testThePlaceholderVectors()
        testTheOwnHashSuffixVectors()
        testWhiteSpaceIsSection3s()
        testTheFirstMigration()
        testTheSecondPass()
        testTheWiring()
        if failures.isEmpty {
            print("all placeholder vector tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
