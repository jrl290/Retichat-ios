//
//  IdentityShareFormat.swift
//  Retichat
//
//  Shared parser/encoder for direct-contact QR codes and deep links.
//

import Foundation

struct SharedPeerIdentity: Equatable, Sendable {
    let destinationHashHex: String
    let publicKey: Data?
}

enum IdentityShareFormat {
    private static let columbaScheme = "lxma://"
    private static let legacyScheme = "lxmf://"

    static func encode(destinationHashHex: String, publicKey: Data?) -> String? {
        let hashHex = sanitizeHex(destinationHashHex)
        guard hashHex.count == 32 else { return nil }

        if let publicKey {
            guard publicKey.count == 64 else { return nil }
            return "\(columbaScheme)\(hashHex):\(publicKey.hexString)"
        }

        return "\(legacyScheme)\(hashHex)"
    }

    static func parse(_ rawValue: String) -> SharedPeerIdentity? {
        let trimmed = (rawValue.removingPercentEncoding ?? rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.hasPrefix("lxm://") else { return nil }

        let payload = stripScheme(from: trimmed)
        let hashPart: String
        let publicKeyPart: String?

        if let separator = payload.firstIndex(of: ":") {
            hashPart = String(payload[..<separator])
            publicKeyPart = String(payload[payload.index(after: separator)...])
        } else if let separator = payload.firstIndex(of: ".") {
            hashPart = String(payload[..<separator])
            publicKeyPart = String(payload[payload.index(after: separator)...])
        } else {
            hashPart = payload
            publicKeyPart = nil
        }

        let hashHex = sanitizeHex(hashPart)
        guard hashHex.count == 32 else { return nil }

        let publicKey: Data?
        if let publicKeyPart, !publicKeyPart.isEmpty {
            let publicKeyHex = sanitizeHex(publicKeyPart)
            guard publicKeyHex.count == 128,
                  let publicKeyData = Data(hexString: publicKeyHex) else {
                return nil
            }
            publicKey = publicKeyData
        } else {
            publicKey = nil
        }

        return SharedPeerIdentity(destinationHashHex: hashHex, publicKey: publicKey)
    }

    private static func stripScheme(from value: String) -> String {
        if value.hasPrefix(columbaScheme) {
            return String(value.dropFirst(columbaScheme.count))
        }
        if value.hasPrefix(legacyScheme) {
            return String(value.dropFirst(legacyScheme.count))
        }
        return value
    }

    private static func sanitizeHex(_ value: String) -> String {
        value.filter { "0123456789abcdef".contains($0) }
    }
}