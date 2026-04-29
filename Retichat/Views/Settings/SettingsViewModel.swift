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
    @Published var displayName: String
    @Published var channelDisplayName: String
    @Published var rfedNodeIdentityHash: String
    @Published var rfedLxmfPropOverride: String
    @Published var filterStrangers: Bool
    @Published var pendingInterfaces: [PendingInterface]

    // Baseline captured at init; updated after Apply so hasChanges resets.
    private var originalDisplayName: String
    private var originalChannelDisplayName: String
    private var originalRfedNodeIdentityHash: String
    private var originalRfedLxmfPropOverride: String
    private var originalFilterStrangers: Bool
    private var originalInterfaces: [PendingInterface]

    /// True when any setting differs from the values present when the screen opened (or last Apply).
    var hasChanges: Bool {
        displayName != originalDisplayName ||
        channelDisplayName != originalChannelDisplayName ||
        rfedNodeIdentityHash != originalRfedNodeIdentityHash ||
        rfedLxmfPropOverride != originalRfedLxmfPropOverride ||
        filterStrangers != originalFilterStrangers ||
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
        self.displayName = prefs.displayName
        self.channelDisplayName = prefs.channelDisplayName
        self.rfedNodeIdentityHash = prefs.rfedNodeIdentityHash
        self.rfedLxmfPropOverride = prefs.rfedLxmfPropOverride
        self.filterStrangers = prefs.filterStrangers
        self.originalDisplayName = prefs.displayName
        self.originalChannelDisplayName = prefs.channelDisplayName
        self.originalRfedNodeIdentityHash = prefs.rfedNodeIdentityHash
        self.originalRfedLxmfPropOverride = prefs.rfedLxmfPropOverride
        self.originalFilterStrangers = prefs.filterStrangers
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
    func apply() {
        let prefs = UserPreferences.shared
        prefs.displayName = displayName
        prefs.channelDisplayName = channelDisplayName
        prefs.rfedNodeIdentityHash = rfedNodeIdentityHash
        prefs.rfedNotifyHash = Self.rnsDestHash(
            identityHashHex: rfedNodeIdentityHash, app: "rfed", aspects: ["notify"]
        ) ?? ""
        prefs.rfedLxmfPropOverride = rfedLxmfPropOverride
        prefs.filterStrangers = filterStrangers
        updateLxmfPropagationHash()
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
        displayName = originalDisplayName
        rfedNodeIdentityHash = originalRfedNodeIdentityHash
        rfedLxmfPropOverride = originalRfedLxmfPropOverride
        filterStrangers = originalFilterStrangers
        pendingInterfaces = originalInterfaces
    }

    /// Reset the dirty baseline to current values (call after Apply).
    func markClean() {
        objectWillChange.send()
        originalDisplayName = displayName
        originalRfedNodeIdentityHash = rfedNodeIdentityHash
        originalRfedLxmfPropOverride = rfedLxmfPropOverride
        originalFilterStrangers = filterStrangers
        originalInterfaces = pendingInterfaces
    }

    /// Derived lxmf.propagation hex for the configured rfed node.
    /// Used as placeholder text in the LXMF propagation override field.
    var derivedLxmfPropHex: String {
        Self.rnsDestHash(identityHashHex: rfedNodeIdentityHash, app: "lxmf", aspects: ["propagation"]) ?? ""
    }

    // MARK: - Private

    private func updateLxmfPropagationHash() {
        let prefs = UserPreferences.shared
        let override = rfedLxmfPropOverride.trimmingCharacters(in: .whitespaces)
        if !override.isEmpty {
            prefs.lxmfPropagationHash = override
        } else {
            prefs.lxmfPropagationHash = Self.rnsDestHash(
                identityHashHex: rfedNodeIdentityHash, app: "lxmf", aspects: ["propagation"]
            ) ?? ""
        }
    }

    /// Compute an RNS SINGLE-destination hash given a 32-char hex identity hash.
    ///
    /// Algorithm (mirrors Destination::hash in Reticulum-rust):
    ///   name_hash_trunc = SHA256(app + "." + aspects.joined("."))[0..<10]
    ///   dest_hash       = SHA256(name_hash_trunc + identity_bytes)[0..<16]
    static func rnsDestHash(identityHashHex: String, app: String, aspects: [String]) -> String? {
        let hex = identityHashHex.trimmingCharacters(in: .whitespaces).lowercased()
        guard hex.count == 32, let identityBytes = Data(hexString: hex) else { return nil }
        let name = ([app] + aspects).joined(separator: ".")
        let nameHashFull = SHA256.hash(data: Data(name.utf8))
        let nameHashTrunc = Data(nameHashFull.prefix(10))   // 80 bits
        let material = nameHashTrunc + identityBytes
        let destHashFull = SHA256.hash(data: material)
        return Data(destHashFull.prefix(16)).hexString      // 128 bits
    }
}
