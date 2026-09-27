import Foundation
import Security

/// Bridge between the main app and the Notification Service Extension via the
/// shared App Group container.
///
/// The NSE stores delivered messages here.  The main app imports them on
/// the next foreground transition.
///
/// All methods are pure file I/O with no UI dependencies, so the enum is
/// explicitly nonisolated to allow calls from any thread/task.
nonisolated enum PendingNotification {

    static let appGroup = "group.com.newendian.Retichat"

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    // MARK: - NSE Message Store

    /// Full message payload stored by the NSE for main-app import.
    struct NSEMessage: Codable {
        let messageHash: String       // hex
        let senderHash: String        // hex
        let destHash: String          // hex
        let title: String
        let content: String
        let timestamp: Double
        let signatureValid: Bool
        let fieldsRawBase64: String   // base64-encoded raw LXMF fields
        /// Why the signature did not validate: 0 validated, 1 source unknown,
        /// 2 invalid. The app accepts the sender's name (field 0xD1) by it
        /// (DISPLAY_NAMES.md §5.2). nil in files written by older builds.
        var unverifiedReason: Int? = nil
        /// Set when this message was a distro identity transfer (SPEC §17.9).
        /// Its fields are then NOT persisted — see stashDistroTransferKey.
        /// Optional so files written by older builds still decode.
        var distroTransfer: DistroTransferStash? = nil

        /// The same message without its fields, for a transfer whose key has
        /// been moved out (or could not be kept).
        func strippedForDistroTransfer(_ stash: DistroTransferStash) -> NSEMessage {
            NSEMessage(messageHash: messageHash, senderHash: senderHash, destHash: destHash,
                       title: title, content: content, timestamp: timestamp,
                       signatureValid: signatureValid, fieldsRawBase64: "",
                       unverifiedReason: unverifiedReason, distroTransfer: stash)
        }
    }

    enum DistroTransferStash: String, Codable {
        /// The key is in the shared Keychain under the message hash.
        case keychain
        /// The Keychain refused it; the key was dropped, not written to disk.
        case lost
    }

    private static let nseMessagesFile = "nse_messages.json"

    /// One lock per process for the hand-off file: an append replaces the
    /// file with an extended copy, and iOS can run two NSE requests in one
    /// process, each with its own NSERun, so a lock per run would still
    /// lose one of two writes. It does not reach the other process: the
    /// app's import and the NSE's appends are still uncoordinated (C3 puts
    /// both under the catch-up lease).
    private static let nseMessagesLock = NSLock()

    /// Append a message delivered by the NSE. Returns whether it was
    /// written; a failure is logged.
    @discardableResult
    static func appendNSEMessage(_ message: NSEMessage) -> Bool {
        guard let dir = containerURL else {
            NSLog("[NSE] hand-off: no App Group container, message %@ not stored",
                  String(message.messageHash.prefix(8)))
            return false
        }
        return appendNSEMessage(message, in: dir)
    }

    /// `appendNSEMessage` against a given directory (tests use a scratch one).
    @discardableResult
    static func appendNSEMessage(_ message: NSEMessage, in dir: URL) -> Bool {
        let file = dir.appendingPathComponent(nseMessagesFile)
        nseMessagesLock.lock()
        defer { nseMessagesLock.unlock() }
        do {
            if try appendEntry(JSONEncoder().encode(message), to: file) { return true }
            // No file yet, or not one appendEntry can extend: write it whole.
            var messages = loadMessages(from: file)
            messages.append(message)
            try JSONEncoder().encode(messages).write(to: file, options: .atomic)
            return true
        } catch {
            NSLog("[NSE] hand-off: message %@ not stored: %@",
                  String(message.messageHash.prefix(8)), error.localizedDescription)
            return false
        }
    }

    /// Adds one encoded message to the file's array without decoding what is
    /// already there. An NSE run appends once per delivery, and decoding and
    /// re-encoding the whole file each time peaks at six to eight times its
    /// size: three 1 MB attachments went past the NSE's memory limit
    /// (measured 2026-09-25). The file is cloned, the clone's closing "]"
    /// becomes ",<entry>]", and the clone is renamed over the file, so a
    /// reader sees the old file or the new one, never part of one. False,
    /// with the file untouched, when there is no file or it does not end
    /// the way JSONEncoder writes a non-empty array.
    private static func appendEntry(_ entry: Data, to file: URL) throws -> Bool {
        let fm = FileManager.default
        // A fixed name: appends are serialised by nseMessagesLock and only
        // the NSE appends, so one left behind by a killed NSE is replaced.
        let clone = file.deletingLastPathComponent().appendingPathComponent(".\(nseMessagesFile).append")
        try? fm.removeItem(at: clone)
        defer { try? fm.removeItem(at: clone) }
        guard (try? fm.copyItem(at: file, to: clone)) != nil else { return false }
        let handle = try FileHandle(forUpdating: clone)
        do {
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            guard size >= 3 else { return false }
            try handle.seek(toOffset: 0)
            let first = try handle.read(upToCount: 1)
            try handle.seek(toOffset: size - 2)
            let last = try handle.read(upToCount: 2)
            guard first == Data("[".utf8), last == Data("}]".utf8) else { return false }
            try handle.seek(toOffset: size - 1)
            // Three writes, not one concatenated copy of the entry.
            try handle.write(contentsOf: Data(",".utf8))
            try handle.write(contentsOf: entry)
            try handle.write(contentsOf: Data("]".utf8))
        }
        guard rename(clone.path, file.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return true
    }

    /// Read and remove all NSE-delivered messages.
    static func readAndClearNSEMessages() -> [NSEMessage] {
        guard let dir = containerURL else { return [] }
        return readAndClearNSEMessages(in: dir)
    }

    /// `readAndClearNSEMessages` against a given directory.
    static func readAndClearNSEMessages(in dir: URL) -> [NSEMessage] {
        let file = dir.appendingPathComponent(nseMessagesFile)
        nseMessagesLock.lock()
        defer { nseMessagesLock.unlock() }
        let messages = loadMessages(from: file)
        try? FileManager.default.removeItem(at: file)
        return messages
    }

    private static func loadMessages(from file: URL) -> [NSEMessage] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        guard let entries = try? JSONDecoder().decode([OneEntry].self, from: data) else {
            // Not an array at all: whatever it held is lost.
            NSLog("[NSE] hand-off: %@ (%d bytes) does not decode; its messages are lost",
                  file.lastPathComponent, data.count)
            return []
        }
        let msgs = entries.compactMap(\.message)
        if msgs.count < entries.count {
            NSLog("[NSE] hand-off: %d of %d entries in %@ do not decode; they are lost",
                  entries.count - msgs.count, entries.count, file.lastPathComponent)
        }
        return msgs
    }

    /// One entry of the file, or nil if it does not decode. appendEntry
    /// extends the file without decoding it, so one bad entry must not take
    /// the entries after it down with it.
    private struct OneEntry: Decodable {
        let message: NSEMessage?
        init(from decoder: Decoder) throws {
            message = try? NSEMessage(from: decoder)
        }
    }

    // MARK: - One NSE run's deliveries
    //
    // The sync an NSE run starts acknowledges every fetched message to the
    // propagation node, which deletes them. Until 2026-09-25 the NSE kept
    // only the first delivery of a run, so with two or more messages
    // waiting, messages 2..N were deleted from the node and stored nowhere
    // (CONNECTIVITY_READINESS.md U2). Every delivery is now written as it
    // arrives: the router calls the delivery callback for each message
    // before it sends the acknowledgement, so each one is in the file
    // before the node is told to delete it, or its failed write is logged
    // and counted. The notification summarises what was written.

    /// Collects one NSE run's deliveries. `deliver` is called on the
    /// stack's thread; the NSE reads `summary()` after sync-complete, which
    /// the router raises only after the run's last delivery.
    nonisolated final class NSERun: @unchecked Sendable {
        private let lock = NSLock()
        private let prepare: (NSEMessage) -> NSEMessage?
        private let store: (NSEMessage) -> Bool
        private var newest: NSEMessage?
        private var stored = 0
        private var failed = 0
        private var dropped = 0

        /// `prepare` gives the form a delivered message is stored in, or
        /// nil when it is not stored (a distro sent copy). `store` writes
        /// it for the app's import and says whether it did.
        init(prepare: @escaping (NSEMessage) -> NSEMessage?,
             store: @escaping (NSEMessage) -> Bool = { PendingNotification.appendNSEMessage($0) }) {
            self.prepare = prepare
            self.store = store
        }

        func deliver(_ message: NSEMessage) {
            guard let toStore = prepare(message) else {
                lock.lock()
                dropped += 1
                lock.unlock()
                return
            }
            // The file has its own lock (nseMessagesLock); this one guards
            // only the run's counts.
            let written = store(toStore)
            lock.lock()
            defer { lock.unlock() }
            guard written else {
                // Not in the file, so the app will never import it: it is
                // neither shown nor counted in "+N more".
                failed += 1
                return
            }
            stored += 1
            // Only the newest is kept in memory (the NSE's budget is small);
            // a tie goes to the later delivery.
            if newest.map({ toStore.timestamp >= $0.timestamp }) ?? true {
                newest = toStore
            }
        }

        func summary() -> NSERunSummary {
            lock.lock()
            defer { lock.unlock() }
            return NSERunSummary(newest: newest, others: max(stored - 1, 0),
                                 failed: failed, dropped: dropped)
        }
    }

    /// What an NSE run's notification shows: the newest message written,
    /// and how many others were written with it.
    struct NSERunSummary {
        let newest: NSEMessage?
        let others: Int
        /// Delivered but not written. The router acknowledges them to the
        /// node all the same, so they are lost (U3 acknowledges only what
        /// the host stored).
        let failed: Int
        /// Delivered but not stored (distro sent copies).
        let dropped: Int

        /// The newest message's text, then "+N more" on its own line when
        /// the run stored others.
        var body: String {
            guard let newest else { return "" }
            guard others > 0 else { return newest.content }
            let more = "+\(others) more"
            return newest.content.isEmpty ? more : newest.content + "\n" + more
        }
    }

    /// Clean up stale files (call on app launch, after importing NSE messages).
    static func cleanup() {
        guard let dir = containerURL else { return }
        // Legacy files from previous versions
        for name in ["pending_notif.json", "nse_handled", "nse_stage",
                      "service_heartbeat"] {
            let f = dir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: f)
        }
    }

    // MARK: - Distro transfer keys (Keychain, never the container)
    //
    // A transfer's FIELD_CUSTOM_DATA (0xFC) is the 128-hex distro private
    // key. nse_messages.json is a plain file in the App Group container
    // (included in device backups), so the NSE moves the key into a Keychain
    // item in the App Group's access group — app groups are valid keychain
    // access groups, so both targets reach it without a new entitlement —
    // and persists the message without its fields. The app takes (reads and
    // deletes) the item when it imports the message. DistroManager's rule:
    // the key lives only in the Keychain, ThisDeviceOnly (never iCloud).

    private static let transferKeychainService = "com.newendian.Retichat.distro.transfer-inbox"

    private static func transferQuery(messageHash: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: transferKeychainService,
            kSecAttrAccount as String: messageHash,
            kSecAttrAccessGroup as String: appGroup,
        ]
    }

    /// NSE side. Returns the Keychain status; anything but errSecSuccess
    /// means the key was not kept (the caller must not write it elsewhere).
    static func stashDistroTransferKey(_ keyHex: String, messageHash: String) -> OSStatus {
        guard let data = keyHex.data(using: .utf8) else { return errSecParam }
        let query = transferQuery(messageHash: messageHash)
        // The same message fetched twice (a second NSE run) replaces, not fails.
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil)
    }

    /// App side: read the stashed key and delete it. nil if absent or
    /// unreadable (the status is logged). Call off the main actor.
    static func takeDistroTransferKey(messageHash: String) -> String? {
        var query = transferQuery(messageHash: messageHash)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else {
            print("[Distro] NSE transfer key for \(messageHash.prefix(8)) not readable (\(status))")
            return nil
        }
        let del = SecItemDelete(transferQuery(messageHash: messageHash) as CFDictionary)
        if del != errSecSuccess {
            print("[Distro] NSE transfer key for \(messageHash.prefix(8)) read but not deleted (\(del))")
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Shared Reticulum data (for NSE stack)

    /// Directory inside the App Group where the NSE can find identity + config.
    static func nseReticulumDir() -> String? {
        guard let dir = containerURL else { return nil }
        let nseDir = dir.appendingPathComponent("nse_reticulum")
        try? FileManager.default.createDirectory(at: nseDir, withIntermediateDirectories: true)
        return nseDir.path
    }

    /// Copy the identity file into the App Group so the NSE can load it.
    static func copyIdentityToAppGroup(from sourcePath: String) {
        guard let nseDir = nseReticulumDir() else { return }
        let dest = URL(fileURLWithPath: nseDir).appendingPathComponent("identity")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(atPath: sourcePath, toPath: dest.path)
    }

    /// Copy the Reticulum config into the App Group so the NSE can init.
    static func copyConfigToAppGroup(from sourcePath: String) {
        guard let nseDir = nseReticulumDir() else { return }
        let dest = URL(fileURLWithPath: nseDir).appendingPathComponent("config")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(atPath: sourcePath, toPath: dest.path)
    }

    /// The NSE stack's storage directory in the App Group.
    static func nseStorageDir() -> String? {
        guard let nseDir = nseReticulumDir() else { return nil }
        let dir = URL(fileURLWithPath: nseDir).appendingPathComponent("storage")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    /// Where the app writes its known destinations snapshot for the NSE
    /// (RetichatBridge.snapshotKnownDestinations). Since 2026-09-26 they are a
    /// SQLite database, which a file copy can catch half-written.
    static func nseKnownDestinationsPath() -> String? {
        nseStorageDir().map { $0 + "/known_destinations.sqlite3" }
    }

    /// Sync the Reticulum path table into the App Group so the NSE stack can
    /// find routes immediately. Known identities go by
    /// RetichatBridge.snapshotKnownDestinations.
    static func syncStorageToAppGroup(from storageDir: String) {
        guard let dir = nseStorageDir() else { return }
        let fm = FileManager.default
        let destStorage = URL(fileURLWithPath: dir)

        for name in ["destination_table"] {
            let src = URL(fileURLWithPath: storageDir).appendingPathComponent(name)
            let dst = destStorage.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
        }
    }

    /// The directory the NSE loads its delivery ratchets from (its LXMRouter
    /// appends "/lxmf" to its storage path "nse_reticulum/lxmf_storage", and
    /// keeps ratchets in "ratchets/<dest hexhash>.ratchets" under that).
    /// Created if missing: the app's stack mirrors every write of its ratchet
    /// file here (LxmfClientConfig.ratchetsMirrorDir), and a mirror write
    /// into a missing directory fails.
    static func nseRatchetsDir() -> String? {
        guard let nseDir = nseReticulumDir() else { return nil }
        let dir = URL(fileURLWithPath: nseDir)
            .appendingPathComponent("lxmf_storage")
            .appendingPathComponent("lxmf")
            .appendingPathComponent("ratchets")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("[Retichat] NSE ratchet directory not created: %@", error.localizedDescription)
            return nil
        }
        return dir.path
    }

    /// Copy the app's LXMF ratchet files into the NSE's ratchet directory,
    /// once per start, BEFORE the app's stack starts (ChatRepository runs it
    /// on ffiQueue ahead of LxmfClient.start). From the start on, the stack
    /// itself keeps the NSE's file current: it mirrors every write of the
    /// ratchet file there (LxmfClientConfig.ratchetsMirrorDir), including the
    /// rotation of the run's first announce. This copy only brings over what
    /// a run before the mirror existed, or a failed mirror write, left behind.
    ///
    /// It cannot overwrite a newer mirror: while no stack runs nothing writes
    /// the app's ratchet file, the NSE never writes its own (it starts with
    /// frozen ratchets), and the last mirror write is identical to the last
    /// primary write. A copy racing the running stack could put an older
    /// file over a newer mirror, so there is no other copy.
    ///
    /// Each file is written atomically (tmp + rename), so an NSE that loads
    /// its ratchets meanwhile reads the old file or the new one, never none.
    ///
    /// Note: LXMRouter internally appends "/lxmf" to the storage path, so the
    /// real ratchet dir is `{lxmfStoragePath}/lxmf/ratchets/`.
    static func syncRatchetsToAppGroup(from lxmfStoragePath: String, to nseRatchetsDir: String? = nil) {
        guard let dstPath = nseRatchetsDir ?? Self.nseRatchetsDir() else { return }
        let fm = FileManager.default
        let srcDir = URL(fileURLWithPath: lxmfStoragePath)
            .appendingPathComponent("lxmf")
            .appendingPathComponent("ratchets")
        let dstDir = URL(fileURLWithPath: dstPath)

        guard fm.fileExists(atPath: srcDir.path) else { return }
        try? fm.createDirectory(at: dstDir, withIntermediateDirectories: true)

        guard let files = try? fm.contentsOfDirectory(atPath: srcDir.path) else { return }
        for file in files where file.hasSuffix(".ratchets") {
            let src = srcDir.appendingPathComponent(file)
            let dst = dstDir.appendingPathComponent(file)
            let tmp = dstDir.appendingPathComponent(file + ".copy.tmp")
            try? fm.removeItem(at: tmp)
            do {
                try fm.copyItem(at: src, to: tmp)
                guard rename(tmp.path, dst.path) == 0 else {
                    NSLog("[Retichat] ratchet copy to the App Group not renamed: errno %d", errno)
                    try? fm.removeItem(at: tmp)
                    continue
                }
            } catch {
                NSLog("[Retichat] ratchet copy to the App Group failed: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Chat name map (for NSE notification titles)

    /// Write a map of contact hash → the contact's shared name
    /// (DISPLAY_NAMES.md §5.3: localName ?? messageName ?? announceName,
    /// with the slot it came from and messageNameAt; a contact with no name
    /// is left out, never written as a hash placeholder) for the NSE's
    /// titles. Format: DisplayNames.SharedName.
    @discardableResult
    static func writeChatNames(_ names: [String: DisplayNames.SharedName], in dir: URL? = nil) -> Bool {
        guard let dir = dir ?? containerURL,
              let data = try? JSONEncoder().encode(names) else { return false }
        do {
            try data.write(to: dir.appendingPathComponent("chat_names.json"), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Read the map written by the main app. A file from a build before the
    /// slot kind (hash → bare name) still reads, each name as `legacy`.
    static func readChatNames(in dir: URL? = nil) -> [String: DisplayNames.SharedName] {
        guard let dir = dir ?? containerURL,
              let data = try? Data(contentsOf: dir.appendingPathComponent("chat_names.json")),
              let names = try? JSONDecoder().decode([String: DisplayNames.SharedName].self, from: data) else {
            return [:]
        }
        return names
    }

    // MARK: - Channel Display Names (for NSE notification titles)

    /// channel hash → sender hash → the Channel Display Name that sender's
    /// posts there carry (DISPLAY_NAMES.md §5.1) and the post time that set
    /// or cleared it, so the NSE labels a channel post as the app does even
    /// when the post carries no name, and an older post pulled late does
    /// not rename its sender in the title (§5.2). A cleared name stays in
    /// the file, with its time. Format: DisplayNames.SharedChannelName.
    @discardableResult
    static func writeChannelSenderNames(_ names: [String: [String: DisplayNames.SharedChannelName]],
                                        in dir: URL? = nil) -> Bool {
        guard let dir = dir ?? containerURL,
              let data = try? JSONEncoder().encode(names) else { return false }
        do {
            try data.write(to: dir.appendingPathComponent("channel_sender_names.json"), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Read the map written by the main app. A file from a build before the
    /// post times (bare names) still reads, each name with no time.
    static func readChannelSenderNames(in dir: URL? = nil) -> [String: [String: DisplayNames.SharedChannelName]] {
        guard let dir = dir ?? containerURL,
              let data = try? Data(contentsOf: dir.appendingPathComponent("channel_sender_names.json")),
              let names = try? JSONDecoder().decode([String: [String: DisplayNames.SharedChannelName]].self,
                                                    from: data) else {
            return [:]
        }
        return names
    }

    // MARK: - Announce Display Name (for the NSE stack)
    //
    // The NSE starts its own copy of this device's lxmf.delivery destination,
    // and Transport answers a path request for it with that destination's
    // announce. Without the Announce Display Name the answer carries nil, and
    // every peer that takes path responses drops the user's public name until
    // the app's next announce (DISPLAY_NAMES.md §2.2, §5.1). The name lives in
    // the app's own UserDefaults, which the NSE cannot read, so the app
    // mirrors it here whenever it applies the names.

    static let announceDisplayNameFile = "announce_display_name.txt"

    /// Mirror the Announce Display Name (already cleaned; "" = none).
    /// Returns false, and says why, when it could not be written.
    @discardableResult
    static func writeAnnounceDisplayName(_ name: String, in dir: URL? = nil) -> Bool {
        guard let dir = dir ?? containerURL else {
            print("[Retichat] announce name not shared with the NSE: no App Group container")
            return false
        }
        do {
            try Data(name.utf8).write(to: dir.appendingPathComponent(announceDisplayNameFile), options: .atomic)
            return true
        } catch {
            print("[Retichat] announce name not shared with the NSE: \(error)")
            return false
        }
    }

    /// The Announce Display Name the app last mirrored; "" when none, or
    /// when the app has not mirrored one yet.
    static func readAnnounceDisplayName(in dir: URL? = nil) -> String {
        guard let dir = dir ?? containerURL,
              let data = try? Data(contentsOf: dir.appendingPathComponent(announceDisplayNameFile)) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Propagation node hashes (for NSE stack)

    /// Write the list of propagation node hashes so the NSE can sync.
    static func writePropagationNodes(_ hashes: [String]) {
        guard let dir = containerURL else { return }
        let file = dir.appendingPathComponent("propagation_nodes.txt")
        let content = hashes.joined(separator: "\n")
        try? content.data(using: .utf8)?.write(to: file, options: .atomic)
    }

    /// Read propagation node hashes written by the main app.
    static func readPropagationNodes() -> [String] {
        guard let dir = containerURL else { return [] }
        let file = dir.appendingPathComponent("propagation_nodes.txt")
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return content.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    // MARK: - Distro, for the NSE (2026-09-26)
    //
    // A push for a distro message wakes the NSE, which must pull the blob from
    // RFed (/rfed/pull) and unwrap it to show it: the distro key and the pull
    // destination are shared through the App Group. The app keeps the NSE's
    // copy of the key in step with its own (DistroManager). The NSE saves every
    // pulled blob here before anything else, since the pull drains RFed's
    // queue, and the app ingests them as a pull of its own
    // (RfedDistroClient.importNSEBlobs).

    private static let sharedDistroKeyService = "com.newendian.Retichat.distro.nse"

    private static func sharedDistroKeyQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sharedDistroKeyService,
            kSecAttrAccount as String: "distro",
            kSecAttrAccessGroup as String: appGroup,
        ]
    }

    /// App side: the NSE's copy of the distro private key. Replaces any
    /// previous copy. The app's own item (DistroManager) stays the one of
    /// record; this copy only lets the NSE read the key.
    @discardableResult
    static func storeSharedDistroKey(_ key: Data) -> OSStatus {
        SecItemDelete(sharedDistroKeyQuery() as CFDictionary)
        var add = sharedDistroKeyQuery()
        add[kSecValueData as String] = key
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil)
    }

    /// App side: the distro was forgotten.
    @discardableResult
    static func deleteSharedDistroKey() -> OSStatus {
        SecItemDelete(sharedDistroKeyQuery() as CFDictionary)
    }

    /// NSE side: the distro private key, or nil when this device has none.
    static func readSharedDistroKey() -> Data? {
        var query = sharedDistroKeyQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data, data.count == 64 else { return nil }
        return data
    }

    /// Where the NSE pulls from: the `rfed.distro.register` destination, and
    /// the RFed node's destinations its path can be seeded from (rfed.node,
    /// the node's lxmf.propagation). RFed does not announce its service
    /// destinations, so a fresh stack has no path to them: the app seeds
    /// them from these (ConnectionStateManager.requestEssentialPaths), and
    /// the NSE must too (NSEDistroPull.ensurePath). Found on the iPad
    /// 2026-09-26: without it the pull's link request left with no path and
    /// never reached RFed.
    struct DistroPullRoute: Equatable {
        let destination: String
        let sources: [String]
    }

    /// One hex hash per line: the destination, then the sources.
    static func encodeDistroPullRoute(_ route: DistroPullRoute) -> String {
        ([route.destination] + route.sources).joined(separator: "\n")
    }

    static func decodeDistroPullRoute(_ text: String) -> DistroPullRoute? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let destination = lines.first, isHash(destination) else { return nil }
        return DistroPullRoute(destination: destination, sources: lines.dropFirst().filter(isHash))
    }

    private static func isHash(_ hex: String) -> Bool {
        hex.count == 32 && hex.allSatisfy(\.isHexDigit)
    }

    /// App side (nil: this device has no distro).
    static func writeDistroPullRoute(_ route: DistroPullRoute?) {
        guard let dir = containerURL else { return }
        let file = dir.appendingPathComponent("distro_pull_route.txt")
        guard let route, isHash(route.destination) else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? Data(encodeDistroPullRoute(route).utf8).write(to: file, options: .atomic)
    }

    /// NSE side.
    static func readDistroPullRoute() -> DistroPullRoute? {
        guard let dir = containerURL,
              let text = try? String(contentsOf: dir.appendingPathComponent("distro_pull_route.txt"),
                                     encoding: .utf8) else { return nil }
        return decodeDistroPullRoute(text)
    }

    private static var nseDistroBlobDir: URL? {
        guard let dir = containerURL else { return nil }
        let blobs = dir.appendingPathComponent("nse_distro_blobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        return blobs
    }

    /// NSE side: save the blobs of one pull round, as one file written
    /// atomically (never a partial file for the app to read). Each blob is
    /// `u32 big-endian length | blob`. Returns whether they were written.
    @discardableResult
    static func saveNSEDistroBlobs(_ blobs: [Data], in dir: URL? = nil) -> Bool {
        guard !blobs.isEmpty else { return true }
        guard let dir = dir ?? nseDistroBlobDir else { return false }
        var out = Data()
        for blob in blobs {
            var len = UInt32(blob.count).bigEndian
            out.append(Data(bytes: &len, count: 4))
            out.append(blob)
        }
        let file = dir.appendingPathComponent(UUID().uuidString + ".blobs")
        do {
            try out.write(to: file, options: .atomic)
            return true
        } catch {
            NSLog("[NSE] pulled blobs not saved: %@", error.localizedDescription)
            return false
        }
    }

    /// App side: every blob the NSE saved, oldest file first; the files are
    /// deleted once read.
    static func readAndClearNSEDistroBlobs(in dir: URL? = nil) -> [Data] {
        guard let dir = dir ?? nseDistroBlobDir,
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
        let ordered = files.filter { $0.pathExtension == "blobs" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a < b
        }
        var blobs: [Data] = []
        for file in ordered {
            guard let data = try? Data(contentsOf: file) else { continue }
            var i = 0
            while i + 4 <= data.count {
                let len = data[data.startIndex + i ..< data.startIndex + i + 4]
                    .reduce(0) { ($0 << 8) | Int($1) }
                i += 4
                guard i + len <= data.count else { break }
                blobs.append(data.subdata(in: data.startIndex + i ..< data.startIndex + i + len))
                i += len
            }
            try? FileManager.default.removeItem(at: file)
        }
        return blobs
    }

    // MARK: - Channels, for the NSE (2026-09-26)
    //
    // A channel with "Push All Messages" on is woken like LXMF, and the push
    // names the channel (userInfo["rfed"]["channel"]). The NSE pulls that
    // channel from RFed (NSEChannelPull) and needs, for it, what the app
    // knows: its name (the channel message key derives from it), the
    // rfed.channel.pull destination of the channel's node, the node
    // destinations that path can be seeded from, and whether the channel's
    // "Notifications" toggle is on. The app writes them here; the NSE saves
    // every pulled blob here for the app to ingest (RfedChannelClient.importNSEBlobs).

    struct ChannelPushEntry: Codable, Equatable {
        /// Channel hash, lowercase hex.
        let channel: String
        let name: String
        /// rfed.channel.pull destination of the channel's RFed node, hex.
        let pull: String
        /// rfed.node and the node's lxmf.propagation, hex (path seeding).
        let sources: [String]
        /// The channel's "Notifications" toggle: off, the NSE saves and shows nothing.
        let notify: Bool
    }

    static func encodeChannelPushDirectory(_ entries: [ChannelPushEntry]) -> Data? {
        try? JSONEncoder().encode(entries)
    }

    static func decodeChannelPushDirectory(_ data: Data) -> [String: ChannelPushEntry] {
        guard let entries = try? JSONDecoder().decode([ChannelPushEntry].self, from: data) else { return [:] }
        return Dictionary(entries.map { ($0.channel.lowercased(), $0) }, uniquingKeysWith: { _, last in last })
    }

    /// App side: the channels with push on (an empty list removes the file).
    static func writeChannelPushDirectory(_ entries: [ChannelPushEntry]) {
        guard let dir = containerURL else { return }
        let file = dir.appendingPathComponent("channel_push_directory.json")
        guard !entries.isEmpty, let data = encodeChannelPushDirectory(entries) else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? data.write(to: file, options: .atomic)
    }

    /// NSE side: keyed by lowercase channel hex.
    static func readChannelPushDirectory() -> [String: ChannelPushEntry] {
        guard let dir = containerURL,
              let data = try? Data(contentsOf: dir.appendingPathComponent("channel_push_directory.json")) else { return [:] }
        return decodeChannelPushDirectory(data)
    }

    private static var nseChannelBlobDir: URL? {
        guard let dir = containerURL else { return nil }
        let blobs = dir.appendingPathComponent("nse_channel_blobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        return blobs
    }

    /// NSE side: save one pull round's (channel hash, blob) pairs, each
    /// stored as `channel(16) | blob` in the distro blob file format.
    @discardableResult
    static func saveNSEChannelBlobs(_ pairs: [(channel: Data, blob: Data)], in dir: URL? = nil) -> Bool {
        guard let dir = dir ?? nseChannelBlobDir else { return pairs.isEmpty }
        return saveNSEDistroBlobs(pairs.map { $0.channel + $0.blob }, in: dir)
    }

    /// App side: every pair the NSE saved, oldest first; read once.
    static func readAndClearNSEChannelBlobs(in dir: URL? = nil) -> [(channel: Data, blob: Data)] {
        guard let dir = dir ?? nseChannelBlobDir else { return [] }
        return readAndClearNSEDistroBlobs(in: dir).compactMap { record in
            guard record.count > 16 else { return nil }
            return (Data(record.prefix(16)), Data(record.dropFirst(16)))
        }
    }
}
