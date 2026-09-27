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
    check(twice.name == "public.x", "Public: only one \"public.\" is dropped", "\(twice)")
    check(edit("public.public.x", "public.x", private: false).name == "public.x",
          "Public: the write-back of public.x is not stripped again")
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
