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
                       distroTransfer: stash)
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

    /// Sync the Reticulum storage directory (path table + known identities)
    /// into the App Group so the NSE stack can find routes immediately.
    static func syncStorageToAppGroup(from storageDir: String) {
        guard let nseDir = nseReticulumDir() else { return }
        let fm = FileManager.default
        let destStorage = URL(fileURLWithPath: nseDir).appendingPathComponent("storage")
        try? fm.createDirectory(at: destStorage, withIntermediateDirectories: true)

        for name in ["destination_table", "known_destinations"] {
            let src = URL(fileURLWithPath: storageDir).appendingPathComponent(name)
            let dst = destStorage.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
        }
    }

    /// Sync the LXMF ratchet keys into the App Group so the NSE can decrypt
    /// ratchet-encrypted messages from the propagation node.
    ///
    /// Note: LXMRouter internally appends "/lxmf" to the storage path, so the
    /// real ratchet dir is `{lxmfStoragePath}/lxmf/ratchets/`.
    static func syncRatchetsToAppGroup(from lxmfStoragePath: String) {
        guard let nseDir = nseReticulumDir() else { return }
        let fm = FileManager.default
        let srcDir = URL(fileURLWithPath: lxmfStoragePath)
            .appendingPathComponent("lxmf")
            .appendingPathComponent("ratchets")
        let dstDir = URL(fileURLWithPath: nseDir)
            .appendingPathComponent("lxmf_storage")
            .appendingPathComponent("lxmf")
            .appendingPathComponent("ratchets")

        guard fm.fileExists(atPath: srcDir.path) else { return }
        try? fm.createDirectory(at: dstDir, withIntermediateDirectories: true)

        guard let files = try? fm.contentsOfDirectory(atPath: srcDir.path) else { return }
        for file in files where file.hasSuffix(".ratchets") {
            let src = srcDir.appendingPathComponent(file)
            let dst = dstDir.appendingPathComponent(file)
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
        }
    }

    // MARK: - Chat name map (for NSE notification titles)

    /// Write a map of peerHash → displayName so the NSE can resolve names.
    static func writeChatNames(_ names: [String: String]) {
        guard let dir = containerURL else { return }
        let file = dir.appendingPathComponent("chat_names.json")
        if let data = try? JSONEncoder().encode(names) {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Read the peerHash → displayName map written by the main app.
    static func readChatNames() -> [String: String] {
        guard let dir = containerURL else { return [:] }
        let file = dir.appendingPathComponent("chat_names.json")
        guard let data = try? Data(contentsOf: file),
              let names = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return names
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
}
