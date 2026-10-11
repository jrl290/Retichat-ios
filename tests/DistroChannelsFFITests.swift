// DistroChannelsFFITests.swift
//
// The glue crate's distro outbox functions, called the way the app calls them,
// against the REAL library: RetichatBridge's Swift wrappers over the xcframework's
// static library, with the message the Rust side writes and signs read back by
// the Swift reader and checked by an independent verifier (CryptoKit). What the
// other tests cannot reach: a wrong C signature (an ABI mismatch is a crash in the
// field), a pointer or length marshalled wrong, a retain the library never
// releases, a callback with the wrong shape.
//
// It runs as a command-line binary on this Mac, built for Mac Catalyst
// (arm64-apple-ios17.6-macabi) against the xcframework's Catalyst slice: the same
// Rust code as the iPhone's, with no simulator, no app and no network (no stack
// is started, no interface is opened, nothing is sent). Needs ./build_rust.sh
// first (the xcframework is a build product, not in git).
//
// Run from the workspace root with:
//
//   { echo 'import Foundation'; \
//     sed -n '/^\/\/ BEGIN DistroInbound/,/^\/\/ END DistroInbound/p' \
//     Retichat-ios/Retichat/Services/RfedDistroClient.swift; } \
//     > /private/tmp/claude-501/DistroInbound.swift && \
//   swiftc -parse-as-library -target arm64-apple-ios17.6-macabi \
//     -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
//     -import-objc-header Retichat-ios/Retichat/Bridge/CRetichatFFI.h \
//     -o /private/tmp/claude-501/distro-channels-ffi \
//     /private/tmp/claude-501/DistroInbound.swift \
//     Retichat-ios/Retichat/Bridge/RetichatBridge.swift \
//     Retichat-ios/Retichat/Bridge/LxmfFields.swift \
//     Retichat-ios/Retichat/Services/DistroGroupSync.swift \
//     Retichat-ios/Retichat/Services/LxmfClient.swift \
//     Retichat-ios/Retichat/Services/PendingNotification.swift \
//     Retichat-ios/Retichat/Services/PropagationNodeManager.swift \
//     Retichat-ios/Retichat/Services/DistroOutbox.swift \
//     Retichat-ios/Retichat/Services/DistroChannelSync.swift \
//     Retichat-ios/Retichat/Services/DeliveryPolicy.swift \
//     Retichat-ios/Retichat/Services/GroupStatuses.swift \
//     Retichat-ios/Retichat/Services/GroupEnvelopes.swift \
//     Retichat-ios/tests/DistroChannelsFFITests.swift \
//     Retichat-ios/Frameworks/RetichatFFI.xcframework/ios-arm64_x86_64-maccatalyst/libretichat_ffi.a \
//     -Xlinker -framework -Xlinker CoreBluetooth -Xlinker -framework -Xlinker IOKit \
//     -Xlinker -framework -Xlinker Security -Xlinker -framework -Xlinker SystemConfiguration \
//     -Xlinker -framework -Xlinker CoreFoundation -lc++ -lresolv -lz -lbz2 && \
//   /private/tmp/claude-501/distro-channels-ffi

import CryptoKit
import Foundation

nonisolated(unsafe) var failures: [String] = []
nonisolated(unsafe) var checks = 0
nonisolated(unsafe) var currentTest = ""

func check(_ ok: Bool, _ what: String, line: UInt = #line) {
    checks += 1
    if !ok {
        failures.append("\(currentTest): \(what)")
        print("FAIL: \(currentTest): \(what) (line \(line))")
    }
}

func checkEqual<T: Equatable>(_ a: T, _ b: T, _ what: String, line: UInt = #line) {
    check(a == b, "\(what): got \(a), want \(b)", line: line)
}

/// The device address the pinned bytes carry (the literal the Rust writer and the Swift reader both pin).
let pinnedDevice = "0123456789abcdef0123456789abcdef"
let pinnedFields = "840cc400ccfbb3726665642e64697374726f2e6368616e6e656cccfc93a46a6f696eae7075626c69632e67656e6572616ccf0000019b76daa800ccfdd9203031323334353637383961626364656630313233343536373839616263646566"
let atMs: Int64 = 1_767_225_600_000

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

/// A fresh identity from the library: its handle, `lxmf.delivery` hash and 64-byte public key.
func newIdentity() -> (handle: UInt64, delivery: Data, publicKey: Data) {
    var len: UInt32 = 0
    let ptr = retichat_distro_generate(&len)!
    let key = Data(bytes: ptr, count: Int(len))
    rns_free_bytes(ptr, len)
    let handle = key.withUnsafeBytes { retichat_identity_from_bytes($0.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(key.count)) }
    var hash = [UInt8](repeating: 0, count: 16)
    check(retichat_distro_delivery_hash(handle, &hash, 16) == 16, "the delivery hash")
    var pub = [UInt8](repeating: 0, count: 64)
    check(retichat_identity_public_key(handle, &pub, 64) == 64, "the public key")
    return (handle, Data(hash), Data(pub))
}

/// What the bridge calls back, counted.
final class CountingSink: UploadSink, @unchecked Sendable {
    private let lock = NSLock()
    private var counts = (proved: 0, lost: 0, neverLeft: 0)
    var provedCount: Int { lock.lock(); defer { lock.unlock() }; return counts.proved }
    var lostCount: Int { lock.lock(); defer { lock.unlock() }; return counts.lost }
    var neverLeftCount: Int { lock.lock(); defer { lock.unlock() }; return counts.neverLeft }
    func proved() { lock.lock(); counts.proved += 1; lock.unlock() }
    func lost() { lock.lock(); counts.lost += 1; lock.unlock() }
    func neverLeft() { lock.lock(); counts.neverLeft += 1; lock.unlock() }
}

/// The message's hash (32 bytes) once it is packed.
func messageHash(_ handle: UInt64) -> Data? {
    var buf = [UInt8](repeating: 0, count: 32)
    let len = lxmf_message_hash(handle, &buf, 32)
    return len == 32 ? Data(buf) : nil
}

let bridge = RetichatBridge.shared

// MARK: - The message the Rust side writes, signs and packs once

func theWrapperWritesCExactlyAsPinnedAndTheSwiftReaderAndAnIndependentVerifierTakeIt() {
    let distro = newIdentity()
    let msg = bridge.messageCreate(destHash: distro.delivery, sourceHash: distro.delivery, content: "", title: "",
                                   method: LxmfMethod.direct, identityHandle: distro.handle)
    check(msg != 0, "a message from the distro to the distro")
    check(bridge.messageSetDistroChannelSync(handle: msg, op: "join", name: "public.general", atMs: atMs, deviceHex: pinnedDevice),
          "C's fields are written")
    guard let packed = bridge.messagePack(handle: msg) else { check(false, "packed"); return }
    // Never packed again: the same bytes.
    checkEqual(bridge.messagePack(handle: msg), packed, "packed once")

    // dest | src | signature | payload, payload = [timestamp f64, title bin, content bin, fields].
    checkEqual(packed.prefix(16), distro.delivery, "dest is the distro")
    checkEqual(packed.dropFirst(16).prefix(16), distro.delivery, "src is the distro")
    let signature = packed.dropFirst(32).prefix(64)
    let payload = packed.dropFirst(96)
    let bytes = [UInt8](payload)
    check(bytes.count > 15 && bytes[0] == 0x94 && bytes[1] == 0xcb, "a four-element array that starts with an f64 timestamp")
    // 0x94, f64 (9 bytes), empty bin (2), empty bin (2): the fields map is the rest, as the sender packed it.
    let fieldsBytes = Data(bytes[(1 + 9 + 2 + 2)...])
    checkEqual(hex(fieldsBytes), pinnedFields, "the very bytes the Rust writer and the Swift reader both pin")

    // The Swift reader takes what the library wrote.
    let marker = DistroChannelSync.read(fieldsBytes)
    checkEqual(marker?.sync, DistroChannelSync.Sync(op: "join", name: "public.general", atMs: atMs), "the reader takes the action")
    checkEqual(marker?.byHex ?? "", pinnedDevice, "and the device")
    check(marker?.problem == nil, "with no problem")

    // An independent verifier: the signature a receiver checks (SPEC §17.11 rule 2) is the distro's
    // Ed25519 signature over dest || src || payload || SHA-256(dest || src || payload).
    let hashed = packed.prefix(32) + payload
    let digest = Data(SHA256.hash(data: hashed))
    let signed = hashed + digest
    let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: distro.publicKey.suffix(32))
    check(publicKey?.isValidSignature(signature, for: signed) == true, "the signature is the distro's, over what the spec says")
    checkEqual(messageHash(msg), digest, "the message hash is that SHA-256")
    check(publicKey?.isValidSignature(signature, for: signed + [0]) == false, "and the verifier is not vacuous")
    _ = lxmf_message_destroy(msg)
}

func theWrapperRefusesAMalformedMessageAndWritesNothing() {
    let distro = newIdentity()
    let msg = bridge.messageCreate(destHash: distro.delivery, sourceHash: distro.delivery, content: "x", title: "",
                                   method: LxmfMethod.direct, identityHandle: distro.handle)
    for (op, name, at, device, why) in [
        ("Join", "public.x", Int64(1), pinnedDevice, "join"),
        ("join", "", 1, pinnedDevice, "names its channel"),
        ("join", "public.x", -1, pinnedDevice, "negative"),
        ("join", "public.x", Int64(1) << 53, pinnedDevice, "2^53"),
        ("join", "public.x", 1, "xyz", "32 hex"),
    ] {
        check(!bridge.messageSetDistroChannelSync(handle: msg, op: op, name: name, atMs: at, deviceHex: device), "refused: \(op) \(name) \(at)")
        check(bridge.rnsLastError()?.contains(why) == true, "says why (\(why)): \(bridge.rnsLastError() ?? "nil")")
    }
    check(!bridge.messageSetDistroChannelSync(handle: 0, op: "join", name: "public.x", atMs: 1, deviceHex: pinnedDevice), "no handle")
    check(bridge.messagePack(handle: 0) == nil, "no pack for no handle")
    guard let packed = bridge.messagePack(handle: msg) else { check(false, "packed"); return }
    check(packed.range(of: Data("rfed.distro.channel".utf8)) == nil, "a refused call wrote nothing")
    _ = lxmf_message_destroy(msg)
}

// MARK: - The upload, with no announce heard and no link held

func anUploadIsNotBuiltForANodeWhoseAnnounceWasNotHeard() {
    let distro = newIdentity()
    let msg = bridge.messageCreate(destHash: distro.delivery, sourceHash: distro.delivery, content: "x", title: "",
                                   method: LxmfMethod.direct, identityHandle: distro.handle)
    guard bridge.messageSetDistroChannelSync(handle: msg, op: "leave", name: "public.x", atMs: 5, deviceHex: pinnedDevice),
          let packed = bridge.messagePack(handle: msg) else { check(false, "made"); return }
    let node = Data(repeating: 0x42, count: 16)
    check(bridge.propagationBuildUpload(distroPublicKey: distro.publicKey, packed: packed, node: node) == nil,
          "no stamp cost is known for a node that was not heard")
    check(bridge.rnsLastError()?.contains("not known") == true, "and it says so: \(bridge.rnsLastError() ?? "nil")")
    check(bridge.propagationBuildUpload(distroPublicKey: distro.publicKey, packed: packed, node: Data([1, 2, 3])) == nil,
          "a node that is not 16 bytes is refused")
    _ = lxmf_message_destroy(msg)
}

func aNodeThatIsNotHeldHasNoLinkAndAnUploadOnItIsRefusedWithItsSinkReleasedOnce() {
    let node = Data(repeating: 0x43, count: 16)
    check(bridge.propagationLink(node: node) == nil, "no link is held for the node")
    var released = 0
    for round in 1...3 {
        weak var weakSink: CountingSink?
        do {
            let sink = CountingSink()
            weakSink = sink
            let started = bridge.propagationUpload(node: node, upload: Data([1, 2, 3]), sink: sink)
            check(started == nil, "round \(round): an upload with no ACTIVE link does not leave")
            check(bridge.rnsLastError()?.contains("no active link") == true, "round \(round): and says so")
            check(sink.provedCount == 0 && sink.lostCount == 0, "round \(round): nothing is reported for an upload that never left")
        }
        // The library took a retain on the sink's box with the call and released it once: nothing holds the sink now.
        if weakSink == nil { released += 1 }
    }
    checkEqual(released, 3, "the library released every sink it was given (the retain it took is balanced)")
    check(bridge.propagationUpload(node: Data([1]), upload: Data([1]), sink: CountingSink()) == nil, "a node of 1 byte is refused")
    check(bridge.propagationUpload(node: node, upload: Data(), sink: CountingSink()) == nil, "no bytes are refused")
}

// MARK: - The callbacks, called as the library calls them

func theUploadTrampolinesReportEachEventAndTheReleaseFreesTheSink() {
    weak var weakSink: CountingSink?
    do {
        let sink = CountingSink()
        weakSink = sink
        // The context the bridge hands the library: a retain the library owns.
        let context = Unmanaged.passRetained(PropagationUploadSinkBox(sink)).toOpaque()
        propagationUploadEvent(context: context, event: 2)   // the receipt timed out
        checkEqual(sink.lostCount, 1, "event 2 is the loss")
        checkEqual(sink.provedCount, 0, "and not a proof")
        propagationUploadEvent(context: context, event: 1)   // a late proof
        checkEqual(sink.provedCount, 1, "event 1 is the proof, after it")
        checkEqual(sink.lostCount, 1, "and not another loss")
        // A Resource whose first advertisement no interface carried (2026-10-10, Stage 0).
        propagationUploadEvent(context: context, event: 3)
        checkEqual(sink.neverLeftCount, 1, "event 3 is never-left")
        check(sink.provedCount == 1 && sink.lostCount == 1, "and neither a proof nor a loss")
        propagationUploadEvent(context: context, event: 9)   // no such event
        check(sink.provedCount == 1 && sink.lostCount == 1 && sink.neverLeftCount == 1, "no other event is told")
        check(weakSink != nil, "the sink lives until the library releases it")
        propagationUploadRelease(context: context)
    }
    check(weakSink == nil, "released")
    propagationUploadEvent(context: nil, event: 1)
    propagationUploadRelease(context: nil)
    check(true, "a nil context is ignored")
}

func aLinkEventReachesTheHandlerWithItsLinkOrNone() {
    final class Seen: @unchecked Sendable {
        let lock = NSLock()
        var events: [(Data, UInt8, Data?)] = []
    }
    let seen = Seen()
    check(bridge.propagationLinkEventsRegister(handler: { dest, status, id in
        seen.lock.lock(); seen.events.append((dest, status, id)); seen.lock.unlock()
    }), "the handler is registered with the library")
    let dest = [UInt8](repeating: 7, count: 16), id = [UInt8](repeating: 9, count: 16)
    propagationLinkEvent(context: nil, dest: dest, destLen: 16, status: RetichatBridge.appLinkActive, linkId: id, linkIdLen: 16)
    propagationLinkEvent(context: nil, dest: dest, destLen: 16, status: 4, linkId: nil, linkIdLen: 0)
    propagationLinkEvent(context: nil, dest: nil, destLen: 0, status: 3, linkId: id, linkIdLen: 16)
    checkEqual(seen.events.count, 2, "an event with no destination is ignored")
    checkEqual(seen.events.first?.1 ?? 0, 3, "ACTIVE")
    checkEqual(seen.events.first?.2, Data(id), "with its link")
    check(seen.events.last?.2 == nil, "a disconnection carries none")
    // A STALE link's recovery is told like an establishment: its own status, and the link.
    propagationLinkEvent(context: nil, dest: dest, destLen: 16, status: RetichatBridge.appLinkRecovered, linkId: id, linkIdLen: 16)
    checkEqual(seen.events.count, 3, "a recovery is told")
    checkEqual(seen.events.last?.1 ?? 0, 5, "RECOVERED")
    checkEqual(seen.events.last?.2, Data(id), "with its link")
    bridge.propagationLinkEventsClear()
    propagationLinkEvent(context: nil, dest: dest, destLen: 16, status: 3, linkId: id, linkIdLen: 16)
    propagationLinkEvent(context: nil, dest: dest, destLen: 16, status: RetichatBridge.appLinkRecovered, linkId: id, linkIdLen: 16)
    checkEqual(seen.events.count, 3, "cleared, a status change reaches nobody")
}

func anInterfaceUpEventReachesTheHandlerWithItsNameUntilItIsCleared() {
    // The library's own up-edge listener (Transport::set_interface_online) is exercised by the glue crate's cargo
    // test; here the registration and the trampoline are the real ones, called as the library calls them.
    final class Seen: @unchecked Sendable {
        let lock = NSLock()
        var names: [String] = []
    }
    let seen = Seen()
    check(bridge.interfaceUpRegister(handler: { name in
        seen.lock.lock(); seen.names.append(name); seen.lock.unlock()
    }), "the handler is registered with the library")
    check(bridge.interfaceUpRegister(handler: { name in
        seen.lock.lock(); seen.names.append(name); seen.lock.unlock()
    }), "registered again, as every start of the stack does, it is no error")
    let name = Array("tcp-direct".utf8)
    interfaceUpEvent(context: nil, name: name, nameLen: UInt32(name.count))
    interfaceUpEvent(context: nil, name: nil, nameLen: 0)
    interfaceUpEvent(context: nil, name: name, nameLen: 0)
    checkEqual(seen.names, ["tcp-direct"], "an event with no name is ignored, and the name arrives whole")
    bridge.interfaceUpClear()
    interfaceUpEvent(context: nil, name: name, nameLen: UInt32(name.count))
    checkEqual(seen.names.count, 1, "cleared, an up-edge reaches nobody")
    check(bridge.interfaceUpRegister(handler: { _ in }), "and it registers again after a clear")
    bridge.interfaceUpClear()
}

// MARK: - Member statuses and keys, through the real library (RFed-spec Group.md, 2026-10-06)

/// Pack an outbound message once and read it back as a status's element is read: through the library's own unpack and check.
func unpacked(_ packed: Data) -> UnpackedGroupMessage? { bridge.groupUnpack(packed).message }

/// An accept or leave the library makes, written as GroupChatManager writes it (GroupEnvelopes, both forms are the sender's), packed once.
/// `signer` is the identity that signs; `source` the one whose hash and key it carries.
func realControl(_ action: String, source: (handle: UInt64, delivery: Data, publicKey: Data),
                 signer: (handle: UInt64, delivery: Data, publicKey: Data)? = nil, to: Data, groupId: String,
                 carryKey: Bool = true) -> Data? {
    let msg = bridge.messageCreate(destHash: to, sourceHash: source.delivery, content: "", title: "",
                                   method: LxmfMethod.direct, identityHandle: (signer ?? source).handle)
    guard msg != 0 else { return nil }
    defer { _ = lxmf_message_destroy(msg) }
    let own = carryKey ? GroupEnvelopes.ownKeyEntry(selfHex: hex(source.delivery), publicKey: source.publicKey) : nil
    let entries = action == GroupAction.accept
        ? GroupEnvelopes.accept(groupId: groupId, selfHex: hex(source.delivery), ownKey: own)
        : GroupEnvelopes.leave(groupId: groupId, selfHex: hex(source.delivery), ownKey: own)
    for entry in entries { check(LxmfClient.messageSetGroupEntry(msg, entry.entry, .str(entry.value)), "the entry \(entry.entry) is written") }
    return bridge.messagePack(handle: msg)
}

func aRealAcceptCarryingItsSendersKeyIsValidatedByThatKeyAndAForgeryIsInvalidAndNoKeyIsUnverifiable() {
    let alice = newIdentity(), mallory = newIdentity(), creator = newIdentity()
    let group = String(repeating: "5e", count: 16)
    guard let accept = realControl(GroupAction.accept, source: alice, to: creator.delivery, groupId: group) else { check(false, "an accept"); return }
    // Nobody holds alice's key: the key the accept carries decides, and it validates.
    guard let u = unpacked(accept) else { check(false, "the library unpacks it"); return }
    checkEqual(u.signature, DeliveryPolicy.Signature.validated, "validated by the key it carries")
    checkEqual(u.senderKey, alice.publicKey, "and that key is alice's own, bound to her address")
    checkEqual(u.source, alice.delivery, "from alice")
    checkEqual(u.destination, creator.delivery, "to the creator")
    let fields = LxmfFieldsDecoder.decode(u.fieldsRaw)
    checkEqual(fields.groupId, group, "the group")
    checkEqual(fields.groupAction, GroupAction.accept, "the action")
    checkEqual(fields.groupMemberKeys?[hex(alice.delivery)], alice.publicKey.base64EncodedString(), "the entry as GroupEnvelopes spells it")
    // The message hash the library reports is the LXMF hash: SHA-256 of destination, source and payload.
    checkEqual(u.hash.count, 32, "a 32-byte message hash")

    // A signature that is not alice's under her name and her key (one bit of it flipped, as a forger's is): invalid, never counted.
    var tampered = accept
    tampered[40] ^= 0x01
    if let f = unpacked(tampered) {
        checkEqual(f.signature, DeliveryPolicy.Signature.invalid, "a signature that does not verify under the key it carries: invalid")
        checkEqual(f.senderKey, alice.publicKey, "the key it carries is still reported (the group rule drops it)")
    } else { check(false, "a forgery") }
    // The library signs as the identity that makes the message: mallory cannot sign as alice with it, so her message is her own,
    // and carries alice's key under alice's hash, which is not its source's: no key binds, and she is not heard as alice.
    if let impostor = realControl(GroupAction.accept, source: alice, signer: mallory, to: creator.delivery, groupId: group),
       let i = unpacked(impostor) {
        check(i.source != alice.delivery || i.signature != DeliveryPolicy.Signature.validated, "mallory's message is never validated as alice's")
    } else { check(false, "an impostor's message") }

    // No key carried and none held: unverifiable, as a client from before this change sends it.
    if let keyless = realControl(GroupAction.leave, source: alice, to: creator.delivery, groupId: group, carryKey: false),
       let k = unpacked(keyless) {
        checkEqual(k.signature, DeliveryPolicy.Signature.sourceUnknown, "no key carried and none held: unverifiable")
        check(k.senderKey == nil, "no key reported")
    } else { check(false, "a keyless leave") }

    // A key that does not bind (another member's key under alice's hash) is no key.
    let msg = bridge.messageCreate(destHash: creator.delivery, sourceHash: alice.delivery, content: "", title: "",
                                   method: LxmfMethod.direct, identityHandle: mallory.handle)
    let entries = GroupEnvelopes.accept(groupId: group, selfHex: hex(alice.delivery),
                                        ownKey: GroupStatuses.keyEntry(hashHex: hex(alice.delivery), publicKey: mallory.publicKey))
    for entry in entries { _ = LxmfClient.messageSetGroupEntry(msg, entry.entry, .str(entry.value)) }
    if let packed = bridge.messagePack(handle: msg), let n = unpacked(packed) {
        checkEqual(n.signature, DeliveryPolicy.Signature.sourceUnknown, "a key that does not produce alice's address is no key")
        check(n.senderKey == nil, "and is not reported")
    } else { check(false, "a message with a key that does not bind") }
    _ = lxmf_message_destroy(msg)
}

func theLibrariesUnpackRefusesWhatIsNoAcceptOrLeaveInSizeOrKind() {
    check(unpacked(Data()) == nil, "nothing")
    check(unpacked(Data(repeating: 0, count: 96)) == nil, "a header and no payload")
    check(unpacked(Data(repeating: 7, count: 2145)) == nil, "over the size of an accept or leave")
    check(unpacked(Data(repeating: 7, count: 300)) == nil, "bytes that are no LXMF message")
    // None of these is a refusal (RFed SPEC §17.14 "Repeated keys" is for a message that repeats a key): a status's
    // element of this kind is skipped as "not an LXMF message".
    for bytes in [Data(), Data(repeating: 0, count: 96), Data(repeating: 7, count: 2145), Data(repeating: 7, count: 300)] {
        checkEqual(bridge.groupUnpack(bytes), .notLxmf, "\(bytes.count) bytes are not an LXMF message, and not a refusal")
    }
}

func aStatusTheLibraryWritesHoldsItsElementsAsAnArrayOfBinAndReadsBackExactlyAsWritten() {
    let creator = newIdentity(), alice = newIdentity(), bob = newIdentity(), frank = newIdentity()
    let group = String(repeating: "5e", count: 16)
    guard let a = realControl(GroupAction.accept, source: alice, to: creator.delivery, groupId: group),
          let b = realControl(GroupAction.leave, source: bob, to: creator.delivery, groupId: group) else { check(false, "elements"); return }
    let msg = bridge.messageCreate(destHash: frank.delivery, sourceHash: creator.delivery, content: "", title: "",
                                   method: LxmfMethod.direct, identityHandle: creator.handle)
    for entry in GroupEnvelopes.status(groupId: group, selfHex: hex(creator.delivery)) {
        check(LxmfClient.messageSetGroupEntry(msg, entry.entry, .str(entry.value)), "the entry \(entry.entry)")
    }
    check(bridge.messageSetRetichatStatuses(handle: msg, elements: [a, b]), "key 10 is written")
    guard let packed = bridge.messagePack(handle: msg), let u = unpacked(packed) else { check(false, "the status packs and unpacks"); return }
    let fields = LxmfFieldsDecoder.decode(u.fieldsRaw)
    checkEqual(fields.groupAction, GroupAction.status, "a status")
    checkEqual(fields.groupSender, hex(creator.delivery), "from the creator")
    checkEqual(fields.groupStatuses, [a, b], "the elements, exactly as written: never wrapped again")
    // Key 10 starts with an array head and each element with a bin head (CHECK_THESE_THINGS_FIRST §11).
    let raw = [UInt8](u.fieldsRaw)
    let key10 = zip(raw, raw.dropFirst()).enumerated().first { $0.element == (0x0A, 0x92) }?.offset
    check(key10 != nil && raw[key10! + 2] == 0xC5, "a native array of bin16: the first element is a packed message of 256..=65535 bytes")
    // The creator's signature validates the status under its own key (carried by none: this receiver holds none).
    checkEqual(u.signature, DeliveryPolicy.Signature.sourceUnknown, "a status carries no key: unverifiable for a receiver that does not hold the creator's")
    // An element no receiver would read is refused and nothing is written.
    let refused = bridge.messageCreate(destHash: frank.delivery, sourceHash: creator.delivery, content: "", title: "",
                                       method: LxmfMethod.direct, identityHandle: creator.handle)
    check(!bridge.messageSetRetichatStatuses(handle: refused, elements: [Data(repeating: 1, count: 96)]), "an element with no payload is refused")
    check(!bridge.messageSetRetichatStatuses(handle: refused, elements: [Data(repeating: 1, count: 2145)]), "so is one over the limit")
    check(bridge.messageSetRetichatStatuses(handle: refused, elements: []), "an empty list is a valid answer")
    _ = lxmf_message_destroy(msg)
    _ = lxmf_message_destroy(refused)
}

func theSharedVectorsPackedMessagesAreUnpackedByTheRealLibraryAsTheFileSaysForAReceiverHoldingNoKeys() {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("rust/retichat-ffi/tests/data/group_status_vectors.json")
    guard let raw = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
          let messages = json["messages"] as? [[String: Any]] else { check(false, "the vectors are readable"); return }
    func unhexed(_ h: String) -> Data {
        Data((0..<h.count / 2).map { i in let at = h.index(h.startIndex, offsetBy: 2 * i); return UInt8(h[at..<h.index(at, offsetBy: 2)], radix: 16)! })
    }
    var verdicts: [String: Int] = [:]
    for m in messages {
        let name = m["name"] as! String
        let packed = unhexed(m["packed_hex"] as! String)
        guard let u = unpacked(packed) else { check(false, "\(name) unpacks"); continue }
        let want = ((m["verdict"] as! [String: String])["none"])!
        let got: String
        switch u.signature {
        case DeliveryPolicy.Signature.validated: got = "verified"
        case DeliveryPolicy.Signature.invalid: got = "forged"
        default: got = "unverifiable"
        }
        checkEqual(got, want, "\(name): the real library, holding no key")
        checkEqual(hex(u.hash), m["message_hash_hex"] as! String, "\(name): the message hash")
        checkEqual(hex(u.fieldsRaw), m["fields_msgpack_hex"] as! String, "\(name): the fields")
        checkEqual(u.timestamp, m["timestamp"] as! Double, "\(name): the time")
        verdicts[name] = u.signature
    }
    checkEqual(verdicts.count, 9, "every message")
}

func aMemberKeyThatDoesNotProduceTheMembersAddressIsNotRememberedByTheRealLibrary() {
    let alice = newIdentity(), mallory = newIdentity()
    // The check is the library's: a key that does not derive the destination is refused, and nothing is remembered.
    MainActor.assumeIsolated {
        let native = FFIGroupNative(bridge: bridge)
        check(!native.rememberKey(memberHex: hex(alice.delivery), publicKey: mallory.publicKey), "mallory's key is not alice's")
        check(!native.rememberKey(memberHex: "zz", publicKey: alice.publicKey), "a hash that is no hex")
        check(!native.rememberKey(memberHex: hex(alice.delivery), publicKey: Data(repeating: 1, count: 63)), "a key of the wrong size")
    }
}

// MARK: - What the unwrap hands the app: the fields as base64, read as the app reads them

func theUnwrapsFieldsAreTheBytesTheReaderTakes() {
    // lxmf_rust::distro::DistroMessage::to_json carries the fields map in standard base64; the app decodes it
    // with DistroUnwrapped and reads C from `fieldsRaw`.
    let fields = Data((0..<(pinnedFields.count / 2)).map { i in
        let s = pinnedFields.index(pinnedFields.startIndex, offsetBy: 2 * i)
        return UInt8(pinnedFields[s..<pinnedFields.index(s, offsetBy: 2)], radix: 16)!
    })
    let json = """
    {"source_hash":"\(String(repeating: "d", count: 32))","timestamp":1767225600.5,"title":"","content":"",\
    "is_delivery_notification":true,"ticket":"","distro_transfer_key":null,"sent_to":null,"sent_by":null,\
    "display_name_state":0,"display_name":null,"signature_validated":true,"unverified_reason":0,\
    "fields":"\(fields.base64EncodedString())"}
    """
    guard let parsed = try? JSONDecoder().decode(DistroUnwrapped.self, from: Data(json.utf8)) else { check(false, "decoded"); return }
    let marker = DistroChannelSync.read(parsed.fieldsRaw)
    checkEqual(marker?.sync, DistroChannelSync.Sync(op: "join", name: "public.general", atMs: atMs), "the app's decode gives the reader C")
    check(parsed.is_delivery_notification && parsed.sent_by == nil && parsed.distro_transfer_key == nil,
          "C passes for a delivery notification, which is why it is read before that test")
}


// MARK: - The distro sync proof (RFed SPEC §17.13; DISTRO-SYNC-PROOF-DESIGN.md §5.1, §12.16)

/// A message from `distro` to `to`, packed once.
func packedMessage(from distro: (handle: UInt64, delivery: Data, publicKey: Data), to: Data, op: String = "join") -> Data? {
    let msg = bridge.messageCreate(destHash: to, sourceHash: distro.delivery, content: "", title: "",
                                   method: LxmfMethod.direct, identityHandle: distro.handle)
    defer { _ = lxmf_message_destroy(msg) }
    guard msg != 0, bridge.messageSetDistroChannelSync(handle: msg, op: op, name: "public.general", atMs: atMs, deviceHex: pinnedDevice)
    else { return nil }
    return bridge.messagePack(handle: msg)
}

func aMessageIsSealedThroughTheBridgeForItsDistroAndTheProofIsDsSignatureOverTheSealedBytes() {
    let distro = newIdentity()
    guard let packed = packedMessage(from: distro, to: distro.delivery) else { check(false, "packed"); return }
    guard let sealed = bridge.distroSeal(distroHandle: distro.handle, packed: packed) else {
        check(false, "sealed: \(bridge.rnsLastError() ?? "nil")")
        return
    }
    // sealed = D_hash | D.encrypt(packed[16..]): LXMF's lxmf_data before the stamp.
    checkEqual(sealed.sealed.prefix(16), distro.delivery, "the sealed bytes start with D's hash")
    check(sealed.sealed.count > packed.count, "and carry the encrypted rest (token overhead)")
    check(sealed.sealed.range(of: packed.dropFirst(32)) == nil, "encrypted: the signed payload is not in the clear")
    checkEqual(sealed.syncSig.count, 64, "an Ed25519 signature")

    // An independent verifier: SIGNED = "rfed.distro.sync" | 0x01 | D_hash | SHA-256(sealed), under D's Ed25519 key.
    let signed = Data("rfed.distro.sync".utf8) + Data([0x01]) + distro.delivery + Data(SHA256.hash(data: sealed.sealed))
    let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: distro.publicKey.suffix(32))
    check(publicKey?.isValidSignature(sealed.syncSig, for: signed) == true, "the proof is D's signature over SIGNED")
    check(publicKey?.isValidSignature(sealed.syncSig, for: signed.dropLast() + [0]) == false, "and the verifier is not vacuous")
    let otherBytes = Data("rfed.distro.sync".utf8) + Data([0x01]) + distro.delivery + Data(SHA256.hash(data: sealed.sealed + [0]))
    check(publicKey?.isValidSignature(sealed.syncSig, for: otherBytes) == false, "it binds these sealed bytes only")

    // Sealed once per owed message: a second seal is new bytes (a fresh ephemeral key), so the
    // outbox keeps the first and never seals again.
    if let again = bridge.distroSeal(distroHandle: distro.handle, packed: packed) {
        check(again.sealed != sealed.sealed, "a second seal differs, which is why the entry keeps its first")
    } else {
        check(false, "sealed again")
    }
}

func aSealIsRefusedForAMessageNotToItsDistroOrWithNoDistro() {
    let distro = newIdentity()
    let other = newIdentity()
    guard let toOther = packedMessage(from: distro, to: other.delivery) else { check(false, "packed"); return }
    check(bridge.distroSeal(distroHandle: distro.handle, packed: toOther) == nil, "a message to someone else is not sealed")
    check(bridge.rnsLastError()?.contains("not addressed to the distro") == true, "and it says so: \(bridge.rnsLastError() ?? "nil")")
    guard let toSelf = packedMessage(from: distro, to: distro.delivery) else { check(false, "packed"); return }
    check(bridge.distroSeal(distroHandle: other.handle, packed: toSelf) == nil, "nor by another distro")
    check(bridge.distroSeal(distroHandle: 0, packed: toSelf) == nil, "nor with no handle")
    check(bridge.distroSeal(distroHandle: distro.handle, packed: Data([1, 2, 3])) == nil, "nor what is no message")
}

func aSealedUploadIsNotBuiltForANodeWhoseAnnounceWasNotHeardWithOrWithoutTheClaim() {
    let distro = newIdentity()
    guard let packed = packedMessage(from: distro, to: distro.delivery),
          let sealed = bridge.distroSeal(distroHandle: distro.handle, packed: packed) else { check(false, "sealed"); return }
    let node = Data(repeating: 0x44, count: 16)
    for withClaim in [true, false] {
        check(bridge.propagationBuildSealedUpload(distroPublicKey: distro.publicKey, sealed: sealed.sealed, syncSig: sealed.syncSig,
                                                  withClaim: withClaim, node: node) == nil,
              "no stamp cost is known for a node that was not heard (claim \(withClaim))")
        check(bridge.rnsLastError()?.contains("not known") == true, "and it says so: \(bridge.rnsLastError() ?? "nil")")
    }
    check(bridge.propagationBuildSealedUpload(distroPublicKey: distro.publicKey, sealed: sealed.sealed, syncSig: sealed.syncSig,
                                              withClaim: true, node: Data([1, 2, 3])) == nil,
          "a node that is not 16 bytes is refused")
}

func theUpEdgeMarkIsTransportsCountAndNothingCameUpSinceItWithNoStack() {
    // No stack is started here, so no interface comes up: the mark holds. The count moving is the
    // glue crate's cargo test (an interface set online between the mark and the question).
    let mark = bridge.interfaceUpMark()
    check(!bridge.interfaceCameUpSince(mark), "nothing came up since the mark")
    checkEqual(bridge.interfaceUpMark(), mark, "the mark is the same count asked again")
    check(bridge.interfaceCameUpSince(mark &+ 1), "a mark that is not the count says an interface came up")
}

let allTests: [(String, () -> Void)] = [
    ("the wrapper writes C exactly as pinned, and the Swift reader and an independent verifier take it", theWrapperWritesCExactlyAsPinnedAndTheSwiftReaderAndAnIndependentVerifierTakeIt),
    ("the wrapper refuses a malformed message and writes nothing", theWrapperRefusesAMalformedMessageAndWritesNothing),
    ("an upload is not built for a node whose announce was not heard", anUploadIsNotBuiltForANodeWhoseAnnounceWasNotHeard),
    ("a node that is not held has no link, and an upload on it is refused with its sink released once", aNodeThatIsNotHeldHasNoLinkAndAnUploadOnItIsRefusedWithItsSinkReleasedOnce),
    ("the upload trampolines report each event and the release frees the sink", theUploadTrampolinesReportEachEventAndTheReleaseFreesTheSink),
    ("a link event reaches the handler with its link or none", aLinkEventReachesTheHandlerWithItsLinkOrNone),
    ("an interface up-edge reaches the handler with its name until it is cleared", anInterfaceUpEventReachesTheHandlerWithItsNameUntilItIsCleared),
    ("a real accept carrying its sender's key is validated by it, a forgery is invalid, no key is unverifiable", aRealAcceptCarryingItsSendersKeyIsValidatedByThatKeyAndAForgeryIsInvalidAndNoKeyIsUnverifiable),
    ("the library's unpack refuses what is no accept or leave in size or kind", theLibrariesUnpackRefusesWhatIsNoAcceptOrLeaveInSizeOrKind),
    ("a status the library writes holds its elements as an array of bin and reads back as written", aStatusTheLibraryWritesHoldsItsElementsAsAnArrayOfBinAndReadsBackExactlyAsWritten),
    ("the shared vectors' messages are unpacked by the real library as the file says", theSharedVectorsPackedMessagesAreUnpackedByTheRealLibraryAsTheFileSaysForAReceiverHoldingNoKeys),
    ("a member key that does not produce the member's address is not remembered", aMemberKeyThatDoesNotProduceTheMembersAddressIsNotRememberedByTheRealLibrary),
    ("the unwrap's fields are the bytes the reader takes", theUnwrapsFieldsAreTheBytesTheReaderTakes),
    ("a message is sealed through the bridge for its distro, and the proof is D's signature over the sealed bytes", aMessageIsSealedThroughTheBridgeForItsDistroAndTheProofIsDsSignatureOverTheSealedBytes),
    ("a seal is refused for a message not to its distro, or with no distro", aSealIsRefusedForAMessageNotToItsDistroOrWithNoDistro),
    ("a sealed upload is not built for a node whose announce was not heard, with or without the claim", aSealedUploadIsNotBuiltForANodeWhoseAnnounceWasNotHeardWithOrWithoutTheClaim),
    ("the up-edge mark is Transport's count, and nothing came up since it with no stack", theUpEdgeMarkIsTransportsCountAndNothingCameUpSinceItWithNoStack),
]

@main
enum DistroChannelsFFITests {
    static func main() {
        for (name, run) in allTests {
            currentTest = name
            let before = failures.count
            run()
            print(failures.count == before ? "ok    - \(name)" : "FAIL  - \(name)")
        }
        print("\n\(allTests.count) tests, \(checks) checks, \(failures.count) failure(s)")
        exit(failures.isEmpty ? 0 : 1)
    }
}
