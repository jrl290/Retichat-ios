// ExplicitContactsTests.swift
//
// Contacts are explicit (James, 2026-10-02: "Just prevent adding contacts
// that aren't explicitly added. The group and channel member messages are
// only accepted by association."). A contact exists only when the user adds
// one: Add Contact, New Conversation, a QR code or an lxma:// link, all
// through ChatRepository.createDirectChat. Group members get hidden rows
// (allowlisted where the group model allows them, never listed), channel
// posters get none, and a stranger's DM (filter off) or a distro message is
// a conversation with a hidden row, not a contact. Contacts, New Chat and
// the New Group picker list contacts only. Rows already stored stay as they
// were listed (James: no cleanup): a row from before the flag is listed when
// it is allowlisted, as before. Android v0.1.9 (ContactSql, database 12,
// ExplicitContactsTest) is the reference.
//
// Until 2026-10-05 iOS listed every allowlisted row, so every member of a
// group the user created, accepted or was invited to by an allowed inviter
// became a contact, offered in New Chat and the New Group picker.
//
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/explicit-contacts \
//     Retichat-ios/Retichat/Services/ContactRows.swift \
//     Retichat-ios/tests/ExplicitContactsTests.swift && \
//     /private/tmp/claude-501/explicit-contacts
//
// ContactRows runs for real; the writers need SwiftData, so they are
// asserted on the source, like DisplayNamesTests.swift.

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
    let ends = ["\n    func ", "\n    private func ", "\n    @MainActor func ", "\n    // MARK: -", "\n    /// "]
        .compactMap { rest.range(of: $0)?.lowerBound }
    return String(rest[..<(ends.min() ?? rest.endIndex)])
}

func testTheListingRule() {
    check(ContactRows.isListed(isContact: true, isAllowlisted: true), "a contact the user added is listed")
    check(ContactRows.isListed(isContact: true, isAllowlisted: nil), "whatever the filter says about it")
    check(!ContactRows.isListed(isContact: false, isAllowlisted: true),
          "a hidden row is never listed, allowlisted or not (a group member)")
    check(!ContactRows.isListed(isContact: false, isAllowlisted: nil), "a hidden row of a stranger is not listed")
    check(ContactRows.isListed(isContact: nil, isAllowlisted: true),
          "a row from before the flag that was listed (allowlisted) stays a contact: no cleanup")
    check(!ContactRows.isListed(isContact: nil, isAllowlisted: false) && !ContactRows.isListed(isContact: nil, isAllowlisted: nil),
          "a row from before the flag that was not listed stays unlisted")
}

func testTheWriters() {
    let model = source("Retichat/Models/Models.swift")
    check(model.contains("    var isContact: Bool?\n") && model.contains("isAllowlisted: Bool? = nil, isContact: Bool = false)")
            && model.contains("self.isContact = isContact"),
          "ContactEntity.isContact is optional (lightweight migration) and a new row is hidden unless said otherwise")
    let repo = source("Retichat/Services/ChatRepository.swift")
    let add = body(repo, "private func addContact(destHash: String)")
    check(add.contains("contact.isContact = true") && add.contains("contact.isAllowlisted = true")
            && add.contains("ContactEntity(destHash: destHash, isAllowlisted: true, isContact: true)"),
          "addContact makes a listed, allowlisted contact")
    check(repo.components(separatedBy: "addContact(destHash:").count == 3
            && body(repo, "func createDirectChat(").contains("addContact(destHash: normalizedHash)")
            && !body(repo, "func createDirectChat(").contains("ensureAllowlistedContact("),
          "createDirectChat (Add Contact, New Conversation, QR, lxma://) is the one caller of addContact")
    check(repo.components(separatedBy: "isContact = true").count == 2
            && repo.components(separatedBy: "isContact: true").count == 2
            && add.contains("isContact = true") && add.contains("isContact: true"),
          "nothing else writes isContact = true")
    let hidden = body(repo, "private func ensureContact(destHash: String)")
    check(hidden.contains("ContactEntity(destHash: destHash, isContact: false)"),
          "a sender's or recipient's row (a stranger's DM, a distro message) is hidden")
    let allow = body(repo, "private func ensureAllowlistedContact(destHash: String)")
    check(allow.contains("ContactEntity(destHash: destHash, isAllowlisted: true, isContact: false)"),
          "a group member's new row is allowlisted but hidden")
    check(allow.contains("contact.isContact = ContactRows.isListed(isContact: contact.isContact,\n                                                         isAllowlisted: contact.isAllowlisted)\n                contact.isAllowlisted = true"),
          "allowlisting an older unlisted row keeps it unlisted")
    let list = body(repo, "func contacts() -> [Contact]")
    check(list.contains("ContactRows.isListed(isContact: $0.isContact, isAllowlisted: $0.isAllowlisted)")
            && !list.contains("$0.isAllowlisted == true &&"),
          "contacts() lists contacts, not every allowlisted row")
    check(body(repo, "private func handleDistroMessage(").contains("ensureContact(destHash: srcHex)")
            && body(repo, "private func storeIncomingDirect(").contains("ensureContact(destHash: srcHex)")
            && body(repo, "private func handleDistroSentCopy(").contains("ensureContact(destHash: chatId)"),
          "a stranger's DM, a distro message and a sent copy's recipient are conversations with hidden rows")
    check(!source("Retichat/Services/RfedChannelClient.swift").contains("ContactEntity("),
          "a channel poster gets no contact row")
}

func testThePickers() {
    for path in ["Retichat/Views/NewChat/NewChatView.swift", "Retichat/Views/NewChat/NewGroupView.swift",
                 "Retichat/Views/NewChat/NewConversationView.swift"] {
        let view = source(path)
        check(view.contains("repository.contacts()") && !view.contains("repository.chats"),
              "\((path as NSString).lastPathComponent) offers contacts only")
    }
}

@main
struct ExplicitContactsTestsMain {
    static func main() {
        testTheListingRule()
        testTheWriters()
        testThePickers()
        if failures.isEmpty {
            print("all explicit contacts tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
