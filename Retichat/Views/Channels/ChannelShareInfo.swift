// ChannelShareInfo.swift
//
// What the channel info sheet (ChannelInfoSheet in ChannelView.swift) shows
// and copies to share a channel (James, 2026-09-27). A channel is shared by
// its full name, "<root>.<name>" (e.g. "abd77af5c72e6b5b.general"); for a
// private channel that name is the invite. The channel hash cannot be used to
// join, so it stays secondary text.
//
// Foundation-only, so tests/ChannelShareInfoTests.swift runs it with swiftc.
// The web and Android clients show the same hints.

import Foundation

enum ChannelShareInfo {

    /// Public channels use this root; every other root is private. Same
    /// literal as ChannelNameRules.publicRoot, which this file does not import
    /// so the test compiles it alone.
    static let publicRoot = "public"

    static let privateHint = "Share the full name to invite someone. Anyone with it can read and post."
    static let publicHint = "Anyone who knows the name can join."

    /// Exactly the text that joins the channel: the stored full name with
    /// surrounding whitespace and any leading "#" (the display decoration
    /// older builds put in front of it) removed. The name's own bytes are left
    /// alone; the channel hash is taken over them.
    static func shareText(_ channelName: String) -> String {
        var name = Substring(channelName.trimmingCharacters(in: .whitespacesAndNewlines))
        while name.hasPrefix("#") { name = name.dropFirst() }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the channel is public: its root is "public".
    static func isPublic(_ channelName: String) -> Bool {
        shareText(channelName).hasPrefix(publicRoot + ".")
    }

    /// The one-line hint under the name.
    static func hint(_ channelName: String) -> String {
        isPublic(channelName) ? publicHint : privateHint
    }
}
