// DistroAttachmentsTests.swift
//
// Found in the final device round (2026-09-29): a photo sent from the Pixel
// to the iPad's distro address arrived as its caption only. The unwrap
// handed the app no fields, and handleDistroMessage stored `attachments: []`.
// lxmf_rust now adds "fields" to the unwrap JSON (the payload's fields map
// as the sender packed it, standard base64, or null); the app decodes it
// with LxmfFieldsDecoder, as it does a direct message's fields, and stores
// the attachments through storeIncomingDirect.
//
// Run from the workspace root with:
//
//   { echo 'import Foundation'; \
//     sed -n '/^\/\/ BEGIN DistroInbound/,/^\/\/ END DistroInbound/p' \
//     Retichat-ios/Retichat/Services/RfedDistroClient.swift; } \
//     > /private/tmp/claude-501/DistroInbound.swift && \
//   swiftc -o /private/tmp/claude-501/distro-attachments \
//     /private/tmp/claude-501/DistroInbound.swift \
//     Retichat-ios/Retichat/Bridge/LxmfFields.swift \
//     Retichat-ios/tests/DistroAttachmentsTests.swift && \
//     /private/tmp/claude-501/distro-attachments
//
// The JSON below is what retichat_distro_unwrap returns: each line was
// produced by lxmf_rust::distro::unwrap_blob and DistroMessage::to_json
// (LXMF-rust 06c40e1) on a blob encrypted to a distro, its payload packed as
// LXMessage packs one (0x05 as add_file_attachment writes it). The JSON
// decode, the DistroMessage the client builds from it and the store rule run
// for real; ChatRepository and RfedDistroClient need SwiftData, UIKit and the
// FFI, so their wiring is asserted on the source.

import Foundation

nonisolated(unsafe) var failures: [String] = []

func check(_ ok: Bool, _ what: String) {
    if ok {
        print("ok    - \(what)")
    } else {
        failures.append(what)
        print("FAIL  - \(what)")
    }
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func source(_ path: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

/// `a` appears, and before `b`.
func before(_ text: String, _ a: String, _ b: String) -> Bool {
    guard let ra = text.range(of: a), let rb = text.range(of: b) else { return false }
    return ra.lowerBound < rb.lowerBound
}

/// The body of `func name` in `text`, up to the next "\n    func " or
/// "\n    private func " at the same depth (enough for these files).
func body(_ text: String, _ signature: String) -> String {
    guard let start = text.range(of: signature) else { return "" }
    let rest = text[start.upperBound...]
    let ends = ["\n    func ", "\n    private func ", "\n    nonisolated static func ",
                "\n    nonisolated private static func ", "\n    // MARK: -"]
        .compactMap { rest.range(of: $0)?.lowerBound }
    return String(rest[..<(ends.min() ?? rest.endIndex)])
}

// MARK: - Golden unwrap JSON (lxmf_rust to_json)

/// Fields {0x05: [["pixel-photo-1.jpg", jpeg], ["notes.txt", "file bytes\n"]],
/// 0x06: ["webp", …], 0x0C: [expiry, ticket]}, no caption: with a ticket and
/// no content, a message since LXMF-rust 06c40e1 (is_delivery_notification
/// false because it carries 0x05/0x06).
let captionless = #"{"source_hash":"c789ebe5a0c0b2c377e967896a386810","timestamp":1790000000.5,"title":"","content":"","is_delivery_notification":false,"ticket":"[1790086400, [171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171]]","distro_transfer_key":null,"sent_to":null,"sent_by":null,"display_name_state":0,"display_name":null,"signature_validated":true,"unverified_reason":0,"fields":"gwWSkrFwaXhlbC1waG90by0xLmpwZ8QO/9j/4AAQSkZJRgAB/9mSqW5vdGVzLnR4dMQLZmlsZSBieXRlcwoGkqR3ZWJwxBBSSUZGDAAAAFdFQlBWUDggDJLLQdqso0AAAADEEKurq6urq6urq6urq6urq6s="}"#

/// The same fields with the caption "pixel-photo-1" (the text the iPad showed alone).
let captioned = #"{"source_hash":"c789ebe5a0c0b2c377e967896a386810","timestamp":1790000000.5,"title":"","content":"pixel-photo-1","is_delivery_notification":false,"ticket":"[1790086400, [171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171]]","distro_transfer_key":null,"sent_to":null,"sent_by":null,"display_name_state":0,"display_name":null,"signature_validated":true,"unverified_reason":0,"fields":"gwWSkrFwaXhlbC1waG90by0xLmpwZ8QO/9j/4AAQSkZJRgAB/9mSqW5vdGVzLnR4dMQLZmlsZSBieXRlcwoGkqR3ZWJwxBBSSUZGDAAAAFdFQlBWUDggDJLLQdqso0AAAADEEKurq6urq6urq6urq6urq6s="}"#

/// A 3-element payload: no fields map.
let noMap = #"{"source_hash":"c789ebe5a0c0b2c377e967896a386810","timestamp":1790000000.5,"title":"","content":"plain","is_delivery_notification":false,"ticket":null,"distro_transfer_key":null,"sent_to":null,"sent_by":null,"display_name_state":0,"display_name":null,"signature_validated":true,"unverified_reason":0,"fields":null}"#

/// An empty fields map and no content.
let emptyMap = #"{"source_hash":"c789ebe5a0c0b2c377e967896a386810","timestamp":1790000000.5,"title":"","content":"","is_delivery_notification":false,"ticket":null,"distro_transfer_key":null,"sent_to":null,"sent_by":null,"display_name_state":0,"display_name":null,"signature_validated":true,"unverified_reason":0,"fields":"gA=="}"#

/// FIELD_IMAGE (0x06) only, no content.
let imageOnly = #"{"source_hash":"c789ebe5a0c0b2c377e967896a386810","timestamp":1790000000.5,"title":"","content":"","is_delivery_notification":false,"ticket":null,"distro_transfer_key":null,"sent_to":null,"sent_by":null,"display_name_state":0,"display_name":null,"signature_validated":true,"unverified_reason":0,"fields":"gQaSpHdlYnDEAwECAw=="}"#

/// What an FFI build before "fields" returned.
let olderFFI = #"{"source_hash":"c789ebe5a0c0b2c377e967896a386810","timestamp":1790000000.5,"title":"","content":"","is_delivery_notification":false,"ticket":null,"distro_transfer_key":null,"sent_to":null,"sent_by":null,"display_name_state":0,"display_name":null,"signature_validated":true,"unverified_reason":0}"#

let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0xFF, 0xD9])
let notes = Data("file bytes\n".utf8)
/// The fields map in the golden lines, as the sender packed it.
let fieldsHex = "83059292b1706978656c2d70686f746f2d312e6a7067c40effd8ffe000104a4649460001ffd992a96e6f7465732e747874c40b66696c652062797465730a0692a477656270c410524946460c00000057454250565038200c92cb41daaca340000000c410abababababababababababababababab"

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

func unwrapped(_ json: String) -> DistroUnwrapped? {
    try? JSONDecoder().decode(DistroUnwrapped.self, from: Data(json.utf8))
}

/// What RfedDistroClient.unwrapAndDeliver hands ChatRepository for this JSON.
func message(_ json: String) -> DistroMessage? {
    guard let parsed = unwrapped(json) else { return nil }
    return DistroMessage(unwrapped: parsed, sourceHash: Data(repeating: 0xC7, count: 16), shownByNSE: false)
}

func same(_ a: [(filename: String, data: Data)], _ b: [(filename: String, data: Data)]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { $0.filename == $1.filename && $0.data == $1.data }
}

// MARK: - Tests

/// The bug: a captionless photo to the distro must store the photo.
func testACaptionlessPhotoStoresItsAttachments() {
    guard let parsed = unwrapped(captionless), let m = message(captionless) else {
        check(false, "the unwrap JSON with fields decodes")
        return
    }
    check(!parsed.is_delivery_notification, "a captionless photo with a ticket is a message (LXMF-rust 06c40e1)")
    check(parsed.fieldsRaw.map(hex) == fieldsHex, "\"fields\" decodes to the map the sender packed")
    check(m.fields.map(hex) == fieldsHex, "the DistroMessage the client builds carries those bytes")

    let stored = DistroMessageStore.stored(m)
    check(same(stored.attachments, [("pixel-photo-1.jpg", jpeg), ("notes.txt", notes)]),
          "both 0x05 attachments reach the store path, in order, bytes intact")
    check(stored.content == "", "no text and attachments stored: no placeholder")
    // "Exactly as a normal message does": the decoder a direct message's
    // fields go through gives the same attachments from the same bytes.
    check(same(stored.attachments, LxmfFieldsDecoder.decode(Data(m.fields ?? Data())).attachments),
          "the same attachments the direct receive path decodes from these fields")
}

func testACaptionedPhotoKeepsItsCaptionAndPhoto() {
    guard let m = message(captioned) else {
        check(false, "the captioned JSON decodes")
        return
    }
    let stored = DistroMessageStore.stored(m)
    check(stored.content == "pixel-photo-1", "the caption is the text")
    check(same(stored.attachments, [("pixel-photo-1.jpg", jpeg), ("notes.txt", notes)]),
          "and the photo is stored with it (the iPad showed the caption alone)")
}

func testThePlaceholderIsOnlyForNothingToStore() {
    let plain = message(noMap)
    check(plain != nil && plain?.fields == nil, "\"fields\": null is no fields")
    if let plain {
        let stored = DistroMessageStore.stored(plain)
        check(stored.content == "plain" && stored.attachments.isEmpty, "a text message stores its text alone")
    }

    let empty = message(emptyMap)
    check(empty?.fields == Data([0x80]), "an empty map is \"gA==\", the byte 0x80")
    if let empty {
        let stored = DistroMessageStore.stored(empty)
        check(stored.content == DistroMessageStore.unavailablePlaceholder && stored.attachments.isEmpty,
              "no text and no attachment: the placeholder")
    }

    // iOS reads attachments from 0x05 only, for direct messages too: an
    // image in 0x06 alone is not an attachment it can store.
    let image = message(imageOnly)
    check(image?.fields.map(hex) == "8106" + "92a477656270c403010203", "\"fields\" carries the 0x06 map")
    if let image {
        let stored = DistroMessageStore.stored(image)
        check(stored.attachments.isEmpty && stored.content == DistroMessageStore.unavailablePlaceholder,
              "an image in 0x06 alone (not read on iOS) gets the placeholder, not an empty bubble")
    }

    let spaces = DistroMessage(sourceHash: Data(count: 16), title: "", content: "  \n", timestamp: 1,
                               fields: Data(base64Encoded: "gA=="))
    check(DistroMessageStore.stored(spaces).content == DistroMessageStore.unavailablePlaceholder,
          "whitespace is no text")
    let photoAndSpaces = DistroMessage(sourceHash: Data(count: 16), title: "", content: " \n",
                                       timestamp: 1, fields: message(captionless)?.fields)
    check(DistroMessageStore.stored(photoAndSpaces).content == "",
          "text is trimmed, as before, and a photo with only whitespace stores no placeholder")
}

func testOlderOrMalformedFieldsDecodeAsNone() {
    let old = unwrapped(olderFFI)
    check(old != nil && old?.fields == nil && old?.fieldsRaw == nil,
          "JSON from an FFI build without \"fields\" still decodes, with no fields")
    let bad = unwrapped(noMap.replacingOccurrences(of: #""fields":null"#, with: #""fields":"not base64!""#))
    check(bad != nil && bad?.fieldsRaw == nil, "\"fields\" that is not base64 is no fields, not a crash")
    check(unwrapped(captionless)?.fields?.hasSuffix("=") == true,
          "the golden line is standard padded base64 (RFC 4648 §4), which Data(base64Encoded:) reads")
}

// MARK: - Wiring (source)

func testTheWiring() {
    let client = source("Retichat/Services/RfedDistroClient.swift")
    check(!client.isEmpty, "reads RfedDistroClient.swift")
    let unwrap = body(client, "nonisolated private static func unwrapAndDeliver(")
    check(unwrap.contains("JSONDecoder().decode(DistroUnwrapped.self, from: json)"),
          "the client decodes the unwrap JSON with the tested type")
    check(unwrap.contains("inbound = .message(DistroMessage(unwrapped: parsed, sourceHash: src, shownByNSE: shownByNSE))"),
          "and builds the message with the tested initializer, fields included")
    check(before(client, "nonisolated static func importNSEBlobs()", "for blob in blobs { ingestBlob(blob, shownByNSE: true) }")
            && client.contains("blobQueue.async { unwrapAndDeliver(blob, shownByNSE: shownByNSE) }"),
          "blobs the NSE pulled go through the same unwrap, so they keep their attachments")

    let repo = source("Retichat/Services/ChatRepository.swift")
    check(!repo.isEmpty, "reads ChatRepository.swift")
    let distro = body(repo, "private func handleDistroMessage(")
    check(before(distro, "let (content, attachments) = DistroMessageStore.stored(m)",
                 "let msgId = DistroCodec.messageId(sourceHex: srcHex, timestamp: m.timestamp, content: content)"),
          "handleDistroMessage takes the text and attachments from the store rule, before its id")
    check(distro.contains("attachments: attachments, notify: !m.shownByNSE)") && !distro.contains("attachments: []"),
          "and hands the attachments to storeIncomingDirect")
    check(!distro.contains("[Attachment not available via the distro address]"),
          "the placeholder is decided by the store rule alone")
    let incoming = body(repo, "private func handleIncomingMessage(")
    check(incoming.contains("attachments: fields.attachments)"),
          "the direct path stores the decoder's attachments through storeIncomingDirect too")
    let store = body(repo, "private func storeIncomingDirect(")
    check(before(store, "for (filename, data) in attachments {", "let att = AttachmentEntity(")
            && store.contains("messageId: msgHashHex,"),
          "storeIncomingDirect files each attachment against the message")

    // SPEC §17.11: a sent copy never carries attachments; its rule stands.
    let sentCopy = body(repo, "private func handleDistroSentCopy(")
    check(sentCopy.contains("// M carried only attachments, which the copy never does.")
            && !sentCopy.contains("AttachmentEntity"),
          "sent copies still store no attachments")

    // The NSE shows the text and leaves the attachments to the app's import.
    let nse = source("NotificationService/NSEDistroPull.swift")
    let show = body(nse, "private static func unwrapToShow(")
    check(show.contains("if m.sent_by != nil || !(m.distro_transfer_key ?? \"\").isEmpty || m.is_delivery_notification {")
            && show.contains("content: m.content ?? \"\""),
          "the NSE shows a captionless photo (not a delivery notification since 06c40e1), its body the empty text")
    let service = source("NotificationService/NotificationService.swift")
    check(service.contains("let body = others == 0 ? msg.content")
            && service.contains("candidates.append((m.senderHash, m.content,")
            && service.contains("($0.senderHash, $0.content, $0.timestamp, \"distro\""),
          "as a photo sent to this device does: both bodies are the message text")
}

@main
enum DistroAttachmentsTests {
    static func main() {
        testACaptionlessPhotoStoresItsAttachments()
        testACaptionedPhotoKeepsItsCaptionAndPhoto()
        testThePlaceholderIsOnlyForNothingToStore()
        testOlderOrMalformedFieldsDecodeAsNone()
        testTheWiring()
        if failures.isEmpty {
            print("all distro attachment tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
