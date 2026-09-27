// ChannelShareInfoTests.swift
//
// Sharing a channel from its info sheet (James, 2026-09-27). A channel's full
// name ("<root>.<name>") is how it is shared; for a private channel it is the
// invite. The iPad's channel info showed the name only as a non-selectable
// "#name" title, and the only copyable text was the channel hash, which is
// useless for joining. Now the sheet shows the full name selectable and
// untruncated, with the hash as secondary text, a "Copy name" button that
// copies exactly the name, a Share action, and a hint saying who can join.
//
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/channel-share-info \
//     Retichat-ios/Retichat/Views/Channels/ChannelShareInfo.swift \
//     Retichat-ios/tests/ChannelShareInfoTests.swift && \
//     /private/tmp/claude-501/channel-share-info
//
// ChannelShareInfo runs for real. The sheet needs SwiftUI and UIKit, so its
// wiring is asserted on the source, like NSEChannelPullTests.swift.

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

/// `a` appears, and before `b`.
func before(_ text: String, _ a: String, _ b: String) -> Bool {
    guard let ra = text.range(of: a), let rb = text.range(of: b) else { return false }
    return ra.lowerBound < rb.lowerBound
}

// MARK: - The helper

func testShareTextIsExactlyTheFullName() {
    let name = "abd77af5c72e6b5b.general"
    check(ChannelShareInfo.shareText(name) == name, "a stored full name is shared unchanged")
    check(ChannelShareInfo.shareText("#\(name)") == name, "no leading #", ChannelShareInfo.shareText("#\(name)"))
    check(ChannelShareInfo.shareText("  #\(name)\n") == name, "no surrounding whitespace or newline")
    check(ChannelShareInfo.shareText("public.general") == "public.general", "a public name keeps its root")
    let long = "0123456789abcdef.team.eu.west.operations-and-on-call-rotation"
    check(ChannelShareInfo.shareText(long) == long, "a long name is not shortened")
    // The channel hash is over the name's bytes: an NFD name is not recomposed.
    let nfd = "0123456789abcdef.caf" + "e\u{301}"
    check(ChannelShareInfo.shareText(nfd).utf8.elementsEqual(nfd.utf8), "the name's bytes are kept")
}

func testHintSaysWhoCanJoin() {
    let privateHint = "Share the full name to invite someone. Anyone with it can read and post."
    let publicHint = "Anyone who knows the name can join."
    check(ChannelShareInfo.hint("abd77af5c72e6b5b.general") == privateHint, "private hint")
    check(ChannelShareInfo.hint("4cdc4115.nametest-096499") == privateHint, "an 8-hex root is private")
    check(ChannelShareInfo.hint("public.general") == publicHint, "public hint")
    check(ChannelShareInfo.hint("#public.general") == publicHint, "a # does not make it private")
    check(ChannelShareInfo.hint("publicity.news") == privateHint, "only the root \"public\" is public")
    check(ChannelShareInfo.isPublic("public.team.ops"), "public with a dotted name")
    check(!ChannelShareInfo.isPublic("abc.public.news"), "\"public\" later in the name is private")
}

// MARK: - The sheet's wiring (source)

func testSheetShowsTheFullNameSelectable() {
    let view = source("Retichat/Views/Channels/ChannelView.swift")
    check(!view.isEmpty, "ChannelView.swift is readable")
    check(!view.contains("Text(\"#\\(channel.channelName)\")"), "the title is no longer \"#name\"")
    check(view.contains("private var shareName: String { ChannelShareInfo.shareText(channel.channelName) }"),
          "the sheet's name is ChannelShareInfo.shareText")
    // The name Text is selectable and may wrap (not truncated).
    guard let nameText = view.range(of: "Text(shareName)") else {
        check(false, "the header shows Text(shareName)")
        return
    }
    // The modifiers between the name Text and the next Text.
    let afterName = view[nameText.upperBound...]
    let nameModifiers = String(afterName[..<(afterName.range(of: "Text(")?.lowerBound ?? afterName.endIndex)])
    check(nameModifiers.contains(".textSelection(.enabled)"), "the full name is selectable")
    check(nameModifiers.contains(".lineLimit(nil)"), "the full name is not limited to one line")
    check(nameModifiers.contains(".fixedSize(horizontal: false, vertical: true)"), "the full name wraps instead of truncating")
    check(!nameModifiers.contains(".truncationMode"), "the full name has no truncation mode")
    // The hash stays, selectable, after the name.
    check(before(view, "Text(shareName)", "Text(channel.id)"), "the hash is secondary, after the name")
    if let hash = view.range(of: "Text(channel.id)") {
        let hashModifiers = String(view[hash.upperBound...].prefix(300))
        check(hashModifiers.contains(".textSelection(.enabled)"), "the hash stays selectable")
    }
}

func testHintUnderTheName() {
    let view = source("Retichat/Views/Channels/ChannelView.swift")
    check(view.contains("Text(ChannelShareInfo.hint(channel.channelName))"), "the hint is shown")
    check(before(view, "Text(shareName)", "Text(ChannelShareInfo.hint(channel.channelName))"), "the hint is under the name")
}

func testCopyNameAndShare() {
    let view = source("Retichat/Views/Channels/ChannelView.swift")
    check(view.contains("UIPasteboard.general.string = shareName"), "Copy name copies exactly the full name")
    check(!view.contains("UIPasteboard.general.string = channel.id"), "Copy does not copy the hash")
    check(view.contains("copiedName ? \"Copied!\" : \"Copy name\""), "Copy name confirms with Copied!")
    check(view.contains(".task(id: copiedName)") && view.contains("copiedName = false"),
          "the Copied! confirmation goes away")
    check(view.contains("ShareLink(item: shareName)"), "Share hands over exactly the full name")
    check(before(view, "UIPasteboard.general.string = shareName", "ShareLink(item: shareName)"),
          "Copy name comes before Share")
}

@main
enum ChannelShareInfoTests {
    static func main() {
        testShareTextIsExactlyTheFullName()
        testHintSaysWhoCanJoin()
        testSheetShowsTheFullNameSelectable()
        testHintUnderTheName()
        testCopyNameAndShare()
        if failures.isEmpty {
            print("all channel share info tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
