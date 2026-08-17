import Foundation
import Security

/// Holds this device's distro identity.
///
/// A distro identity is one LXMF identity shared by all of a person's devices.
/// Anything addressed to it is fanned out by RFed to every device registered
/// under it, so possession of the private key IS membership — there is no
/// revocation, and a leaked key means generating a new distro and re-enrolling
/// every device.
///
/// That is why the key lives in the Keychain rather than in UserDefaults or a
/// file beside the device identity: RFed SPEC §17.9 requires platform secure
/// storage, and unlike the device identity this key is *designed* to be copied
/// between devices, which makes it the more attractive thing to steal.
///
/// The key is never rendered in the UI. Adding a device is a transfer to that
/// device's LXMF address, not a copy-paste — a private key on screen is one
/// screenshot or clipboard manager away from being someone else's.
final class DistroManager: @unchecked Sendable {

    static let shared = DistroManager()

    /// `rfed-distro-private-key://<128 hex>`. Named for what it carries: the
    /// older `rfed-distro-id://` read like a public identifier.
    static let uriScheme = "rfed-distro-private-key://"
    /// Still accepted on import so a key exported by an older build is not stranded.
    static let legacyUriScheme = "rfed-distro-id://"

    private let keychainService = "com.newendian.Retichat.distro"
    private let keychainAccount = "distro-identity"
    private let lock = NSLock()

    /// Live identity handle into the Rust side; 0 when no distro is loaded.
    private(set) var handle: UInt64 = 0
    private var privateKey: Data?

    private init() {
        load()
    }

    // MARK: - State

    var has: Bool {
        lock.lock(); defer { lock.unlock() }
        return handle != 0
    }

    /// The distro's `lxmf.delivery` hash — the address senders address and feed
    /// to `requestPath`.
    ///
    /// Deliberately the only hash this class publishes. The identity hash is a
    /// different value that routes nowhere, and conflating the two is exactly
    /// why distro contact links were unreachable on the web client.
    var deliveryHashHex: String? {
        lock.lock(); defer { lock.unlock() }
        guard handle != 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: 16)
        guard retichat_distro_delivery_hash(handle, &buf, 16) == 16 else { return nil }
        return Data(buf).distroHexString
    }

    var publicKeyHex: String? {
        lock.lock(); defer { lock.unlock() }
        guard handle != 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: 64)
        guard retichat_identity_public_key(handle, &buf, 64) == 64 else { return nil }
        return Data(buf).distroHexString
    }

    /// Public contact link, safe to share openly. Carries the DELIVERY hash.
    var contactUri: String? {
        guard let delivery = deliveryHashHex, let pub = publicKeyHex else { return nil }
        return "lxma://\(delivery):\(pub)"
    }

    // MARK: - Lifecycle

    @discardableResult
    func generate() -> Bool {
        var outLen: UInt32 = 0
        guard let ptr = retichat_distro_generate(&outLen), outLen == 64 else { return false }
        let key = Data(bytes: ptr, count: Int(outLen))
        rns_free_bytes(ptr, outLen)
        return adopt(privateKey: key)
    }

    @discardableResult
    func importHex(_ hex: String) -> Bool {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == 128, let key = Data(distroHexString: trimmed) else { return false }
        return adopt(privateKey: key)
    }

    @discardableResult
    func importUri(_ uri: String) -> Bool {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in [Self.uriScheme, Self.legacyUriScheme] where trimmed.hasPrefix(scheme) {
            return importHex(String(trimmed.dropFirst(scheme.count)))
        }
        // A bare hex key is accepted too: the LXMF transfer hands over hex.
        return importHex(trimmed)
    }

    /// The private key as hex. Only for the encrypted device-to-device
    /// transfer — never for display.
    func exportHex() -> String? {
        lock.lock(); defer { lock.unlock() }
        return privateKey?.distroHexString
    }

    func forget() {
        lock.lock()
        if handle != 0 { _ = retichat_identity_destroy(handle) }
        handle = 0
        privateKey = nil
        lock.unlock()
        deleteFromKeychain()
    }

    private func adopt(privateKey key: Data) -> Bool {
        let newHandle = key.withUnsafeBytes { raw -> UInt64 in
            retichat_identity_from_bytes(
                raw.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(key.count))
        }
        guard newHandle != 0 else { return false }

        lock.lock()
        if handle != 0 { _ = retichat_identity_destroy(handle) }
        handle = newHandle
        privateKey = key
        lock.unlock()

        storeInKeychain(key)
        return true
    }

    private func load() {
        guard let key = readFromKeychain(), key.count == 64 else { return }
        let h = key.withUnsafeBytes { raw -> UInt64 in
            retichat_identity_from_bytes(
                raw.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(key.count))
        }
        guard h != 0 else {
            // A stored key that will not load is worse than none: every later
            // call fails obscurely. Drop it rather than keep it around.
            deleteFromKeychain()
            return
        }
        handle = h
        privateKey = key
    }

    // MARK: - Keychain

    private func storeInKeychain(_ key: Data) {
        deleteFromKeychain()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: key,
            // The stack runs in the background to receive fan-out, so the key
            // must be readable without the device being unlocked right then.
            // ThisDeviceOnly keeps it out of iCloud Keychain: this key is meant
            // to be transferred deliberately, not synced silently to devices
            // the user did not choose to enrol.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private func readFromKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private func deleteFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Hex

// Named distinctly rather than extending Data with a bare `hexString`: the
// project already defines that in PropagationNodeManager, and two same-named
// extensions on Data in one module is an ambiguity waiting to happen.
extension Data {
    var distroHexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(distroHexString hex: String) {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let byte = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            bytes.append(byte)
            i += 2
        }
        self = Data(bytes)
    }
}
