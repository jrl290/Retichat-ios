// ChannelNameRulesTests.swift
//
// The New Channel form's root rules (James, 2026-09-27). A channel name is
// "<root>.<name>"; public channels use the root "public". A private root was a
// random 8-hex prefix shown read-only, so nobody could join someone else's
// private channel by name (the iPad could not join the phone's
// 4cdc4115.nametest-096499). Now the root is editable, defaults to 16 hex
// characters from the system CSPRNG, and a pasted "root.name" fills both fields.
//
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/channel-name-rules \
//     Retichat-ios/Retichat/Views/NewChat/ChannelNameRules.swift \
//     Retichat-ios/tests/ChannelNameRulesTests.swift && \
//     /private/tmp/claude-501/channel-name-rules
//
// ChannelNameRules runs for real. The form's wiring needs SwiftUI, so it is
// asserted on the source, like NSEChannelPullTests.swift.

import Foundation

nonisolated(unsafe) var failures: [String] = []

func check(_ ok: Bool, _ what: String, _ detail: String = "") {
    if !ok {
        let message = detail.isEmpty ? what : "\(what) — \(detail)"
        failures.append(message)
        print("FAIL: \(message)")
    }
}

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func source(_ path: String) -> String {
    (try? String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

func edit(_ old: String, _ new: String, private isPrivate: Bool, root: String = "0123456789abcdef")
    -> (root: String, name: String)
{
    ChannelNameRules.applyNameEdit(old: old, new: new, isPrivate: isPrivate, root: root)
}

func testTheCharacterRules() {
    check(ChannelNameRules.filterName("News.Tech-2 !") == "news.tech-2",
          "the name part keeps lowercase letters, digits, dots and hyphens",
          ChannelNameRules.filterName("News.Tech-2 !"))
    check(ChannelNameRules.filterRoot("Team.Ops-1 !") == "teamops-1",
          "a root is filtered like the name part, without dots",
          ChannelNameRules.filterRoot("Team.Ops-1 !"))
    check(ChannelNameRules.filterRoot("4CDC4115") == "4cdc4115", "a root is lowercased")

    // The web client (Retichat-js filterChannelChars) lowercases, NFC-normalises
    // and keeps \p{L}\p{N}.- per scalar. The channel hash is over the UTF-8
    // bytes, so iOS must give the same bytes for the same visible name.
    func hex(_ s: String) -> String { s.utf8.map { String(format: "%02x", $0) }.joined() }
    let vectors: [(String, String)] = [          // expected bytes from node
        ("cafe\u{301}", "636166c3a9"),            // NFD e + U+0301 -> U+00E9
        ("q\u{301}x", "7178"),                    // a mark NFC cannot compose is dropped
        ("x\u{b2}", "78c2b2"),                    // superscript two is \p{N}
        ("\u{1c5}a", "c78661"),                   // titlecase letter lowercased
        ("Caf\u{c9}.N\u{e4}me", "636166c3a92e6ec3a46d65"),
        ("a b!c", "616263"),
    ]
    for (input, want) in vectors {
        check(hex(ChannelNameRules.filterName(input)) == want,
              "the name filter gives the web client's bytes for \(input.unicodeScalars.map { String($0.value, radix: 16) })",
              hex(ChannelNameRules.filterName(input)))
    }
    check(hex(ChannelNameRules.filterRoot("Cafe\u{301}.x")) == "636166c3a978",
          "the root filter is NFC too", hex(ChannelNameRules.filterRoot("Cafe\u{301}.x")))
    // SwiftUI may keep an NFD value in the field (String == is canonical
    // equivalence), so the joined name normalises whatever the fields hold.
    check(hex(ChannelNameRules.fullName(isPrivate: true, root: "cafe\u{301}", name: "cafe\u{301}"))
            == "636166c3a92e636166c3a9",
          "the full name is NFC even when the fields are not")
    check(!ChannelNameRules.sameBytes("cafe\u{301}", "caf\u{e9}") && ChannelNameRules.sameBytes("ab", "ab"),
          "sameBytes tells NFD from NFC")
}

func testAPrivatePasteFillsBothFields() {
    let r = edit("", "4cdc4115.nametest-096499", private: true)
    check(r.root == "4cdc4115" && r.name == "nametest-096499",
          "Private: a pasted root.name moves the root out of the name field", "\(r)")

    let upper = edit("", " ABCD.Foo\n", private: true)
    check(upper.root == "abcd" && upper.name == "foo",
          "Private: the pasted root and name are filtered", "\(upper)")

    let deep = edit("", "abc.team.ops", private: true)
    check(deep.root == "abc" && deep.name == "team.ops",
          "Private: only the part before the first dot becomes the root", "\(deep)")

    // The form writes the rest back into the name field, which fires the
    // edit again; it must not split off another segment.
    let back = edit("abc.team.ops", "team.ops", private: true, root: "abc")
    check(back.root == "abc" && back.name == "team.ops",
          "Private: the write-back of the rest is not split again", "\(back)")
    let more = edit("team.ops", "team.opsx", private: true, root: "abc")
    check(more.root == "abc" && more.name == "team.opsx",
          "Private: editing a dotted name part leaves the root alone", "\(more)")

    let over = edit("team.ops", "zz.foo", private: true, root: "abc")
    check(over.root == "zz" && over.name == "foo",
          "Private: a root.name pasted over a dotted name fills both fields", "\(over)")
    let dotMore = edit("team.ops", "team.ops.x", private: true, root: "abc")
    check(dotMore.root == "abc" && dotMore.name == "team.ops.x",
          "Private: another dot typed into a dotted name leaves the root alone", "\(dotMore)")

    // A select-all paste shares its first character, or a tail that holds the
    // dot, with the old name: the inferred edit is smaller than the paste, and
    // it must still split (the field reports no selection).
    let sharedHead = edit("team.ops", "tango.foo", private: true, root: "abc")
    check(sharedHead.root == "tango" && sharedHead.name == "foo",
          "Private: a root.name pasted over a name starting with the same letter fills both fields",
          "\(sharedHead)")
    let sharedTail = edit("news.eu", "c0ffee12.eu", private: true, root: "abc")
    check(sharedTail.root == "c0ffee12" && sharedTail.name == "eu",
          "Private: a root.name pasted over a name ending like it fills both fields", "\(sharedTail)")
    let sharedBoth = edit("4cdc4115.news.eu", "c0ffee12.news.eu", private: true, root: "abc")
    check(sharedBoth.root == "c0ffee12" && sharedBoth.name == "news.eu",
          "Private: a root.name.x pasted over one with the same tail fills both fields", "\(sharedBoth)")

    // Edits that are not pastes over the first segment leave the root alone.
    let later = edit("team.ops", "team.eu.west", private: true, root: "abc")
    check(later.root == "abc" && later.name == "team.eu.west",
          "Private: a paste after the first segment leaves the root alone", "\(later)")
    let keystroke = edit("team.ops", "teams.ops", private: true, root: "abc")
    check(keystroke.root == "abc" && keystroke.name == "teams.ops",
          "Private: typing into the first segment leaves the root alone", "\(keystroke)")
    let backspace = edit("team.ops", "tea.ops", private: true, root: "abc")
    check(backspace.root == "abc" && backspace.name == "tea.ops",
          "Private: deleting from the first segment leaves the root alone", "\(backspace)")
    let atStart = edit("team.ops", "newteam.ops", private: true, root: "abc")
    check(atStart.root == "abc" && atStart.name == "newteam.ops",
          "Private: dotless text pasted at the start leaves the root alone", "\(atStart)")
    let dottedAtStart = edit("team.ops", "x.yteam.ops", private: true, root: "abc")
    check(dottedAtStart.root == "x" && dottedAtStart.name == "yteam.ops",
          "Private: a root. pasted at the start moves into the root", "\(dottedAtStart)")
    let writeBack = edit("c0ffee12.news.eu", "news.eu", private: true, root: "c0ffee12")
    check(writeBack.root == "c0ffee12" && writeBack.name == "news.eu",
          "Private: the write-back after a shared-tail paste is not split again", "\(writeBack)")

    let typed = edit("team", "team.", private: true)
    check(typed.root == "team" && typed.name == "",
          "Private: typing root then a dot moves it into the root", "\(typed)")

    let lead = edit("", ".foo", private: true, root: "keepme")
    check(lead.root == "keepme" && lead.name == "foo",
          "Private: an empty part before the dot keeps the root", "\(lead)")

    let plain = edit("gen", "gene", private: true, root: "keepme")
    check(plain.root == "keepme" && plain.name == "gene",
          "Private: a plain name edit leaves the root alone", "\(plain)")
}

func testAPublicPasteDropsTheDuplicatePrefix() {
    let r = edit("", "public.general", private: false)
    check(r.name == "general", "Public: a pasted public.name drops \"public.\"", "\(r)")
    check(edit("public.general", "general", private: false).name == "general",
          "Public: the write-back is stable")
    let twice = edit("", "public.public.x", private: false)
    check(twice.name == "x", "Public: every leading \"public.\" is dropped", "\(twice)")
    check(edit("public.x", "x", private: false).name == "x", "Public: the write-back is stable")

    // A select-all paste of public.name over a name that already starts with
    // "public." (left there by a Private paste of "abc.public.x", then
    // switching to Public) still drops the duplicate.
    let overDup = edit("public.x", "public.general", private: false)
    check(overDup.name == "general",
          "Public: a pasted public.name over a public.-prefixed name drops \"public.\"",
          "\(overDup)")
    let typedDup = edit("public.", "public.g", private: false)
    check(typedDup.name == "g", "Public: typing after a leading public. drops it", "\(typedDup)")
    let other = edit("", "news.tech", private: false)
    check(other.name == "news.tech" && other.root == "0123456789abcdef",
          "Public: any other x.y stays in the name part", "\(other)")
}

func testTheRootIsValidated() {
    check(ChannelNameRules.rootProblem(isPrivate: true, root: "") != nil,
          "Private: an empty root is refused")
    check(ChannelNameRules.rootProblem(isPrivate: true, root: "public") != nil,
          "Private: the root \"public\" is refused")
    check(ChannelNameRules.rootProblem(isPrivate: true, root: "4cdc4115") == nil,
          "Private: an 8-hex root from an older client is accepted")
    check(ChannelNameRules.rootProblem(isPrivate: true, root: "my-team") == nil,
          "Private: a typed root is accepted")
    check(ChannelNameRules.rootProblem(isPrivate: false, root: "") == nil,
          "Public ignores the private root")

    check(ChannelNameRules.fullName(isPrivate: true, root: "4cdc4115", name: "nametest-096499")
            == "4cdc4115.nametest-096499",
          "Private: the full name is root.name")
    check(ChannelNameRules.fullName(isPrivate: false, root: "4cdc4115", name: "general")
            == "public.general",
          "Public: the full name is public.name")
    check(!ChannelNameRules.canStart(isPrivate: true, root: "", name: "general"),
          "Private: an empty root disables Start")
    check(!ChannelNameRules.canStart(isPrivate: true, root: "public", name: "general"),
          "Private: the root \"public\" disables Start")
    check(!ChannelNameRules.canStart(isPrivate: false, root: "x", name: ""),
          "an empty name disables Start")
    check(ChannelNameRules.canStart(isPrivate: true, root: "4cdc4115", name: "n"),
          "Private: a root and a name enable Start")
}

struct FixedGenerator: RandomNumberGenerator {
    var value: UInt64
    mutating func next() -> UInt64 { value }
}

func testTheDefaultRoot() {
    check(ChannelNameRules.defaultRootHexLength == 16, "the default root is 16 hex characters")
    var seen = Set<String>()
    let hex = Set("0123456789abcdef")
    for _ in 0..<1000 {
        let r = ChannelNameRules.randomRoot()
        check(r.count == 16 && r.allSatisfy { hex.contains($0) },
              "a random root is 16 lowercase hex characters", r)
        seen.insert(r)
    }
    check(seen.count == 1000, "random roots do not repeat", "\(seen.count) distinct of 1000")

    var zero = FixedGenerator(value: 0)
    check(ChannelNameRules.randomRoot(using: &zero) == "0000000000000000",
          "a small value is zero-padded to 16 characters")
    var small = FixedGenerator(value: 0xab)
    check(ChannelNameRules.randomRoot(using: &small) == "00000000000000ab", "padding keeps the value")
    var max = FixedGenerator(value: .max)
    check(ChannelNameRules.randomRoot(using: &max) == "ffffffffffffffff", "all 64 bits are used")

    let rules = source("Retichat/Views/NewChat/ChannelNameRules.swift")
    check(rules.contains("SystemRandomNumberGenerator()"),
          "the default root comes from the system CSPRNG")
}

func testTheFormWiring() {
    let view = source("Retichat/Views/NewChat/NewConversationView.swift")
    check(!view.isEmpty, "NewConversationView.swift is readable")
    check(view.contains("privatePrefix: String = ChannelNameRules.randomRoot()"),
          "the form's default root is ChannelNameRules.randomRoot()")
    check(!view.contains("randomHex()") && !view.contains("count: 4)"),
          "the 8-hex generator is gone")
    check(view.contains("Button(\"Regenerate prefix\") { privatePrefix = ChannelNameRules.randomRoot() }"),
          "Regenerate prefix makes a fresh 16-hex root")
    check(view.contains("TextField(\"prefix\", text: $privatePrefix)"),
          "the private root is an editable field")
    check(view.contains("ChannelNameRules.filterRoot(val)"),
          "the root field is filtered by ChannelNameRules.filterRoot")
    check(view.contains("ChannelNameRules.applyNameEdit("),
          "the name field goes through ChannelNameRules.applyNameEdit")
    check(!view.contains("$0.isLetter || $0.isNumber || $0 == \".\""),
          "the name filter is not duplicated in the view")
    check(view.contains("ChannelNameRules.fullName(isPrivate: isPrivate, root: privatePrefix, name: subdomain)"),
          "the joined name comes from ChannelNameRules.fullName")
    check(view.contains(".disabled(convType == .channel && !channelCanStart)"),
          "Start is disabled while the channel form cannot start")
    check(view.contains("canStart = ChannelNameRules.canStart("),
          "the form reports ChannelNameRules.canStart to the Start button")
    check(view.contains("Only people you share the full name with can join."),
          "the private hint says the full name must be shared")
    check(view.contains("if !ChannelNameRules.sameBytes(edit.name, val) { subdomain = edit.name }")
            && view.contains("if !ChannelNameRules.sameBytes(filtered, val) { privatePrefix = filtered }"),
          "the form writes a filtered value back when its bytes differ, not only when != says so")
    check(!view.contains("Private channel prefix:"),
          "the read-only prefix line is gone")
}

@main
enum ChannelNameRulesTests {
    static func main() {
        testTheCharacterRules()
        testAPrivatePasteFillsBothFields()
        testAPublicPasteDropsTheDuplicatePrefix()
        testTheRootIsValidated()
        testTheDefaultRoot()
        testTheFormWiring()
        if failures.isEmpty {
            print("all channel name rules tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
