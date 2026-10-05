// OutgoingTextTests.swift
//
// The composer on a Mac (Catalyst or "Designed for iPad"), and what every
// send path sends (release 2026-10, "iOS on Mac sends pasted text ending in
// \n"). Return sends there, so the composer watched for a line break at the
// end of the text: any edit leaving one sent the message, and pasting text
// that ended in a line break sent it at once, before the user could look at
// it. Now only a typed Return sends (the edit added exactly one line break,
// at the end); pasted text stays in the field. What is sent has both ends
// trimmed, as Android (OutgoingText.of) and the web send it, the line breaks
// inside kept: DMs, groups and channel posts.
//
// Also the chat list's preview: one line, as the web and Android show it
// (it showed two).
//
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/outgoing-text \
//     Retichat-ios/Retichat/Views/Conversation/OutgoingText.swift \
//     Retichat-ios/tests/OutgoingTextTests.swift && \
//     /private/tmp/claude-501/outgoing-text
//
// OutgoingText runs for real; the SwiftUI wiring is asserted on the source.

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
    let ends = ["\n    func ", "\n    private func ", "\n    // MARK: -", "\n    /// "]
        .compactMap { rest.range(of: $0)?.lowerBound }
    return String(rest[..<(ends.min() ?? rest.endIndex)])
}

func testTheTrim() {
    check(OutgoingText.of("Hello\n") == "Hello", "a trailing line break is not sent")
    check(OutgoingText.of("  \n\tHello \r\n") == "Hello", "both ends are trimmed, CR LF included")
    check(OutgoingText.of("\none\n\ntwo\n  three\n\n") == "one\n\ntwo\n  three", "the line breaks inside are kept")
    check(OutgoingText.of(" \n ").isEmpty, "white space alone is nothing to send")
}

func testReturnIsToldFromAPaste() {
    check(OutgoingText.isTypedReturn(old: "Hello", new: "Hello\n"), "Return typed at the end sends")
    check(OutgoingText.isTypedReturn(old: "", new: "\n"), "Return in an empty field is a typed Return (nothing is sent)")
    check(!OutgoingText.isTypedReturn(old: "", new: "pasted text\n"),
          "text pasted with a trailing line break does not send")
    check(!OutgoingText.isTypedReturn(old: "Note: ", new: "Note: pasted\n"),
          "nor does a paste at the end of what was typed")
    check(OutgoingText.isTypedReturn(old: "pasted text\n", new: "pasted text\n\n"),
          "Return after such a paste sends it")
    check(!OutgoingText.isTypedReturn(old: "ab", new: "a\nb"), "a line break in the middle does not send")
    check(!OutgoingText.isTypedReturn(old: "Hello\n", new: "Hello"), "deleting a line break does not send")
}

func testTheWiring() {
    let view = source("Retichat/Views/Conversation/ConversationView.swift")
    check(view.contains(".onChange(of: messageText) { oldValue, newValue in\n                    guard shouldUseReturnToSendOnMac else { return }")
            && view.contains("guard OutgoingText.isTypedReturn(old: oldValue, new: newValue) else { return }")
            && !view.contains("guard newValue.hasSuffix(\"\\n\") else { return }"),
          "on a Mac only a typed Return sends")
    let send = body(view, "private func sendMessage()")
    check(send.contains("let content = OutgoingText.of(messageText)")
            && send.contains("repository.sendMessage(chatId: id, content: content, attachments: atts)")
            && send.contains("channelClient.sendMessage(content: content, toChannel: ch)"),
          "every send path (DMs, groups, channel posts) sends the trimmed text")
    check(source("Retichat/Services/ChatRepository.swift").contains(
            "func sendMessage(chatId: String, content: String, attachments: [(String, Data)] = []) {\n        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)"),
          "and the repository trims what it is given too")
}

func testThePreviewIsOneLine() {
    let list = source("Retichat/Views/ChatList/ChatListView.swift")
    check(list.contains("Text(chat.lastMessage)\n                        .font(.subheadline)\n                        .foregroundColor(.retichatOnSurfaceVariant)\n                        .lineLimit(1)"),
          "the chat list shows one line of the last message, as the web and Android")
}

@main
struct OutgoingTextTestsMain {
    static func main() {
        testTheTrim()
        testReturnIsToldFromAPaste()
        testTheWiring()
        testThePreviewIsOneLine()
        if failures.isEmpty {
            print("all outgoing text tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
