//
//  PropagationNodeManager.swift
//  Retichat
//
//  Shuffled propagation node hashes with failover rotation.
//  Mirrors the Android PropagationNodeManager.
//

import Foundation

final class PropagationNodeManager {
    static let shared = PropagationNodeManager()

    /// Hardcoded propagation node destination hashes.
    private let nodeHashes: [String] = [
        "813be36e005df166d8b168d16e69e4ab",
        "e17f5ca5bc8aee7bdeb87a04d7e2fc93",
        "bfce1340fca06dad950deb1024565912",
        "1726dbf12e234884eba5bf43b35becf2",
        "ae3506510f368373eb66d78fd400d14c",
        "fcb25c1e995a6753dd019f06d766abea",
        "64bba2ef4be2b514d2d02e52bbe454ad",
        "ac3f4050a30e5e5e7a2c4b1a11e4f78a",
        "e362aae7ff61e4dc75e84f0a5d67d2e7",
        "96f6a453419ea00c56e74c1a03728a71",
        "f52e34bc9e1ed689d2f9383c3fb7a1fc",
        "a431a573a4789bb2a4ee8b8a3ec61b94",
        "0b30a1e1b0e3ad86f12c15925e910e84",
        "8b8a9b1f3e1d6dc2e0cb8a3e6c9b3eaf",
        "37499048d4e4bbef5f2b38eb46fe45a3",
        "26b63f2a1e1d476c8e3d7a0b9c8f5e2d",
        "c89b4da064bf66d280f0ef4db08b8a73",
    ]

    private var shuffledNodes: [String] = []
    private var currentIndex = 0
    /// Hash injected from user settings (rfed's lxmf.propagation destination).
    /// Stored separately so `reshuffle()` and `rotateToNext()` can preserve it.
    private var userConfiguredHash: String? = nil

    private init() {
        shuffledNodes = nodeHashes.shuffled()
    }

    /// Set (or clear) a user-configured propagation node hash, e.g. rfed's
    /// `lxmf.propagation` destination.  When set, it is inserted at the front
    /// of the active list so it is tried first on the next poll cycle.
    /// Pass an empty string to remove a previously configured node.
    func setUserConfiguredNode(_ hash: String) {
        let trimmed = hash.trimmingCharacters(in: .whitespaces).lowercased()
        // Remove any previously injected user hash
        if let prev = userConfiguredHash {
            shuffledNodes.removeAll { $0 == prev }
        }
        guard !trimmed.isEmpty, trimmed.count == 32,
              trimmed.allSatisfy({ $0.isHexDigit }) else {
            userConfiguredHash = nil
            return
        }
        userConfiguredHash = trimmed
        // Ensure it isn't a duplicate of one of the built-in nodes, then prepend
        shuffledNodes.removeAll { $0 == trimmed }
        shuffledNodes.insert(trimmed, at: 0)
        currentIndex = 0
    }

    /// Get the current propagation node hash as Data (16 bytes).
    func currentNode() -> Data? {
        guard !shuffledNodes.isEmpty else { return nil }
        let hex = shuffledNodes[currentIndex % shuffledNodes.count]
        return Data(hexString: hex)
    }

    /// Current failover order as lowercase 32-char hex hashes, starting with
    /// the node that will be tried next. Used by the NSE/background path so it
    /// preserves the same failover pool as the foreground app.
    func orderedNodeHashes() -> [String] {
        guard !shuffledNodes.isEmpty else { return [] }
        let start = currentIndex % shuffledNodes.count
        return (0..<shuffledNodes.count).map { offset in
            shuffledNodes[(start + offset) % shuffledNodes.count]
        }
    }

    /// Rotate to next node on failure.
    func rotateToNext() {
        currentIndex = (currentIndex + 1) % shuffledNodes.count
    }

    /// Reshuffle the list (keeps user-configured node at the front if set).
    func reshuffle() {
        shuffledNodes = nodeHashes.shuffled()
        if let userHash = userConfiguredHash {
            shuffledNodes.removeAll { $0 == userHash }
            shuffledNodes.insert(userHash, at: 0)
        }
        currentIndex = 0
    }
}

// MARK: - Data hex helper

extension Data {
    nonisolated init?(hexString: String) {
        let hex = hexString.replacingOccurrences(of: " ", with: "")
        guard hex.count % 2 == 0 else { return nil }

        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }

    nonisolated var hexString: String {
        return map { String(format: "%02x", $0) }.joined()
    }
}
