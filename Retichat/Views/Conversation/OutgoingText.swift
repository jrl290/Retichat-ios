//
//  OutgoingText.swift
//  Retichat
//
//  What the message composer sends, and when Return sends it on a Mac.
//  Foundation only, so tests/OutgoingTextTests.swift runs it for real.
//

import Foundation

nonisolated enum OutgoingText {
    /// A message's text as it is sent: both ends trimmed, as Android
    /// (OutgoingText.of) and the web (Retichat-js sendMessage) send it, so a
    /// line break typed or pasted by accident at either end never reaches
    /// the other side. The line breaks inside are sent as typed. DMs, groups
    /// and channel posts (ConversationView.sendMessage).
    static func of(_ typed: String) -> String {
        typed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// On a Mac (Catalyst or "Designed for iPad"), Return in the composer
    /// sends, Shift-Return makes a new line. Return is told from a paste by
    /// what the edit did: a typed Return adds exactly one line break, at the
    /// end. A paste adds its text at once, so text pasted with a trailing
    /// line break stays in the field, to be edited and sent with Return or
    /// the send button. Until 2026-10-05 any edit leaving a line break at
    /// the end sent the message, so pasting such text sent it at once.
    static func isTypedReturn(old: String, new: String) -> Bool {
        new == old + "\n"
    }
}
