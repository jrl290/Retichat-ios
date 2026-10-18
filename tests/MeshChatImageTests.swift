// MeshChatImageTests.swift
//
// A picture from MeshChat or Sideband arrives (Retichat-ios #8): LXMF's FIELD_IMAGE (0x06,
// `[image_type, data]`) and FIELD_AUDIO (0x07, `[audio_mode, data]`) are read into
// `LxmfFields.attachments` after the file attachments (0x05), as the web reads them
// (Retichat-js lxmf.js attachmentsFromFields) and Android does (LxmfFields.getAttachments,
// LxmfImageAudioFieldsTest). Until 2026-10-17 only 0x05 was read and such a message arrived as
// its text alone.
//
// Run from the workspace root with:
//
//   swiftc -parse-as-library -o /private/tmp/claude-501/meshchat-image \
//     Retichat-ios/Retichat/Bridge/LxmfFields.swift \
//     Retichat-ios/Retichat/Services/DeliveryPolicy.swift \
//     Retichat-ios/Retichat/Services/DistroGroupSync.swift \
//     Retichat-ios/Retichat/Services/PendingNotification.swift \
//     Retichat-ios/Retichat/Services/Reactions.swift \
//     Retichat-ios/tests/MeshChatImageTests.swift && \
//   /private/tmp/claude-501/meshchat-image

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

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func source(_ path: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

func bytes(_ hex: String) -> Data {
    var out = Data()
    var i = hex.startIndex
    while i < hex.endIndex {
        let j = hex.index(i, offsetBy: 2)
        out.append(UInt8(hex[i..<j], radix: 16)!)
        i = j
    }
    return out
}

func decode(_ hex: String) -> LxmfFields { LxmfFieldsDecoder.decode(bytes(hex)) }

func names(_ hex: String) -> [String] { decode(hex).attachments.map(\.filename) }

let data = "c403010203"   // bin 01 02 03

// MARK: - Tests

func testAMeshChatImageIsAnAttachmentNamedForAnInlineType() {
    // {0x06: ["png", bin 01 02 03]}: what MeshChat sends for a picture.
    let f = decode("8106" + "92" + "a3706e67" + data)
    checkEqual(f.attachments.map(\.filename), ["image.png"], "the picture is an attachment")
    checkEqual(f.attachments.first?.data, Data([1, 2, 3]), "with its bytes")
    // Sideband's "webp", a MIME type, upper case, and the type as bin.
    checkEqual(names("8106" + "92" + "a477656270" + data), ["image.webp"], "webp")
    checkEqual(names("8106" + "92" + "aa696d6167652f6a706567" + data), ["image.jpeg"], "image/jpeg")
    checkEqual(names("8106" + "92" + "a34a5047" + data), ["image.jpg"], "JPG")
    checkEqual(names("8106" + "92" + "c403706e67" + data), ["image.png"], "the type as bin")
    checkEqual(names("8106" + "92" + "a468656963" + data), ["image.heic"], "heic, which isImage shows")
}

func testATypeNotShownInlineIsAFileAndNeverMakesTheName() {
    // "svg+xml", a path, and nil: the picture still arrives, as "image".
    checkEqual(names("8106" + "92" + "a7737667" + "2b786d6c" + data), ["image"], "svg+xml")
    checkEqual(names("8106" + "92" + "a92e2e2f2e2e2f782e6a" + data), ["image"], "a path")
    checkEqual(names("8106" + "92" + "c0" + data), ["image"], "nil")
}

func testAnImageOrAudioNotOfThatShapeIsSkippedAndTheRestIsRead() {
    // {0x06: "x", 0xFB: "abc"}: the walk stays in step past a malformed 0x06.
    let notAList = decode("82" + "06a178" + "ccfb" + "a3616263")
    check(notAList.attachments.isEmpty, "a 0x06 that is not a list is no attachment")
    checkEqual(notAList.customType, "abc", "and the field after it is still read")
    // {0x07: [16, "no", 1], 0xFB: "abc"}: the same after a 0x07 of three entries.
    checkEqual(decode("82" + "0793" + "10" + "a26e6f" + "01" + "ccfb" + "a3616263").customType, "abc",
               "a 0x07 with a str for data is consumed whole")
    check(decode("8106" + "91" + "a3706e67").attachments.isEmpty, "[\"png\"] alone")
    check(decode("8106" + "92" + "a3706e67" + "a26e6f").attachments.isEmpty, "[\"png\", \"no\"]: the data must be a bin")
    check(decode("8107" + "91" + "10").attachments.isEmpty, "[16] alone")
    // A truncated value: no crash, nothing read.
    check(decode("8106" + "92" + "a3706e67" + "c40a0102").attachments.isEmpty, "a bin running past the end")
}

func testAudioIsOfferedAsAFileNamedForItsMode() {
    checkEqual(names("8107" + "92" + "10" + data), ["audio.ogg"], "AM_OPUS_OGG")
    checkEqual(names("8107" + "92" + "cc11" + data), ["audio.ogg"], "a uint8 mode")
    checkEqual(names("8107" + "92" + "05" + data), ["audio.c2"], "AM_CODEC2_1300")
    checkEqual(names("8107" + "92" + "30" + data), ["audio.bin"], "an unknown mode")
    checkEqual(names("8107" + "92" + "a178" + data), ["audio.bin"], "a str mode")
}

func testTheFileAttachmentsComeFirstThenTheImageThenTheAudio() {
    // {0x07: [16, bin 0a], 0x06: ["png", bin 01 02 03], 0x05: [["a.txt", bin 09]]}: map order
    // does not matter.
    let f = decode("83" + "07" + "92" + "10" + "c4010a" + "06" + "92" + "a3706e67" + data
                   + "05" + "91" + "92" + "a5612e747874" + "c40109")
    checkEqual(f.attachments.map(\.filename), ["a.txt", "image.png", "audio.ogg"], "0x05, image, audio")
    checkEqual(f.attachments.map(\.data), [Data([9]), Data([1, 2, 3]), Data([10])], "bytes intact")
}

func testTheNamesAreOnesTheAppShowsInline() {
    // Attachment.isImage (Models.swift) decides what shows inline; every image name made here
    // must be one of its suffixes, or a picture would show as a file.
    let models = source("Retichat/Models/Models.swift")
    check(!models.isEmpty, "reads Models.swift")
    for ext in LxmfFieldsDecoder.imageTypes {
        check(models.contains("lower.hasSuffix(\".\(ext)\")"), "isImage shows .\(ext)")
    }
}

func testEveryReceivePathReadsTheDecodersAttachments() {
    let repo = source("Retichat/Services/ChatRepository.swift")
    check(!repo.isEmpty, "reads ChatRepository.swift")
    check(repo.contains("attachments: fields.attachments, lxmfHash: msgHashHex)"),
          "a direct message stores the decoder's attachments")
    checkEqual(repo.components(separatedBy: "for (filename, data) in fields.attachments {").count - 1, 2,
               "the NSE import and the group path store the decoder's attachments")
    let client = source("Retichat/Services/RfedDistroClient.swift")
    check(client.contains("let attachments = LxmfFieldsDecoder.decode(m.fields ?? Data()).attachments"),
          "a distro message stores the decoder's attachments")
}

let allTests: [(String, () -> Void)] = [
    ("testAMeshChatImageIsAnAttachmentNamedForAnInlineType", testAMeshChatImageIsAnAttachmentNamedForAnInlineType),
    ("testATypeNotShownInlineIsAFileAndNeverMakesTheName", testATypeNotShownInlineIsAFileAndNeverMakesTheName),
    ("testAnImageOrAudioNotOfThatShapeIsSkippedAndTheRestIsRead", testAnImageOrAudioNotOfThatShapeIsSkippedAndTheRestIsRead),
    ("testAudioIsOfferedAsAFileNamedForItsMode", testAudioIsOfferedAsAFileNamedForItsMode),
    ("testTheFileAttachmentsComeFirstThenTheImageThenTheAudio", testTheFileAttachmentsComeFirstThenTheImageThenTheAudio),
    ("testTheNamesAreOnesTheAppShowsInline", testTheNamesAreOnesTheAppShowsInline),
    ("testEveryReceivePathReadsTheDecodersAttachments", testEveryReceivePathReadsTheDecodersAttachments),
]

@main
enum MeshChatImageTests {
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
