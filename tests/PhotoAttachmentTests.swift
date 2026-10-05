// PhotoAttachmentTests.swift
//
// Photos picked in a conversation (release 2026-10): an iPhone photo is
// HEIC, and until 2026-10-05 its bytes were sent as they came, named
// "photo_<time>.jpg". Browsers cannot show HEIC and Android does not take it
// for an image, so the web showed a broken picture and Android a file. Now
// the name always says what the bytes are: JPEG, PNG, GIF and WebP go as
// they are, any other still image (HEIC, HEIF, AVIF, ...) is drawn upright
// and sent as JPEG, and a video keeps its bytes under its own extension.
//
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/photo-attachment \
//     Retichat-ios/Retichat/Services/PhotoAttachment.swift \
//     Retichat-ios/tests/PhotoAttachmentTests.swift && \
//     /private/tmp/claude-501/photo-attachment
//
// PhotoAttachment runs for real on macOS ImageIO (iOS's), on a HEIC made
// here with an EXIF orientation; the picker's wiring is asserted on the
// source.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

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

/// A 64 x 32 image (left half red, right half blue), encoded as `type`
/// with EXIF orientation `orientation`.
func encodedImage(_ type: UTType, orientation: Int = 1) -> Data? {
    let width = 64, height = 32
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 32, y: 0, width: 32, height: 32))
    guard let image = ctx.makeImage() else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return out as Data
}

func pixelSize(_ data: Data) -> (Int, Int, Int?)? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (w, h, props[kCGImagePropertyOrientation] as? Int)
}

func testAHeicPhotoGoesAsAnUprightJPEG() {
    guard let heic = encodedImage(.heic, orientation: 6) else {
        check(false, "this Mac's ImageIO encodes a HEIC to test with")
        return
    }
    check(PhotoAttachment.format(of: heic) == .isoMedia(brand: "heic") || {
        if case .isoMedia = PhotoAttachment.format(of: heic) { return true } else { return false }
    }(), "a HEIC is told by its ftyp box")
    let sent = PhotoAttachment.prepare(heic, baseName: "photo_1", fallbackExtension: "heic")
    check(sent.filename == "photo_1.jpg", "a HEIC photo is named .jpg ...")
    check(PhotoAttachment.format(of: sent.data) == .jpeg, "... and its bytes are JPEG")
    if let (w, h, orientation) = pixelSize(sent.data) {
        check(w == 32 && h == 64, "drawn upright: the EXIF orientation is applied to the pixels (\(w)x\(h))")
        check(orientation == nil || orientation == 1, "and no orientation is left for a receiver to ignore")
    } else {
        check(false, "the JPEG decodes")
    }
}

func testFormatsEveryClientShowsGoAsTheyAre() {
    if let jpeg = encodedImage(.jpeg) {
        let sent = PhotoAttachment.prepare(jpeg, baseName: "p")
        check(sent.filename == "p.jpg" && sent.data == jpeg, "a JPEG goes as it is, named .jpg")
    } else { check(false, "a JPEG to test with") }
    if let png = encodedImage(.png) {
        let sent = PhotoAttachment.prepare(png, baseName: "p")
        check(sent.filename == "p.png" && sent.data == png, "a PNG (a screenshot) goes as it is, named .png")
    } else { check(false, "a PNG to test with") }
    if let gif = encodedImage(.gif) {
        let sent = PhotoAttachment.prepare(gif, baseName: "p")
        check(sent.filename == "p.gif" && sent.data == gif, "a GIF goes as it is (animation kept), named .gif")
    } else { check(false, "a GIF to test with") }
    let webp = Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 ".utf8)
    check(PhotoAttachment.format(of: webp) == .webp && PhotoAttachment.prepare(webp, baseName: "p").filename == "p.webp",
          "a WebP is named .webp")
}

func testAVideoKeepsItsBytesAndItsOwnName() {
    var mov = Data([0, 0, 0, 0x14]); mov.append(Data("ftypqt  ".utf8)); mov.append(Data(count: 32))
    var mp4 = Data([0, 0, 0, 0x18]); mp4.append(Data("ftypisom".utf8)); mp4.append(Data(count: 32))
    let movSent = PhotoAttachment.prepare(mov, baseName: "v")
    check(movSent.filename == "v.mov" && movSent.data == mov, "a QuickTime video is named .mov, bytes as they are")
    check(PhotoAttachment.prepare(mp4, baseName: "v").filename == "v.mp4", "another ISO media video is named .mp4")
    check(PhotoAttachment.prepare(mov, baseName: "v", fallbackExtension: "mov").filename == "v.mov",
          "the picked item's own type names a video")
    check(PhotoAttachment.prepare(Data([1, 2, 3]), baseName: "x").filename == "x.bin",
          "bytes that are no image are never named .jpg")
}

func testThePickerWiring() {
    let view = source("Retichat/Views/Conversation/ConversationView.swift")
    check(!view.contains("let filename = \"photo_\\(Date().timeIntervalSince1970).jpg\""),
          "the picker no longer names any bytes .jpg")
    check(view.contains("let attachment = await Task.detached(priority: .userInitiated) {\n                            PhotoAttachment.prepare(data, baseName: baseName, fallbackExtension: itemExtension)")
            && view.contains("pendingAttachments.append((attachment.filename, attachment.data))"),
          "it sends what PhotoAttachment prepares, made off the main actor")
}

@main
struct PhotoAttachmentTestsMain {
    static func main() {
        testAHeicPhotoGoesAsAnUprightJPEG()
        testFormatsEveryClientShowsGoAsTheyAre()
        testAVideoKeepsItsBytesAndItsOwnName()
        testThePickerWiring()
        if failures.isEmpty {
            print("all photo attachment tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
