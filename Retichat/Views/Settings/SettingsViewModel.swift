//
//  SettingsViewModel.swift
//  Retichat
//
//  Thin state wrapper for settings screen.
//  Mirrors Android SettingsViewModel.kt.
//

import SwiftUI
import Combine
import CryptoKit
import SwiftData

/// Lightweight snapshot of an interface config for pending edits.
struct PendingInterface: Identifiable, Equatable {
    var id: String
    /// One of `InterfaceKind.rawValue`.
    var type: String
    var name: String
    var targetHost: String
    var targetPort: Int
    var enabled: Bool
    /// Type-specific JSON config (e.g. `RNodeInterfaceProfile`). nil for TCP.
    var configJSON: String?

    var kind: InterfaceKind { InterfaceKind(rawValue: type) ?? .tcpClient }
}

@MainActor
class SettingsViewModel: ObservableObject {
    // The three names of DISPLAY_NAMES.md §6, independent, all empty by default.
    @Published var announceDisplayName: String
    @Published var messageDisplayName: String
    @Published var channelDisplayName: String
    @Published var rfedNodeIdentityHash: String
    @Published var rfedLxmfPropOverride: String
    @Published var filterStrangers: Bool
    @Published var defaultTcpEnabled: Bool
    @Published var rtnodeBluetoothEnabled: Bool
    @Published var pendingInterfaces: [PendingInterface]

    // Baseline captured at init; updated after Apply so hasChanges resets.
    private var originalAnnounceDisplayName: String
    private var originalMessageDisplayName: String
    private var originalChannelDisplayName: String
    private var originalRfedNodeIdentityHash: String
    private var originalRfedLxmfPropOverride: String
    private var originalFilterStrangers: Bool
    private var persistedFilterStrangers: Bool
    private var originalDefaultTcpEnabled: Bool
    private var originalRtnodeBluetoothEnabled: Bool
    private var originalInterfaces: [PendingInterface]

    /// True when any setting differs from the values present when the screen opened (or last Apply).
    var hasChanges: Bool {
        namesChanged ||
        filterStrangers != persistedFilterStrangers ||
        needsRestart
    }

    /// A display name differs from what was saved. Names apply through the
    /// router's setters with no stack restart (DISPLAY_NAMES.md §6).
    var namesChanged: Bool {
        announceDisplayName != originalAnnounceDisplayName ||
        messageDisplayName != originalMessageDisplayName ||
        channelDisplayName != originalChannelDisplayName
    }

    /// Only these settings are read at stack start (the generated config,
    /// the RFed node's destinations, the propagation node), so only they
    /// restart the stack on Apply.
    var needsRestart: Bool {
        rfedNodeIdentityHash != originalRfedNodeIdentityHash ||
        rfedLxmfPropOverride != originalRfedLxmfPropOverride ||
        defaultTcpEnabled != originalDefaultTcpEnabled ||
        rtnodeBluetoothEnabled != originalRtnodeBluetoothEnabled ||
        pendingInterfaces != originalInterfaces
    }

    /// True if the given pending interface row hasn't been applied yet, or
    /// has been edited since the last Apply. Used by the settings list to
    /// distinguish "not yet applied" from "applied but offline" so the
    /// status dot doesn't lie about a not-yet-saved row.
    func isUnsaved(_ iface: PendingInterface) -> Bool {
        guard let original = originalInterfaces.first(where: { $0.id == iface.id }) else {
            return true
        }
        return original != iface
    }

    init() {
        let prefs = UserPreferences.shared
        self.announceDisplayName = prefs.announceDisplayName
        self.messageDisplayName = prefs.messageDisplayName
        self.channelDisplayName = prefs.channelDisplayName
        // The node in use, the default included, is shown in the field: no
        // hidden fallback behind a blank one.
        self.rfedNodeIdentityHash = prefs.effectiveRfedNodeIdentityHash
        self.rfedLxmfPropOverride = prefs.rfedLxmfPropOverride
        self.filterStrangers = prefs.filterStrangers
        self.defaultTcpEnabled = prefs.defaultTcpEnabled
        self.rtnodeBluetoothEnabled = prefs.rtnodeBluetoothEnabled
        self.originalAnnounceDisplayName = prefs.announceDisplayName
        self.originalMessageDisplayName = prefs.messageDisplayName
        self.originalChannelDisplayName = prefs.channelDisplayName
        self.originalRfedNodeIdentityHash = prefs.effectiveRfedNodeIdentityHash
        self.originalRfedLxmfPropOverride = prefs.rfedLxmfPropOverride
        self.originalFilterStrangers = prefs.filterStrangers
        self.persistedFilterStrangers = prefs.filterStrangers
        self.originalDefaultTcpEnabled = prefs.defaultTcpEnabled
        self.originalRtnodeBluetoothEnabled = prefs.rtnodeBluetoothEnabled
        self.pendingInterfaces = []
        self.originalInterfaces = []
    }

    /// Load interface configs from SwiftData into pending state.
    func loadInterfaces(from repository: ChatRepository) {
        let ifaces = repository.interfaces().map {
            PendingInterface(id: $0.id, type: $0.type, name: $0.name,
                             targetHost: $0.targetHost, targetPort: $0.targetPort,
                             enabled: $0.enabled, configJSON: $0.configJSON)
        }
        pendingInterfaces = ifaces
        originalInterfaces = ifaces
    }

    /// Persist all settings to UserPreferences. Call before restarting the service.
    /// The names are saved cleaned exactly as the router cleans them (§3,
    /// lxmf_display_name_clean; the announce name with the announce rules),
    /// and the fields show the cleaned value: what goes out.
    func apply() {
        let prefs = UserPreferences.shared
        announceDisplayName = LxmfClient.cleanDisplayName(announceDisplayName, announce: true) ?? ""
        messageDisplayName = LxmfClient.cleanDisplayName(messageDisplayName) ?? ""
        channelDisplayName = LxmfClient.cleanDisplayName(channelDisplayName) ?? ""
        prefs.announceDisplayName = announceDisplayName
        prefs.messageDisplayName = messageDisplayName
        prefs.channelDisplayName = channelDisplayName
        prefs.defaultTcpEnabled = defaultTcpEnabled
        prefs.rtnodeBluetoothEnabled = rtnodeBluetoothEnabled
        prefs.rfedNodeIdentityHash = rfedNodeIdentityHash
        // rfed.notify and lxmf.propagation are derived from the node when they
        // are used (UserPreferences); only the explicit override is saved.
        prefs.rfedLxmfPropOverride = rfedLxmfPropOverride
        prefs.filterStrangers = filterStrangers
    }

    /// Persist the stranger-filter toggle immediately. This gate is enforced
    /// in app code, so it must not depend on the separate Apply/restart flow.
    func persistFilterStrangersLive() {
        UserPreferences.shared.filterStrangers = filterStrangers
        persistedFilterStrangers = filterStrangers
    }

    /// Commit pending interface changes to SwiftData.
    func applyInterfaces(to repository: ChatRepository) {
        let existing = repository.interfaces()
        let pendingIds = Set(pendingInterfaces.map { $0.id })

        // Delete removed interfaces
        for iface in existing where !pendingIds.contains(iface.id) {
            repository.deleteInterface(id: iface.id)
        }

        let existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for pending in pendingInterfaces {
            if let iface = existingById[pending.id] {
                // Update existing
                iface.type = pending.type
                iface.name = pending.name
                iface.targetHost = pending.targetHost
                iface.targetPort = pending.targetPort
                iface.enabled = pending.enabled
                iface.configJSON = pending.configJSON
                try? iface.modelContext?.save()
            } else {
                // Add new
                let newIface = InterfaceConfigEntity(
                    id: pending.id, type: pending.type, name: pending.name,
                    targetHost: pending.targetHost, targetPort: pending.targetPort,
                    enabled: pending.enabled, configJSON: pending.configJSON
                )
                repository.addInterface(newIface)
            }
        }
    }

    /// Restore all settings to the values they had when the screen opened.
    func revert() {
        announceDisplayName = originalAnnounceDisplayName
        messageDisplayName = originalMessageDisplayName
        channelDisplayName = originalChannelDisplayName
        rfedNodeIdentityHash = originalRfedNodeIdentityHash
        rfedLxmfPropOverride = originalRfedLxmfPropOverride
        filterStrangers = originalFilterStrangers
        UserPreferences.shared.filterStrangers = originalFilterStrangers
        persistedFilterStrangers = originalFilterStrangers
        defaultTcpEnabled = originalDefaultTcpEnabled
        UserPreferences.shared.defaultTcpEnabled = originalDefaultTcpEnabled
        rtnodeBluetoothEnabled = originalRtnodeBluetoothEnabled
        UserPreferences.shared.rtnodeBluetoothEnabled = originalRtnodeBluetoothEnabled
        pendingInterfaces = originalInterfaces
    }

    /// Bluetooth is not allowed for Retichat, and RTNodeBluetoothCoordinator
    /// has saved the Nearby RTNode switch off. Shown off, and off is the
    /// baseline too: not an unapplied change, and Revert cannot save it on.
    func rtnodeBluetoothDenied() {
        rtnodeBluetoothEnabled = false
        originalRtnodeBluetoothEnabled = false
    }

    /// Reset the dirty baseline to current values (call after Apply).
    func markClean() {
        objectWillChange.send()
        originalAnnounceDisplayName = announceDisplayName
        originalMessageDisplayName = messageDisplayName
        originalChannelDisplayName = channelDisplayName
        originalRfedNodeIdentityHash = rfedNodeIdentityHash
        originalRfedLxmfPropOverride = rfedLxmfPropOverride
        originalFilterStrangers = filterStrangers
        persistedFilterStrangers = filterStrangers
        originalDefaultTcpEnabled = defaultTcpEnabled
        originalRtnodeBluetoothEnabled = rtnodeBluetoothEnabled
        originalInterfaces = pendingInterfaces
    }

    /// Derived lxmf.propagation hex for the configured rfed node.
    /// Used as placeholder text in the LXMF propagation override field.
    var derivedLxmfPropHex: String {
        Self.rnsDestHash(identityHashHex: rfedNodeIdentityHash, app: "lxmf", aspects: ["propagation"]) ?? ""
    }

    // MARK: - Private

    /// Compute an RNS SINGLE-destination hash given a 32-char hex identity hash.
    ///
    /// Algorithm (mirrors Destination::hash in Reticulum-rust):
    ///   name_hash_trunc = SHA256(app + "." + aspects.joined("."))[0..<10]
    ///   dest_hash       = SHA256(name_hash_trunc + identity_bytes)[0..<16]
    static func rnsDestHash(identityHashHex: String, app: String, aspects: String) -> String? {
        rnsDestHash(identityHashHex: identityHashHex, app: app, aspects: [aspects])
    }

    static func rnsDestHash(identityHashHex: String, app: String, aspects: [String]) -> String? {
        let hex = identityHashHex.trimmingCharacters(in: .whitespaces).lowercased()
        guard hex.count == 32, let identityBytes = Data(hexString: hex) else { return nil }
        let name = ([app] + normalizedAspectSegments(app: app, aspects: aspects)).joined(separator: ".")
        let nameHashFull = SHA256.hash(data: Data(name.utf8))
        let nameHashTrunc = Data(nameHashFull.prefix(10))   // 80 bits
        let material = nameHashTrunc + identityBytes
        let destHashFull = SHA256.hash(data: material)
        return Data(destHashFull.prefix(16)).hexString      // 128 bits
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
}
