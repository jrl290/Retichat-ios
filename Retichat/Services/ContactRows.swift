//
//  ContactRows.swift
//  Retichat
//
//  Explicit contacts (James, 2026-10-02). Foundation only, so
//  tests/ExplicitContactsTests.swift runs it for real.
//

import Foundation

/// Which rows are contacts (James, 2026-10-02: "Just prevent adding
/// contacts that aren't explicitly added. The group and channel member
/// messages are only accepted by association."). A contact exists only
/// because the user added it: Add Contact, New Conversation, a QR code or an
/// lxma:// link (ChatRepository.createDirectChat through addContact, the
/// one place a row becomes a contact). Every other row is hidden: it holds what the app
/// learned about a peer (a group member's key, a sender's names) and is
/// listed nowhere.
nonisolated enum ContactRows {
    /// Listed in Contacts, New Chat and the New Group picker. A row from
    /// before the flag (`isContact` nil) is listed as builds before listed
    /// it, when allowlisted: James asked for no cleanup.
    static func isListed(isContact: Bool?, isAllowlisted: Bool?) -> Bool {
        isContact ?? (isAllowlisted == true)
    }
}
