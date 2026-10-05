//
//  UserPreferences.swift
//  Retichat
//
//  UserDefaults wrapper mirroring Android SharedPreferences.
//

import Foundation
import CryptoKit

final class UserPreferences {
    static let shared = UserPreferences()
    /// The RFed node used when none is set. Settings shows it in the field
    /// rather than leaving the field blank over a hidden fallback.
    static let defaultRfedNodeIdentityHash = "7e5ff856dc2aa0fbc9fc8831b62d2834"

    private let defaults = UserDefaults.standard

    private init() {
        // Until 2026-09-24 Settings saved copies of the rfed.notify and
        // lxmf.propagation hashes derived from the RFed node, and those copies
        // won over the node: a node changed any other way left them pointing
        // at the old one (the simulator, switched back from staging, sent every
        // propagated message to the staging node). Both are derived at use time
        // now; drop the copies so none can come back.
        defaults.removeObject(forKey: Keys.rfedNotifyHash)
        defaults.removeObject(forKey: Keys.lxmfPropagationHash)
        Self.migrateDisplayName(defaults)
    }

    /// DISPLAY_NAMES.md §5.4: the old single display name was sent inside
    /// messages, so it becomes the Message Display Name. The Announce
    /// Display Name starts empty; the channel name keeps its key.
    static func migrateDisplayName(_ defaults: UserDefaults) {
        guard let old = defaults.string(forKey: Keys.legacyDisplayName) else { return }
        if defaults.string(forKey: Keys.messageDisplayName) == nil {
            defaults.set(old, forKey: Keys.messageDisplayName)
        }
        defaults.removeObject(forKey: Keys.legacyDisplayName)
    }

    private enum Keys {
        /// Until 2026-09-27; moved to messageDisplayName at init.
        static let legacyDisplayName = "display_name"
        static let messageDisplayName = "message_display_name"
        static let announceDisplayName = "announce_display_name"
        static let channelDisplayName = "channel_display_name"
        static let contactNamesMigrated = "contact_names_migrated_v1"
        static let contactNamesPlaceholderPass = "contact_names_placeholder_pass_v1"
        static let defaultTcpEnabled = "default_tcp_enabled"
        static let rtnodeBluetoothEnabled = "rtnode_bluetooth_enabled"
        static let dropAnnounces = "drop_announces"
        static let identityPath = "identity_path"
        /// No longer written; removed at init (see init).
        static let rfedNotifyHash = "rfed_notify_hash"
        static let apnsDeviceToken = "apns_device_token"
        /// No longer written; removed at init (see init).
        static let lxmfPropagationHash = "lxmf_propagation_hash"
        static let rfedNodeIdentityHash = "rfed_node_identity_hash"
        static let rfedLxmfPropOverride = "rfed_lxmf_prop_override"
        static let filterStrangers = "filter_strangers"
        static let mutedChatIds = "muted_chat_ids"
        static let channelNotificationsOn = "channel_notifications_on"
        static let channelPushEnabled = "channel_push_enabled"
        static let channelLastOpened = "channel_last_opened"
        static let distroContacts = "distro_contacts"
    }

    // MARK: - Display names (LXMF-rust/DISPLAY_NAMES.md)
    //
    // Three independent names, all empty by default; none falls back to
    // another (§1). Settings saves them cleaned (lxmf_display_name_clean), so
    // the screen shows exactly what goes out.

    /// Sent inside messages (field 0xD1), only to the people messaged (§4.1).
    var messageDisplayName: String {
        get { defaults.string(forKey: Keys.messageDisplayName) ?? "" }
        set { defaults.set(newValue, forKey: Keys.messageDisplayName) }
    }

    /// PUBLIC: sent in this device's and the distro's announces to the whole
    /// network (§2.2). Empty = anonymous (the announce carries nil).
    var announceDisplayName: String {
        get { defaults.string(forKey: Keys.announceDisplayName) ?? "" }
        set { defaults.set(newValue, forKey: Keys.announceDisplayName) }
    }

    /// Carried in channel posts by the §4.2 rule. Empty = posts carry no
    /// name; it never falls back to the Message Display Name.
    var channelDisplayName: String {
        get { defaults.string(forKey: Keys.channelDisplayName) ?? "" }
        set { defaults.set(newValue, forKey: Keys.channelDisplayName) }
    }

    /// The one-time contact name migration (§5.4) has run.
    var contactNamesMigrated: Bool {
        get { defaults.bool(forKey: Keys.contactNamesMigrated) }
        set { defaults.set(newValue, forKey: Keys.contactNamesMigrated) }
    }

    /// The one-off second §5.4 pass has run (ChatRepository
    /// .remigrateContactNamesIfNeeded): stored names lose an old web node
    /// default and the old web announce suffix.
    var contactNamesPlaceholderPass: Bool {
        get { defaults.bool(forKey: Keys.contactNamesPlaceholderPass) }
        set { defaults.set(newValue, forKey: Keys.contactNamesPlaceholderPass) }
    }

    /// When true (default) and no user-configured interfaces are present,
    /// three invisible fallback TCP backbones are injected at startup.
    /// Mirrors Android `PREF_KEY_DEFAULT_TCP`.
    var defaultTcpEnabled: Bool {
        get { defaults.object(forKey: Keys.defaultTcpEnabled) != nil ? defaults.bool(forKey: Keys.defaultTcpEnabled) : true }
        set { defaults.set(newValue, forKey: Keys.defaultTcpEnabled) }
    }

    /// When true, Retichat links over Bluetooth to any RTNode in range, with
    /// no other configuration (RTNodeBluetoothCoordinator). Off by default
    /// (James, 2026-09-29): a user who never turns it on sees no Bluetooth
    /// permission prompt and nothing scans, because the coordinator, and with
    /// it the CBCentralManager that asks, is only started when this is true.
    var rtnodeBluetoothEnabled: Bool {
        get { Self.rtnodeBluetoothEnabled(defaults) }
        set { defaults.set(newValue, forKey: Keys.rtnodeBluetoothEnabled) }
    }

    /// The saved switch; false when it was never set. Settings saves it as a
    /// Bool, so a value the user chose, on or off, is what is read back.
    static func rtnodeBluetoothEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: Keys.rtnodeBluetoothEnabled) != nil
            ? defaults.bool(forKey: Keys.rtnodeBluetoothEnabled) : false
    }

    var dropAnnounces: Bool {
        get { defaults.object(forKey: Keys.dropAnnounces) != nil ? defaults.bool(forKey: Keys.dropAnnounces) : true }
        set { defaults.set(newValue, forKey: Keys.dropAnnounces) }
    }

    var identityPath: String? {
        get { defaults.string(forKey: Keys.identityPath) }
        set { defaults.set(newValue, forKey: Keys.identityPath) }
    }

    /// Runtime RFed notify-register destination, derived from the RFed node
    /// in use, so it always follows the node.
    ///
    /// After the rfed.notify aspect split this is the canonical probe used
    /// for UI reachability indicators and as the target for the register
    /// op. Unregister derives its own hash via `["notify", "unregister"]`.
    var effectiveRfedNotifyHash: String {
        Self.rnsDestHash(identityHashHex: effectiveRfedNodeIdentityHash,
                         app: "rfed", aspects: ["notify", "register"]) ?? ""
    }



    /// Last known APNs device token (hex string). Stored for re-registration on launch.
    var apnsDeviceToken: String {
        get { defaults.string(forKey: Keys.apnsDeviceToken) ?? "" }
        set { defaults.set(newValue, forKey: Keys.apnsDeviceToken) }
    }

    /// Runtime LXMF propagation destination, tried first on every poll cycle
    /// (the built-in rotated pool follows on failure): the Settings override
    /// when one is set, otherwise derived from the RFed node in use, at the
    /// moment it is asked for, so it always follows the node (Android
    /// ChatRepository.selectPropagationNode derives it the same way).
    var effectiveLxmfPropagationHash: String {
        let override = Self.normalizedHex(rfedLxmfPropOverride)
        if !override.isEmpty { return override }
        return Self.rnsDestHash(identityHashHex: effectiveRfedNodeIdentityHash,
                                app: "lxmf", aspects: ["propagation"]) ?? ""
    }

    /// 32-char hex public identity hash of the RFed node.
    /// Capability destination hashes (rfed.notify, rfed.channel, rfed.delivery,
    /// lxmf.propagation) are derived automatically from this value.
    var rfedNodeIdentityHash: String {
        get { defaults.string(forKey: Keys.rfedNodeIdentityHash) ?? "" }
        set { defaults.set(newValue, forKey: Keys.rfedNodeIdentityHash) }
    }

    /// Runtime RFed identity hash: the one saved in Settings, or the default
    /// when none is saved.
    var effectiveRfedNodeIdentityHash: String {
        let configured = Self.normalizedHex(rfedNodeIdentityHash)
        if !configured.isEmpty { return configured }
        return Self.defaultRfedNodeIdentityHash
    }

    /// Optional override for the LXMF propagation hash.
    /// When empty, the lxmf.propagation hash is derived from rfedNodeIdentityHash.
    var rfedLxmfPropOverride: String {
        get { defaults.string(forKey: Keys.rfedLxmfPropOverride) ?? "" }
        set { defaults.set(newValue, forKey: Keys.rfedLxmfPropOverride) }
    }

    /// When true, incoming messages from senders not in the contact allowlist
    /// are silently dropped.  Contacts are allowlisted when explicitly added
    /// via "New Chat" or QR scan.  Defaults to true (block strangers).
    var filterStrangers: Bool {
        get { defaults.object(forKey: Keys.filterStrangers) != nil ? defaults.bool(forKey: Keys.filterStrangers) : true }
        set { defaults.set(newValue, forKey: Keys.filterStrangers) }
    }

    /// Set of chat IDs for which notifications are silenced by the user.
    var mutedChatIds: Set<String> {
        get {
            let arr = defaults.stringArray(forKey: Keys.mutedChatIds) ?? []
            return Set(arr)
        }
        set { defaults.set(Array(newValue), forKey: Keys.mutedChatIds) }
    }

    func muteChat(_ chatId: String) {
        var ids = mutedChatIds
        ids.insert(chatId)
        mutedChatIds = ids
    }

    func unmuteChat(_ chatId: String) {
        var ids = mutedChatIds
        ids.remove(chatId)
        mutedChatIds = ids
    }

    func isChatMuted(_ chatId: String) -> Bool {
        mutedChatIds.contains(chatId)
    }

    /// Set of channel IDs for which notifications are enabled.
    /// Channels are opt-in (default off); add a channel ID here to enable notifications.
    var channelNotificationsOn: Set<String> {
        get {
            let arr = defaults.stringArray(forKey: Keys.channelNotificationsOn) ?? []
            return Set(arr)
        }
        set { defaults.set(Array(newValue), forKey: Keys.channelNotificationsOn) }
    }

    func enableChannelNotifications(_ channelId: String) {
        var ids = channelNotificationsOn
        ids.insert(channelId)
        channelNotificationsOn = ids
    }

    func disableChannelNotifications(_ channelId: String) {
        var ids = channelNotificationsOn
        ids.remove(channelId)
        channelNotificationsOn = ids
    }

    func isChannelNotificationsEnabled(_ channelId: String) -> Bool {
        channelNotificationsOn.contains(channelId)
    }

    /// Set of channel IDs for which push wakeups are enabled.
    /// When enabled, the device registers with rfed.notify so a silent push is fired
    /// for every new channel message (waking the app to pull it).
    /// Defaults to ON when a channel is joined.
    var channelPushEnabled: Set<String> {
        get {
            let arr = defaults.stringArray(forKey: Keys.channelPushEnabled) ?? []
            return Set(arr)
        }
        set { defaults.set(Array(newValue), forKey: Keys.channelPushEnabled) }
    }

    func enableChannelPush(_ channelId: String) {
        var ids = channelPushEnabled
        ids.insert(channelId)
        channelPushEnabled = ids
    }

    func disableChannelPush(_ channelId: String) {
        var ids = channelPushEnabled
        ids.remove(channelId)
        channelPushEnabled = ids
    }

    func isChannelPushEnabled(_ channelId: String) -> Bool {
        channelPushEnabled.contains(channelId)
    }

    // MARK: - Distro contacts

    /// Destination hashes (lowercase hex) whose lxmf.delivery announce carried
    /// the distro flag SF_RFED_DISTRO (RFed SPEC §17.10). Written ONLY from that
    /// announce flag (ChatRepository.handleAnnounce), never from lxma:// links:
    /// a link carries a key, not distro-ness. A send to one of these goes
    /// PROPAGATED at once. Android UserPreferences.kt:186-193.
    func isDistroContact(_ hex: String) -> Bool {
        (defaults.stringArray(forKey: Keys.distroContacts) ?? []).contains(hex.lowercased())
    }

    func setDistroContact(_ hex: String, _ isDistro: Bool) {
        let key = hex.lowercased()
        var set = Set(defaults.stringArray(forKey: Keys.distroContacts) ?? [])
        if isDistro { set.insert(key) } else { set.remove(key) }
        defaults.set(Array(set).sorted(), forKey: Keys.distroContacts)
    }

    /// Per-channel "last opened" timestamp in **seconds** (Apple epoch).
    /// Used by `ChatListView` as the channel sort key so channels only
    /// bubble to the top when the user actually opens them — incoming
    /// channel traffic does *not* reorder the list.  Channels never
    /// opened on this device sit at the bottom (timestamp 0).
    var channelLastOpened: [String: Double] {
        get {
            let raw = defaults.dictionary(forKey: Keys.channelLastOpened) as? [String: Double] ?? [:]
            // Migrate legacy ms-encoded values written before the unit switch.
            // Anything > 1e11 cannot be a seconds-epoch value (year 5138+).
            var migrated = raw
            var changed = false
            for (k, v) in raw where v > 1e11 {
                migrated[k] = v / 1000.0
                changed = true
            }
            if changed {
                defaults.set(migrated, forKey: Keys.channelLastOpened)
            }
            return migrated
        }
        set { defaults.set(newValue, forKey: Keys.channelLastOpened) }
    }

    func channelLastOpenedTime(_ channelId: String) -> Double {
        channelLastOpened[channelId] ?? 0
    }

    func markChannelOpened(_ channelId: String, at time: Double = Date().timeIntervalSince1970) {
        var map = channelLastOpened
        map[channelId] = time
        channelLastOpened = map
    }

    static func normalizedHex(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedAspectSegments(app: String, aspects: [String]) -> [String] {
        let normalizedApp = app.trimmingCharacters(in: .whitespacesAndNewlines)
        var segments = aspects
            .flatMap { $0.split(whereSeparator: { $0 == "." || $0 == "," }) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if segments.first == normalizedApp {
            segments.removeFirst()
        }

        return segments
    }

    private static func rnsDestHash(identityHashHex: String, app: String, aspects: [String]) -> String? {
        let hex = normalizedHex(identityHashHex)
        guard hex.count == 32, let identityBytes = Data(hexString: hex) else { return nil }
        let name = ([app] + normalizedAspectSegments(app: app, aspects: aspects)).joined(separator: ".")
        let nameHashFull = SHA256.hash(data: Data(name.utf8))
        let nameHashTrunc = Data(nameHashFull.prefix(10))
        let material = nameHashTrunc + identityBytes
        let destHashFull = SHA256.hash(data: material)
        return Data(destHashFull.prefix(16)).hexString
    }
}
