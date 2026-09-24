import Foundation
import Security

// MARK: - Public value types (bound by the Identity screen)

/// Snapshot of the loaded distro identity, for display.
///
/// nonisolated: built on whichever thread reads DistroManager, published on
/// the main actor by RfedDistroClient.
nonisolated struct DistroInfo: Equatable, Sendable {
    /// 32 hex: the distro's lxmf.delivery hash — the routable address.
    let deliveryHashHex: String
    /// 32 hex: SHA256(pub64)[0..<16]. An RNS identity hash; routes nowhere.
    let identityHashHex: String
    /// 128 hex public key.
    let publicKeyHex: String
    /// Public contact link, safe to share openly. Carries the DELIVERY hash.
    /// Android DistroCodec.contactUri; web RnsClient distro contact link.
    var contactUri: String { "lxma://\(deliveryHashHex):\(publicKeyHex)" }
}

nonisolated enum DistroKeyResult: Equatable, Sendable {
    case ok
    /// The input was not a 64-byte distro private key, or the Rust side
    /// could not build an identity from it.
    case invalidKey
    /// The Keychain refused a read, backup or write. The previous key (if
    /// any) is untouched.
    case storageFailed
}

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
/// device's LXMF address (an LXMF message with FIELD_CUSTOM_TYPE 0xFB =
/// "rfed.distro.transfer" and FIELD_CUSTOM_DATA 0xFC = the key, SPEC §17.9),
/// not a copy-paste — a private key on screen is one screenshot or clipboard
/// manager away from being someone else's.
///
/// Mirrors Android service/DistroManager.kt. The distro sends and shows; the
/// device keeps the network layer — the distro's lxmf.delivery is never
/// registered inbound, fan-out reaches the device via RFed.
///
/// nonisolated + two locks: read from ffiQueue (sendingIdentity), the distro
/// blob queue (handle), detached Keychain tasks (adopt/forget/reload) and the
/// main actor (info). Every Keychain call runs on a detached task, never on
/// the main actor (DESIGN_PRINCIPLES.md §6).
nonisolated final class DistroManager: @unchecked Sendable {

    static let shared = DistroManager()

    private let keychainService = "com.newendian.Retichat.distro"
    private let keychainAccount = "distro-identity"

    /// Guards the in-memory fields below. Never held across a Keychain call.
    private let stateLock = NSLock()
    /// Serialises every Keychain read-modify-write (adopt, forget, reload), so
    /// a backup always reads the key that the write then replaces.
    private let writeLock = NSLock()

    private enum LoadState {
        /// Nothing read yet. The first reloadIfNeeded() reads the Keychain.
        case notLoaded
        case loaded
        /// The Keychain definitively holds no key (errSecItemNotFound).
        case absent
        /// The Keychain could not be read (e.g. errSecInteractionNotAllowed
        /// before first unlock). Never overwritten: we do not know what the
        /// item holds, and it may be the only copy of the key.
        case unavailable(OSStatus)
        /// The item was read but is not a usable distro key (corrupt or
        /// wrong length). Unlike `.unavailable` we have its bytes, so
        /// adopt() backs them up under `.bak-unknown-<ts>` and replaces them —
        /// Android DistroManager.kt logs an unreadable key file and lets a
        /// later import/generate back it up and replace it. Refusing here
        /// would leave Generate/Import failing forever with no way out.
        case undecodable
    }

    // Guarded by stateLock.
    private var state: LoadState = .notLoaded
    private var _handle: UInt64 = 0
    private var privateKey: Data?
    private var _deliveryHash: Data?
    private var publicKeyHex: String?
    private var identityHashHex: String?
    /// Handles replaced by adopt() or dropped by forget(). NEVER destroyed: a
    /// send on ffiQueue may already hold one from sendingIdentity(), and
    /// message_create would then fail with "invalid source identity handle".
    /// Replacement is a rare user action, so the leak is bounded.
    private var retiredHandles: [UInt64] = []

    /// Deliberately does not touch the Keychain: the first access may be on
    /// the main actor. RfedDistroClient loads the key from a detached task
    /// (at launch, before stack start, and when protected data becomes
    /// available).
    private init() {}

    // MARK: - State

    var has: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _handle != 0
    }

    /// Live identity handle into the Rust side; 0 when no distro is loaded.
    var handle: UInt64 {
        stateLock.lock(); defer { stateLock.unlock() }
        return _handle
    }

    /// The distro's `lxmf.delivery` hash — the address senders use and the
    /// 16-byte prefix RFed's fan-out carries.
    ///
    /// The identity hash is a different value that routes nowhere; conflating
    /// the two is exactly why distro contact links were unreachable on the web
    /// client.
    var deliveryHash: Data? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _deliveryHash
    }

    var deliveryHashHex: String? { deliveryHash?.hexString }

    /// A key is stored but will not load. The Identity screen says so, and
    /// Generate/Import keep a backup of it before replacing it.
    var storedKeyUnreadable: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        if case .undecodable = state { return true }
        return false
    }

    func info() -> DistroInfo? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard _handle != 0, let delivery = _deliveryHash, let pub = publicKeyHex,
              let idHex = identityHashHex else { return nil }
        return DistroInfo(deliveryHashHex: delivery.hexString, identityHashHex: idHex, publicKeyHex: pub)
    }

    /// Source address and signing identity for an outgoing message: the
    /// distro when one is loaded, so replies reach every device, else the
    /// device. Android DistroManager.kt:141-149; web RnsClient.sendingIdentity.
    func sendingIdentity(deviceHash: Data, deviceHandle: UInt64) -> (hash: Data, handle: UInt64) {
        stateLock.lock(); defer { stateLock.unlock() }
        if _handle != 0, let delivery = _deliveryHash { return (delivery, _handle) }
        return (deviceHash, deviceHandle)
    }

    /// The private key as hex. Only for the encrypted device-to-device
    /// transfer and for "is this offer the key I already hold" — never for display.
    func exportHex() -> String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return privateKey?.hexString
    }

    // MARK: - Lifecycle

    /// Read the Keychain if nothing has been loaded yet, or if the last read
    /// failed (e.g. a background launch before first unlock). Callers:
    /// RfedDistroClient at launch, prepareForStackStart, and the
    /// protected-data-available observer — all from detached tasks.
    func reloadIfNeeded() {
        writeLock.lock(); defer { writeLock.unlock() }
        stateLock.lock()
        let needed: Bool
        switch state {
        case .notLoaded, .unavailable: needed = true
        // Re-reading an undecodable item yields the same bytes.
        case .loaded, .absent, .undecodable: needed = false
        }
        stateLock.unlock()
        if needed { loadLocked() }
    }

    func generate() -> DistroKeyResult {
        var outLen: UInt32 = 0
        guard let ptr = retichat_distro_generate(&outLen) else {
            print("[Distro] generate failed: \(DistroMessageFFI.rnsLastError())")
            return .invalidKey
        }
        let key = Data(bytes: ptr, count: Int(outLen))
        rns_free_bytes(ptr, outLen)
        guard key.count == 64 else { return .invalidKey }
        return adopt(key)
    }

    /// Accepts `rfed-distro-private-key://`, `rfed-distro-id://` or bare
    /// 128-hex, any case. Android DistroManager.importText.
    func importText(_ text: String) -> DistroKeyResult {
        guard let key = DistroCodec.parsePrivateKey(text) else { return .invalidKey }
        return adopt(key)
    }

    enum ForgetResult: Equatable, Sendable {
        case deleted
        /// The Keychain delete failed; the key may reload on next launch.
        case deleteFailed
        /// A different key was adopted after the caller captured
        /// `expectedHandle` (e.g. a transfer accepted while Forget was
        /// unregistering). Nothing was deleted: that key is the user's
        /// newest choice and has no backup.
        case superseded
    }

    /// Drop the distro: retire the handle and delete the Keychain item —
    /// only if the loaded handle is still `expectedHandle`, checked under
    /// writeLock so no adopt() can slip between the check and the delete.
    /// Does NOT unregister from RFed and does not back up — the caller
    /// unregisters first (Android IdentityScreen Forget → unregister, forget).
    func forget(expectedHandle: UInt64) -> ForgetResult {
        writeLock.lock(); defer { writeLock.unlock() }

        stateLock.lock()
        guard _handle == expectedHandle else {
            let current = _handle
            stateLock.unlock()
            print("[Distro] forget skipped: the distro changed while forgetting (handle \(expectedHandle) → \(current))")
            return .superseded
        }
        if _handle != 0 { retiredHandles.append(_handle) }
        clearCachesLocked()
        state = .absent
        stateLock.unlock()

        let status = SecItemDelete(baseQuery(account: keychainAccount) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            print("[Distro] forget: Keychain delete failed (\(status)) — the key may reload on next launch")
            return .deleteFailed
        }
        return .deleted
    }

    // MARK: - Adopt

    private struct Derived {
        let handle: UInt64
        let deliveryHash: Data
        let publicKeyHex: String
        let identityHashHex: String
    }

    /// Build an identity handle for `key` and derive its display values.
    /// Destroys the handle and returns nil if any step fails.
    private func derive(_ key: Data) -> Derived? {
        guard key.count == 64 else { return nil }
        let h = key.withUnsafeBytes { raw -> UInt64 in
            retichat_identity_from_bytes(raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                         UInt32(key.count))
        }
        guard h != 0 else { return nil }
        var hashBuf = [UInt8](repeating: 0, count: 16)
        var pubBuf = [UInt8](repeating: 0, count: 64)
        guard retichat_distro_delivery_hash(h, &hashBuf, 16) == 16,
              retichat_identity_public_key(h, &pubBuf, 64) == 64,
              let idHex = DistroCodec.identityHashHex(publicKey: Data(pubBuf))
        else {
            _ = retichat_identity_destroy(h)
            return nil
        }
        return Derived(handle: h, deliveryHash: Data(hashBuf),
                       publicKeyHex: Data(pubBuf).hexString, identityHashHex: idHex)
    }

    /// Store `key` as the distro identity and make it live.
    ///
    /// The whole read-backup-write-swap runs under writeLock. A different key
    /// already stored is first copied to `distro-identity.bak-<hash8>-<unix>`
    /// (Android DistroManager.kt:100-115): a distro key cannot be recovered
    /// from anywhere, so replacing it must never be the only copy's end.
    private func adopt(_ key: Data) -> DistroKeyResult {
        writeLock.lock(); defer { writeLock.unlock() }

        stateLock.lock()
        let wasNotLoaded: Bool
        if case .notLoaded = state { wasNotLoaded = true } else { wasNotLoaded = false }
        stateLock.unlock()
        // Learn what is stored before replacing it, so a key that could not
        // be read is never overwritten.
        if wasNotLoaded { loadLocked() }

        stateLock.lock()
        let current = state
        stateLock.unlock()
        // Only an unreadable Keychain blocks adopt. An `.undecodable` item was
        // read, so the backup below copies its bytes (as
        // `.bak-unknown-<ts>`: writeBackup cannot derive a hash from them)
        // before the write replaces it.
        if case .unavailable(let status) = current {
            print("[Distro] adopt refused: the stored key could not be read (\(status)); not overwriting it")
            return .storageFailed
        }

        guard let derived = derive(key) else { return .invalidKey }

        let (stored, readStatus) = readStoredKey()
        switch readStatus {
        case errSecSuccess:
            if let stored, stored != key {
                let backupStatus = writeBackup(of: stored)
                guard backupStatus == errSecSuccess else {
                    _ = retichat_identity_destroy(derived.handle)
                    print("[Distro] adopt refused: backup of the current key failed (\(backupStatus))")
                    return .storageFailed
                }
            }
        case errSecItemNotFound:
            break
        default:
            _ = retichat_identity_destroy(derived.handle)
            print("[Distro] adopt refused: Keychain read failed (\(readStatus))")
            return .storageFailed
        }

        let writeStatus = writeMain(key)
        guard writeStatus == errSecSuccess else {
            _ = retichat_identity_destroy(derived.handle)
            print("[Distro] adopt refused: Keychain write failed (\(writeStatus))")
            return .storageFailed
        }

        stateLock.lock()
        if _handle != 0 { retiredHandles.append(_handle) }
        setLoadedLocked(derived, key: key)
        stateLock.unlock()
        print("[Distro] distro loaded: \(derived.deliveryHash.hexString)")
        return .ok
    }

    // MARK: - Load

    /// Caller holds writeLock.
    private func loadLocked() {
        let (data, status) = readStoredKey()
        switch status {
        case errSecSuccess:
            guard let data, let derived = derive(data) else {
                // A stored key that will not load: keep the item (it may be
                // the only copy). adopt() backs it up before replacing it.
                print("[Distro] stored distro key did not load; leaving the Keychain item in place")
                stateLock.lock(); clearCachesLocked(); state = .undecodable; stateLock.unlock()
                return
            }
            stateLock.lock()
            setLoadedLocked(derived, key: data)
            stateLock.unlock()
            print("[Distro] distro loaded: \(derived.deliveryHash.hexString)")
        case errSecItemNotFound:
            stateLock.lock(); clearCachesLocked(); state = .absent; stateLock.unlock()
        default:
            print("[Distro] Keychain read failed (\(status)); will retry when protected data becomes available")
            stateLock.lock(); state = .unavailable(status); stateLock.unlock()
        }
    }

    /// Caller holds stateLock.
    private func setLoadedLocked(_ d: Derived, key: Data) {
        _handle = d.handle
        privateKey = key
        _deliveryHash = d.deliveryHash
        publicKeyHex = d.publicKeyHex
        identityHashHex = d.identityHashHex
        state = .loaded
    }

    /// Caller holds stateLock.
    private func clearCachesLocked() {
        _handle = 0
        privateKey = nil
        _deliveryHash = nil
        publicKeyHex = nil
        identityHashHex = nil
    }

    // MARK: - Keychain

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
    }

    // The stack runs in the background to receive fan-out, so the key must be
    // readable without the device being unlocked right then. ThisDeviceOnly
    // keeps it out of iCloud Keychain: this key is meant to be transferred
    // deliberately, not synced silently to devices the user did not enrol.
    private var accessibility: CFString { kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }

    /// Only errSecSuccess returns data; only errSecItemNotFound means "no key".
    /// Any other status (notably errSecInteractionNotAllowed before first
    /// unlock) is a read failure, not an absence.
    private func readStoredKey() -> (Data?, OSStatus) {
        var query = baseQuery(account: keychainAccount)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess else { return (nil, status) }
        return (out as? Data, status)
    }

    private func writeMain(_ key: Data) -> OSStatus {
        let attrs: [String: Any] = [
            kSecValueData as String: key,
            kSecAttrAccessible as String: accessibility,
        ]
        let status = SecItemUpdate(baseQuery(account: keychainAccount) as CFDictionary,
                                   attrs as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var add = baseQuery(account: keychainAccount)
        add[kSecValueData as String] = key
        add[kSecAttrAccessible as String] = accessibility
        return SecItemAdd(add as CFDictionary, nil)
    }

    /// `distro-identity.bak-<first 8 hex of the old key's delivery hash>-<unix secs>`,
    /// same service and accessibility as the main item. Android
    /// DistroManager.backupExistingKey names its file the same way.
    private func writeBackup(of oldKey: Data) -> OSStatus {
        var hash8 = "unknown"
        if let old = derive(oldKey) {
            hash8 = String(old.deliveryHash.hexString.prefix(8))
            _ = retichat_identity_destroy(old.handle)   // temporary; never published
        }
        let account = "\(keychainAccount).bak-\(hash8)-\(Int(Date().timeIntervalSince1970))"
        var add = baseQuery(account: account)
        add[kSecValueData as String] = oldKey
        add[kSecAttrAccessible as String] = accessibility
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { print("[Distro] previous distro key backed up as \(account)") }
        return status
    }
}
