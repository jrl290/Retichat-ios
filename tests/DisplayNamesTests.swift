// DisplayNamesTests.swift
//
// Display names on iOS (LXMF-rust/DISPLAY_NAMES.md, agreed 2026-09-27): the
// rules the app applies to the names the Rust side cleans and decodes, the
// settings migration, and the wiring on every path that yields a message,
// every surface that shows a name, and the NSE. Until then iOS read field
// 0x10 only as msgpack str while every native sender wrote bin (audit H2),
// kept one name slot that the first name seen filled for good, froze names
// into system messages, and labelled channel posters and NSE titles by hash.
//
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/display-names \
//     Retichat-ios/Retichat/Bridge/LxmfFields.swift \
//     Retichat-ios/Retichat/Services/UserPreferences.swift \
//     Retichat-ios/tests/DisplayNamesTests.swift && \
//     /private/tmp/claude-501/display-names
//
// DisplayNames (in LxmfFields.swift, compiled into the app and the NSE) runs
// for real, and the digest is checked against the vectors the Rust suite
// runs (LXMF-rust/tests/display_name_vectors.json). Cleaning and decoding
// 0xD1 are Rust's and tested there. The wiring needs SwiftData, UIKit and
// the FFI, so it is asserted on the source, like NSEChannelPullTests.swift.

import Foundation

// UserPreferences.swift uses the app's Data hex helpers
// (PropagationNodeManager.swift), which need the whole app; the same two here.
extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var out = Data()
        var i = hexString.startIndex
        while i < hexString.endIndex {
            let j = hexString.index(i, offsetBy: 2)
            guard let b = UInt8(hexString[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        self = out
    }
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

nonisolated(unsafe) var failures: [String] = []

func check(_ ok: Bool, _ what: String, _ detail: String = "") {
    if !ok {
        let message = detail.isEmpty ? what : "\(what) — \(detail)"
        failures.append(message)
        print("FAIL: \(message)")
    }
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let workspace = root.deletingLastPathComponent()

func source(_ path: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

/// `a` appears, and before `b`.
func before(_ text: String, _ a: String, _ b: String) -> Bool {
    guard let ra = text.range(of: a), let rb = text.range(of: b) else { return false }
    return ra.lowerBound < rb.lowerBound
}

/// The body of `func name` in `text`, up to the next "\n    func " or
/// "\n    private func " at the same depth (enough for these files).
func body(_ text: String, _ signature: String) -> String {
    guard let start = text.range(of: signature) else { return "" }
    let rest = text[start.upperBound...]
    let ends = ["\n    func ", "\n    private func ", "\n    @MainActor func ", "\n    // MARK: -"]
        .compactMap { rest.range(of: $0)?.lowerBound }
    return String(rest[..<(ends.min() ?? rest.endIndex)])
}

let alice = "1a2b3c4d5e6f708192a3b4c5d6e7f801"

// MARK: - Decoding (§2.1, §3)

func testTheNameStateBufferParses() {
    check(DisplayNames.parseNameState(Data([0, 0, 0])) == .absent, "state 0 is absent")
    check(DisplayNames.parseNameState(Data([1, 0, 0])) == .clear, "state 1 is a clear")
    let name = Data("Zoë".utf8)
    check(DisplayNames.parseNameState(Data([2, 0, UInt8(name.count)]) + name) == .name("Zoë"),
          "state 2 carries the UTF-8 name, length u16 big-endian")
    check(DisplayNames.parseNameState(Data([2, 0, 9]) + name) == nil, "a name running past the buffer is malformed")
    check(DisplayNames.parseNameState(Data([2, 0, 0])) == nil, "state 2 without a name is malformed")
    check(DisplayNames.parseNameState(Data([2, 0, 1, 0xFF])) == nil, "a name that is not UTF-8 is malformed")
    check(DisplayNames.parseNameState(Data([7, 0, 0])) == nil, "an unknown state is malformed")
    check(DisplayNames.parseNameState(Data([0, 0])) == nil, "a short buffer is malformed")
}

/// {0x10: bin "Alice", 0xA0: str "g"} as lxmf_message_add_field writes keys.
func testTheRetiredFieldNoLongerStopsTheParse() {
    var map = Data([0x82, 0x10, 0xC4, 0x05]) + Data("Alice".utf8)
    map += Data([0xCC, 0xA0, 0xA1]) + Data("g".utf8)
    let fields = LxmfFieldsDecoder.decode(map)
    check(fields.groupId == "g",
          "a bin value at 0x10 is skipped and the fields after it still decode (audit H2)")
    let lxmf = source("Retichat/Bridge/LxmfFields.swift")
    check(!lxmf.contains("senderName"), "0x10 is neither a field key nor a decoded field any more (§2.1)")
}

// MARK: - Accepting 0xD1 (§5.2)

func testTheAcceptTable() {
    typealias C = DisplayNames.Change
    func accept(_ f: DisplayNames.NameField, _ reason: Int, _ current: String?) -> C {
        DisplayNames.acceptMessageName(f, unverifiedReason: reason, current: current)
    }
    check(accept(.name("Alice"), 0, nil) == .set("Alice"), "validated name: set")
    check(accept(.name("Alice"), 0, "Old") == .set("Alice"), "validated name: replaces the one held")
    check(accept(.name("Alice"), 0, "Alice") == .keep, "validated same name: nothing to write")
    check(accept(.clear, 0, "Alice") == .set(nil), "validated clear: messageName = none")
    check(accept(.clear, 0, nil) == .keep, "validated clear with nothing held: nothing to write")
    check(accept(.name("Alice"), 1, nil) == .set("Alice"), "source unknown: set only if none is held")
    check(accept(.name("Mallory"), 1, "Alice") == .keep, "source unknown: never replaces a name")
    check(accept(.clear, 1, "Alice") == .keep, "source unknown: a clear is ignored")
    check(accept(.name("Mallory"), 2, nil) == .keep, "invalid signature: a name is ignored")
    check(accept(.clear, 2, "Alice") == .keep, "invalid signature: a clear is ignored")
    check(accept(.absent, 0, "Alice") == .keep, "no 0xD1: nothing changes")
    check(accept(.name("X"), 7, nil) == .keep, "an unknown reason counts as invalid")
}

// MARK: - Resolving (§5.3)

func testTheResolver() {
    check(DisplayNames.shortHash("1A2B3C4D5E6F") == "1a2b3c4d\u{2026}", "shortHash: 8 hex and an ellipsis, lowercase")
    check(DisplayNames.contactLabel(hash: alice, local: "Mum", message: "Alice", announce: "A.") == "Mum",
          "localName first")
    check(DisplayNames.contactLabel(hash: alice, local: nil, message: "Alice", announce: "A.") == "Alice",
          "then messageName")
    check(DisplayNames.contactLabel(hash: alice, local: "", message: nil, announce: "A.") == "A.",
          "then announceName; an empty slot is no name")
    check(DisplayNames.contactLabel(hash: alice, local: nil, message: nil, announce: nil) == "1a2b3c4d\u{2026}",
          "then the short hash")
    check(DisplayNames.contactName(local: nil, message: nil, announce: nil) == nil, "no slot, no name")

    let fromChannel = DisplayNames.channelLabel(hash: alice, channelName: "Wizard", contactName: "Alice")
    check(fromChannel == .init(label: "Wizard", secondary: "1a2b3c4d"),
          "channelName first, with the 8-hex hash beside it")
    check(DisplayNames.channelLabel(hash: alice, channelName: nil, contactName: "Alice")
            == .init(label: "Alice", secondary: nil), "then the contact's name, no hash")
    check(DisplayNames.channelLabel(hash: alice, channelName: "", contactName: nil)
            == .init(label: "1a2b3c4d\u{2026}", secondary: nil), "then the short hash")
    check(DisplayNames.channelNotificationTitle(channelName: "public.general", label: fromChannel)
            == "#public.general (Wizard \u{00B7} 1a2b3c4d)", "a channel-name notification shows the hash too")
    check(DisplayNames.channelNotificationTitle(channelName: "public.general",
                                                label: .init(label: "Alice", secondary: nil))
            == "#public.general (Alice)", "a contact-named one does not")

    check(DisplayNames.channelName(afterPost: .name("New"), stored: "Old") == "New", "a post's name replaces")
    check(DisplayNames.channelName(afterPost: .clear, stored: "Old") == nil, "a post's clear clears")
    check(DisplayNames.channelName(afterPost: .absent, stored: "Old") == "Old", "a post without 0xD1 keeps it")

    let token = DisplayNames.subjectToken
    check(DisplayNames.systemText("\(token) joined the group", subject: "Alice") == "Alice joined the group",
          "a system message is named when shown")
    check(DisplayNames.systemText("hello", subject: "Alice") == "hello", "other text is untouched")
}

func testTheNotificationServiceTitle() {
    func title(app: String?, _ field: DisplayNames.NameField, _ reason: Int, announce: String?) -> String {
        DisplayNames.notificationName(hash: alice, appName: app, messageName: field,
                                      unverifiedReason: reason, announceName: announce)
    }
    check(title(app: "Mum", .name("Alice"), 0, announce: "A.") == "Mum", "the app's resolved name first")
    check(title(app: nil, .name("Alice"), 0, announce: "A.") == "Alice", "then the message's validated name")
    check(title(app: nil, .name("Alice"), 1, announce: nil) == "Alice", "a first name from an unknown source")
    check(title(app: nil, .name("Mallory"), 2, announce: "A.") == "A.", "never an invalid message's name")
    check(title(app: nil, .absent, 0, announce: nil) == "1a2b3c4d\u{2026}", "then the short hash")
}

// MARK: - Channel posts (§4.2)

func testTheChannelRule() {
    let day = DisplayNames.channelNameRefreshSecs
    let now = 1_800_000_000.0
    let d = DisplayNames.digest("Alice")
    func post(_ name: String?, _ last: Data?, _ at: Double?, newSender: Bool = false, now t: Double = now)
        -> DisplayNames.NameField {
        DisplayNames.channelPostName(current: name, lastDigest: last, lastIncludedAt: at,
                                     newSenderSinceIncluded: newSender, now: t)
    }
    check(day == 86_400, "CHANNEL_NAME_REFRESH_SECS is 24 hours")
    check(post("Alice", nil, nil) == .name("Alice"), "the first post carries the name")
    check(post("Alice", DisplayNames.digest("Old"), now - 10) == .name("Alice"), "a changed name goes out")
    check(post("Alice", d, now - 10) == .absent, "an unchanged name recently sent stays out")
    check(post("Alice", d, now - 10, newSender: true) == .name("Alice"), "a new sender since brings it back")
    check(post("Alice", d, now - day) == .absent, "exactly 24 hours is not more than 24 hours")
    check(post("Alice", d, now - day - 1) == .name("Alice"), "after 24 hours it is refreshed")
    check(post(nil, d, now - 10) == .clear, "unset after a real name: clear once")
    check(post(nil, DisplayNames.digest(nil), now - 10) == .absent, "and only once")
    check(post(nil, nil, nil) == .absent, "never named: nothing")
    check(post("", d, now - 10) == .clear, "an empty name is unset")
}

func testTheDigestMatchesTheRustVectors() {
    let url = workspace.appendingPathComponent("LXMF-rust/tests/display_name_vectors.json")
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let vectors = json["digest"] as? [[String: Any]], !vectors.isEmpty else {
        check(false, "the shared vectors load", url.path)
        return
    }
    for v in vectors {
        guard let input = v["input"] as? String, let hex = v["digest_hex"] as? String else { continue }
        let got = DisplayNames.digest(input.isEmpty ? nil : input).hexString
        check(got == hex, "digest \(v["name"] ?? "?") matches lxmf_rust::display_name::digest", got)
    }
}

// MARK: - Distro unwrap

func testTheDistroUnwrapKeys() {
    check(DisplayNames.distroNameField(state: 2, name: "Alice") == .name("Alice"), "state 2 is the name")
    check(DisplayNames.distroNameField(state: 1, name: nil) == .clear, "state 1 is a clear")
    check(DisplayNames.distroNameField(state: 0, name: "x") == .absent, "state 0 is absent")
    check(DisplayNames.distroNameField(state: nil, name: nil) == .absent, "an older FFI (no keys) names nobody")
    check(DisplayNames.distroNameField(state: 2, name: nil) == .absent, "state 2 without a name is absent")
    check(DisplayNames.distroReason(validated: true, unverifiedReason: 1) == 0, "validated is reason 0")
    check(DisplayNames.distroReason(validated: false, unverifiedReason: 1) == 1, "source unknown kept")
    check(DisplayNames.distroReason(validated: false, unverifiedReason: nil) == 2,
          "not validated without a reason is invalid")
    check(DisplayNames.distroReason(validated: nil, unverifiedReason: nil) == 2, "no keys at all is invalid")
}

// MARK: - Migration (§5.4)

func testTheContactMigration() {
    func m(_ v: String, recalled: String? = nil) -> DisplayNames.LegacyName {
        DisplayNames.migrateLegacyName(v, hash: alice, recalledAnnounceName: recalled)
    }
    check(m("1a2b3c4d\u{2026}") == .drop, "the 8-hex placeholder is dropped")
    check(m("1a2b3c4d5e6f7081\u{2026}") == .drop, "the 16-hex picker placeholder is dropped")
    check(m("1A2B3C4D...") == .drop, "any case, three dots")
    check(m(alice) == .drop, "the whole hash is dropped")
    check(m("   ") == .drop, "an empty name is dropped")
    check(m("Anonymous Peer") == .drop, "MeshChatX's and Columba's placeholder is dropped")
    check(m("deadbeef\u{2026}") == .localName("deadbeef\u{2026}"), "another hash's prefix is a typed name")
    check(m("Alice", recalled: "Alice") == .announceName("Alice"), "equal to the recalled announce name")
    check(m("Mum", recalled: "Alice") == .localName("Mum"), "anything else was typed: localName")
    check(m("Cafe", recalled: nil) == .localName("Cafe"), "no recalled name: localName")
}

func testTheContactMigrationWiring() {
    let repo = source("Retichat/Services/ChatRepository.swift")
    let migrate = body(repo, "private func migrateLegacyContactNamesIfNeeded(")
    check(migrate.contains("guard !prefs.contactNamesMigrated") && migrate.contains("self.prefs.contactNamesMigrated = true"),
          "the contact migration runs once, guarded by a persisted flag")
    check(before(migrate, "ffiQueue.async", "client.recallDisplayName(for: data)"),
          "its announce-name recalls run off the main thread")
    check(migrate.contains("if contact.localName == nil { contact.localName = name")
            && migrate.contains("if contact.announceName == nil { contact.announceName = name"),
          "a slot filled since is never overwritten")
    check(migrate.contains("LxmfClient.cleanDisplayName(value)"), "old names are cleaned as saved names are")
    check(body(repo, "private func finishStartService(").contains("migrateLegacyContactNamesIfNeeded(client: client)"),
          "it runs when the stack is up (the recall needs it)")
    check(body(repo, "private func resolvedName(").contains("if !prefs.contactNamesMigrated, !DisplayNames.isPlaceholder("),
          "until then an old non-placeholder name is still shown")
}

func testTheSettingsMigration() {
    let suite = "display-names-test-\(UUID().uuidString)"
    guard let d = UserDefaults(suiteName: suite) else { check(false, "a scratch defaults suite"); return }
    defer { d.removePersistentDomain(forName: suite) }
    d.set("Alice", forKey: "display_name")
    d.set("Chan", forKey: "channel_display_name")
    UserPreferences.migrateDisplayName(d)
    check(d.string(forKey: "message_display_name") == "Alice", "the old display name becomes the Message Display Name")
    check(d.string(forKey: "display_name") == nil, "the old key is gone, so it runs once")
    check(d.string(forKey: "announce_display_name") == nil, "the Announce Display Name starts empty")
    check(d.string(forKey: "channel_display_name") == "Chan", "the channel name stays")
    d.set("Later", forKey: "display_name")
    UserPreferences.migrateDisplayName(d)
    check(d.string(forKey: "message_display_name") == "Alice", "a message name already set is never overwritten")
}

// MARK: - Wiring (source)

func testTheReceivePaths() {
    let repo = source("Retichat/Services/ChatRepository.swift")
    let incoming = body(repo, "private func handleIncomingMessage(")
    check(before(incoming, "if let key = fields.distroTransferKey", "LxmfClient.decodeDisplayName(fieldsRaw: fieldsRaw)"),
          "transfers and sent copies are dropped before any name is read")
    check(before(incoming, "if shouldProcessGroupMessage(", "applyMessageName(nameField, unverifiedReason: unverifiedReason, sourceHex: srcHex)\n                handleGroupMessage("),
          "a group message's 0xD1 names its LXMF source, only when the group policy accepts it (audit H11)")
    check(before(incoming, "guard allowlist.isAllowed else", "applyMessageName(nameField, unverifiedReason: unverifiedReason, sourceHex: srcHex)\n        storeIncomingDirect("),
          "a DM's 0xD1 is applied after the allowlist and before the bubble and notification")
    let nse = body(repo, "func importNSEMessages()")
    check(nse.contains("let reason = msg.unverifiedReason ?? (msg.signatureValid ? 0 : 2)"),
          "the NSE import decides on the stored reason; older files count as invalid")
    check(nse.components(separatedBy: "applyMessageName(nameField, unverifiedReason: reason, sourceHex: srcHex)").count == 3,
          "NSE-imported group messages and DMs both apply the name (audit M4)")
    check(before(nse, "guard allowlist.isAllowed else", "applyMessageName(nameField, unverifiedReason: reason, sourceHex: srcHex)\n            // As for"),
          "an NSE-imported DM applies it only past the allowlist")
    let distro = body(repo, "private func handleDistroMessage(")
    check(distro.contains("applyMessageName(m.displayName, unverifiedReason: m.unverifiedReason, sourceHex: srcHex)")
            && distro.contains("signatureValid: m.unverifiedReason == 0"),
          "distro messages carry their name and signature result (audit H7)")
    let apply = body(repo, "private func applyMessageName(")
    check(apply.contains("DisplayNames.acceptMessageName(field, unverifiedReason: unverifiedReason")
            && apply.contains("contact.messageName = name") && !apply.contains("localName"),
          "0xD1 writes messageName only, by the §5.2 table")
    check(apply.contains("!isOwnAddress(sourceHex)"), "this device's own addresses are never named from a message")
    let announce = body(repo, "private func handleAnnounce(")
    check(announce.contains("contact.announceName = announceName") && !announce.contains("localName")
            && !announce.contains("messageName"),
          "an announce replaces announceName (none when it has none) and nothing else")
    check(!repo.contains("updateContactNameIfEmpty"), "no first-name-wins-forever write is left (audit M5)")

    let distroClient = source("Retichat/Services/RfedDistroClient.swift")
    check(distroClient.contains("let display_name_state: Int?") && distroClient.contains("let unverified_reason: Int?")
            && distroClient.contains("displayName: parsed.nameField,"),
          "the distro unwrap's new JSON keys reach the message")
    let nsePull = source("NotificationService/NSEDistroPull.swift")
    check(nsePull.contains("let display_name_state: Int?") && nsePull.contains("DisplayNames.distroReason("),
          "the NSE's distro unwrap reads them too")

    let bridge = source("Retichat/Bridge/RetichatBridge.swift")
    check(bridge.contains("    signatureValid: Int32,\n    unverifiedReason: Int32,\n    fieldsRaw:"),
          "the app's delivery trampoline takes unverified_reason after signature_valid (CRetichatFFI.h)")
    let service = source("NotificationService/NotificationService.swift")
    check(service.contains("    signatureValid: Int32,\n    unverifiedReason: Int32,\n    fieldsRaw:")
            && service.contains("unverifiedReason: Int(unverifiedReason)"),
          "the NSE's does too, and stores it for the app")
}

func testTheSurfaces() {
    let repo = source("Retichat/Services/ChatRepository.swift")
    check(!repo.contains("contactDisplayName(for: srcHex)): \\\"")
            && repo.contains("content: \"Group invite from \\(DisplayNames.subjectToken): ")
            && repo.contains("content: \"\\(DisplayNames.subjectToken) joined the group\"")
            && repo.contains("content: \"\\(DisplayNames.subjectToken) left the group\""),
          "system messages store the subject's hash (senderHash) and a token, never a name (audit L2)")
    let messages = body(repo, "func messages(forChatId chatId: String")
    check(messages.contains("content: DisplayNames.systemText(entity.content, subject: senderName)"),
          "bubbles name the subject when shown")
    let refresh = body(repo, "func refreshChats()")
    check(refresh.contains("shownText($0.content, senderHash: $0.senderHash, names: names)"),
          "so does the chat-list preview")
    check(refresh.contains("let snapshot = names.compactMapValues { $0 }") && !refresh.contains("chatNameMap[chat.peerHash]"),
          "chat_names.json holds every named contact's resolved name, keyed by contact, never a placeholder (audit M3)")
    let contacts = body(repo, "func contacts() -> [Contact]")
    check(contacts.contains("!groupIds.contains($0.destHash)") && contacts.contains("!isOwnAddress($0.destHash)"),
          "the pickers never list a group id or this device (audit L4)")
    let create = body(repo, "func createGroupChat(")
    check(!create.contains("ensureAllowlistedContact(destHash: groupId)")
            && create.contains("guard memberHash != ownHashHex else { continue }"),
          "creating a group makes no contact for its id or for this device")
    check(!body(repo, "func acceptGroupInvite(").contains("ensureAllowlistedContact(destHash: groupId)"),
          "nor does accepting one")
    check(body(repo, "func createDirectChat(").contains("refreshAnnounceNameFromCache(destHash: normalizedHash)"),
          "a new chat takes the announce name already cached (audit M10)")
    let local = body(repo, "func setLocalName(")
    check(local.contains("contact.localName = LxmfClient.cleanDisplayName(name)"),
          "a local name is saved cleaned; empty cleans to none, which clears it")

    let view = source("Retichat/Views/Conversation/ConversationView.swift")
    check(view.contains("case .dm:              return repository.chats.first(where: { $0.id == chatId })?.displayName"),
          "the header follows the chat list's resolved name, not a copy taken on appear (audit L3)")
    check(view.contains(".onReceive(repository.$namesVersion)"), "an open chat reloads its bubbles on a name change")
    check(source("Retichat/Views/Conversation/ConversationViewModel.swift").contains(
            "let changed = namesChanged || page.count != messages.count"),
          "and the 3 s refresh does too")
    check(view.contains("renameText = isGroup ? title : (slots?.local ?? \"\")")
            && view.contains("repository.setLocalName(destHash: peerHash, name: trimmed)")
            && !view.contains("guard !trimmed.isEmpty else { return }\n        if isGroup"),
          "the rename field holds only the local name, and saving it empty clears it (audit M5)")
    check(view.contains("channelClient.senderLabel(\n                            channelHashHex: channel.id, senderHashHex: msg.senderHash,")
            && view.contains("senderSecondary: label?.secondary,"),
          "channel bubbles use the channel resolver, with the hash beside a channel name (audit H10)")
    check(source("Retichat/Views/Components/GlassComponents.swift").contains("if let secondary = message.senderSecondary {"),
          "the bubble shows that hash")
    for picker in ["NewChat/NewChatView.swift", "NewChat/NewGroupView.swift", "NewChat/NewConversationView.swift"] {
        check(!source("Retichat/Views/" + picker).contains("prefix(16)"),
              "\(picker) shows the resolved name, not a 16-hex placeholder")
    }

    let service = source("NotificationService/NotificationService.swift")
    check(service.contains("DisplayNames.notificationName(") && !service.contains("senderName = msg.title"),
          "NSE titles use the resolver order and never the LXMF title (audit M3)")
    check(service.contains("PendingNotification.readChannelSenderNames()[channelPull.channelHex]"),
          "NSE channel titles know the stored channel names")
}

func testTheChannelSend() {
    let client = source("Retichat/Services/RfedChannelClient.swift")
    let rule = body(client, "private func channelPostName(for channel: Channel)")
    check(rule.contains("LxmfClient.cleanDisplayName(prefs.channelDisplayName)") && !rule.contains("messageDisplayName"),
          "posts carry the Channel Display Name only, never the Message Display Name (§1)")
    let send = body(client, "private func trySend(")
    check(before(send, "let postName = channelPostName(for: channel)", "displayName: postName)"),
          "the pack gets the §4.2 decision")
    check(before(send, "let ok = await ConnectionStateManager.shared.appLinkSendData(", "recordPostName(postName, channelHashHex: channel.id)")
            && before(send, "if !ok {", "recordPostName(postName"),
          "the name is recorded only after RFed took the post")
    let note = body(client, "private func noteSender(")
    check(note.contains("if let at = row.channelNameAtMs, postMs < at {"),
          "an older post pulled later does not undo a newer name")
    check(body(client, "private func dispatchVerifiedLxmf(").contains("if !isOutgoing {\n            noteSender("),
          "only other senders' verified posts are noted")
    check(source("Retichat/Models/Models.swift").contains("var nameLastDigestHex: String?")
            && source("Retichat/RetichatApp.swift").contains("ChannelSenderEntity.self"),
          "the channel state is persisted (§4.2)")
}

func testTheSettings() {
    let settings = source("Retichat/Views/Settings/SettingsView.swift")
    for hint in ["Public. Sent in your announces to the whole network, including other Reticulum apps. Leave empty to stay anonymous.",
                 "Sent inside your messages, only to the people you message.",
                 "Shown on your channel posts. Anyone who can read a channel can see it. Leave empty to post without a name."] {
        check(settings.contains(hint), "Settings shows the §6 text: \(hint.prefix(30))…")
    }
    check(!settings.contains("If blank, uses your Display Name"), "the channel name no longer claims a fallback (audit H9)")
    check(settings.contains("guard needsRestart, repository.serviceRunning else { return }")
            && settings.contains("repository.applyDisplayNames(announceChanged: announceChanged)"),
          "names apply through the setters; only settings read at start restart the stack (audit M7)")
    let vm = source("Retichat/Views/Settings/SettingsViewModel.swift")
    let restart = body(vm, "var needsRestart: Bool")
    check(!restart.contains("DisplayName"), "no name is a restart setting")
    check(vm.contains("announceDisplayName = LxmfClient.cleanDisplayName(announceDisplayName, announce: true) ?? \"\"")
            && vm.contains("messageDisplayName = LxmfClient.cleanDisplayName(messageDisplayName) ?? \"\""),
          "names are saved cleaned, as the router cleans them")
    let repo = source("Retichat/Services/ChatRepository.swift")
    let finish = body(repo, "private func finishStartService(")
    check(before(finish, "self.lxmfClient = client", "applyDisplayNames(announceChanged: false)")
            && before(finish, "applyDisplayNames(announceChanged: false)", "_ = publishClient.publish(refreshSecs: 30 * 60)"),
          "the names are set on the stack's queue before the first announce")
    let apply = body(repo, "func applyDisplayNames(")
    check(before(apply, "ffiQueue.async {", "client.setAnnounceDisplayName(announce)"),
          "the setters run on ffiQueue, in order with the publish, never on the main thread")
    check(source("Retichat/Services/RfedDistroClient.swift").contains(
            "announceName: UserPreferences.shared.announceDisplayName"),
          "the distro's pre-signed announce carries it too (§2.2)")
}

@main
enum DisplayNamesTests {
    static func main() {
        testTheNameStateBufferParses()
        testTheRetiredFieldNoLongerStopsTheParse()
        testTheAcceptTable()
        testTheResolver()
        testTheNotificationServiceTitle()
        testTheChannelRule()
        testTheDigestMatchesTheRustVectors()
        testTheDistroUnwrapKeys()
        testTheContactMigration()
        testTheContactMigrationWiring()
        testTheSettingsMigration()
        testTheReceivePaths()
        testTheSurfaces()
        testTheChannelSend()
        testTheSettings()
        if failures.isEmpty {
            print("all display name tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
