import Foundation

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
    }

    /// Append a message delivered by the NSE.
    static func appendNSEMessage(_ message: NSEMessage) {
        guard let dir = containerURL else { return }
        let file = dir.appendingPathComponent("nse_messages.json")
        var messages = loadMessages(from: file)
        messages.append(message)
        if let data = try? JSONEncoder().encode(messages) {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Read and remove all NSE-delivered messages.
    static func readAndClearNSEMessages() -> [NSEMessage] {
        guard let dir = containerURL else { return [] }
        let file = dir.appendingPathComponent("nse_messages.json")
        let messages = loadMessages(from: file)
        try? FileManager.default.removeItem(at: file)
        return messages
    }

    private static func loadMessages(from file: URL) -> [NSEMessage] {
        guard let data = try? Data(contentsOf: file),
              let msgs = try? JSONDecoder().decode([NSEMessage].self, from: data) else {
            return []
        }
        return msgs
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
