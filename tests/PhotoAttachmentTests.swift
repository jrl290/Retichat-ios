// PhotoAttachmentTests.swift
//
// Photos picked in a conversation (release 2026-10): an iPhone photo is
// HEIC, and until 2026-10-05 its bytes were sent as they came, named
// "photo_<time>.jpg". Browsers cannot show HEIC and Android does not take it
// for an image, so the web showed a broken picture and Android a file. Now
// the name always says what the bytes are: JPEG, PNG, GIF and WebP keep
// their image bytes, any other still image (HEIC, HEIF, AVIF, ...) is drawn
// upright and sent as JPEG, and a video keeps its bytes under its own
// extension.
//
// And no photo leaves the phone with its location, whatever its format
// (James, 2026-10-05: "strip from every photo"). Until then a JPEG, PNG,
// GIF or WebP went with its EXIF GPS, XMP and IPTC location as picked.
// Each format now keeps only what draws its picture, the image bytes as
// they are; a JPEG keeps its orientation as the one EXIF tag left, and a
// PNG that needs turning is redrawn upright.
//
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/photo-attachment \
//     Retichat-ios/Retichat/Services/PhotoAttachment.swift \
//     Retichat-ios/Retichat/Services/PhotoMetadata.swift \
//     Retichat-ios/tests/PhotoAttachmentTests.swift && \
//     /private/tmp/claude-501/photo-attachment
//
// PhotoAttachment and PhotoMetadata run for real on macOS ImageIO (iOS's),
// on photos made here with a GPS position, an IPTC city and an EXIF
// orientation; the picker's wiring is asserted on the source.

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

/// Where the photos below were "taken".
let city = "Lisbon"
let located: [CFString: Any] = [
    kCGImagePropertyGPSDictionary: [
        kCGImagePropertyGPSLatitude: 38.7223, kCGImagePropertyGPSLatitudeRef: "N",
        kCGImagePropertyGPSLongitude: 9.1393, kCGImagePropertyGPSLongitudeRef: "W",
    ],
    kCGImagePropertyIPTCDictionary: [
        kCGImagePropertyIPTCCity: city, kCGImagePropertyIPTCCountryPrimaryLocationName: "Portugal",
    ],
    kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:05 12:00:00"],
]

/// A 64 x 32 image (left half red, right half blue), encoded as `type`
/// with EXIF orientation `orientation` and, when `withLocation`, the
/// position, city and date above.
func encodedImage(_ type: UTType, orientation: Int = 1, withLocation: Bool = false) -> Data? {
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
    var props: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
    if withLocation { props.merge(located) { a, _ in a } }
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return out as Data
}

func properties(_ data: Data) -> [CFString: Any]? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
}

func pixelSize(_ data: Data) -> (Int, Int, Int?)? {
    guard let props = properties(data),
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (w, h, props[kCGImagePropertyOrientation] as? Int)
}

func contains(_ data: Data, _ text: String) -> Bool {
    data.range(of: Data(text.utf8)) != nil
}

/// A photo carries a location ImageIO can see, or the city's name anywhere
/// in its bytes (EXIF, XMP, IPTC or text).
func carriesLocation(_ data: Data) -> Bool {
    let props = properties(data) ?? [:]
    return props[kCGImagePropertyGPSDictionary] != nil || props[kCGImagePropertyIPTCDictionary] != nil
        || contains(data, city) || contains(data, "GPSLatitude")
}

/// `data` from the first occurrence of `marker` to its end.
func suffix(_ data: Data, from marker: [UInt8]) -> Data? {
    data.range(of: Data(marker)).map { data[$0.lowerBound...] }
}

// MARK: - Location

func testAJPEGLosesItsLocationAndKeepsItsPicture() {
    guard let jpeg = encodedImage(.jpeg, orientation: 6, withLocation: true) else {
        check(false, "this Mac's ImageIO encodes a JPEG with a location to test with")
        return
    }
    check(carriesLocation(jpeg) && properties(jpeg)?[kCGImagePropertyGPSDictionary] != nil,
          "the JPEG made here carries a GPS position and its city")
    let sent = PhotoAttachment.prepare(jpeg, baseName: "photo_1", fallbackExtension: "jpeg")
    check(sent.filename == "photo_1.jpg", "it is sent as a JPEG")
    check(!carriesLocation(sent.data), "with no GPS, IPTC or city left anywhere in its bytes")
    check(properties(sent.data)?[kCGImagePropertyExifDictionary] == nil, "and no other EXIF")
    if let (w, h, orientation) = pixelSize(sent.data) {
        check(w == 64 && h == 32 && orientation == 6, "it keeps its orientation tag, so it stays upright (\(w)x\(h), \(orientation ?? 0))")
    } else {
        check(false, "it decodes")
    }
    // The compressed picture is untouched: from the first quantisation
    // table to the end of the image, the bytes are the original's.
    let tables: [UInt8] = [0xFF, 0xDB]
    check(suffix(sent.data, from: tables) != nil && suffix(sent.data, from: tables) == suffix(jpeg, from: tables),
          "its tables, frame and scans are the original bytes")
    check(contains(jpeg, "ICC_PROFILE") == contains(sent.data, "ICC_PROFILE"), "its colour profile is kept")

    let upright = PhotoAttachment.prepare(encodedImage(.jpeg, withLocation: true) ?? Data(), baseName: "p").data
    check(!carriesLocation(upright) && pixelSize(upright)?.2 == nil,
          "an upright JPEG keeps no EXIF at all")
}

func testEveryOtherFormatLosesItsLocation() {
    if let heic = encodedImage(.heic, orientation: 6, withLocation: true) {
        check(carriesLocation(heic), "the HEIC made here carries a location")
        let sent = PhotoAttachment.prepare(heic, baseName: "p")
        check(sent.filename == "p.jpg" && !carriesLocation(sent.data), "a HEIC photo goes as a JPEG without it")
    } else { check(false, "a HEIC to test with") }

    if let png = encodedImage(.png, withLocation: true) {
        check(carriesLocation(png), "the PNG made here carries a location (eXIf, and XMP in iTXt)")
        let sent = PhotoAttachment.prepare(png, baseName: "p")
        check(sent.filename == "p.png" && !carriesLocation(sent.data), "a PNG goes without it")
        check(chunks(sent.data).allSatisfy { PhotoMetadata.pngChunksKept.contains($0.type) }
                && chunks(sent.data).filter { $0.type == "IDAT" }.map(\.body) == chunks(png).filter { $0.type == "IDAT" }.map(\.body),
              "keeping its image data as it was")
    } else { check(false, "a PNG to test with") }
    if let turned = encodedImage(.png, orientation: 6, withLocation: true) {
        let sent = PhotoAttachment.prepare(turned, baseName: "p")
        let size = pixelSize(sent.data)
        check(sent.filename == "p.png" && !carriesLocation(sent.data) && size?.0 == 32 && size?.1 == 64,
              "a PNG that needs turning is redrawn upright, still PNG, without it")
    } else { check(false, "a turned PNG to test with") }

    if let gif = encodedImage(.gif) {
        let tagged = gifWithMetadata(gif)
        check(contains(tagged, city), "a GIF with a comment and XMP naming the city")
        let sent = PhotoAttachment.prepare(tagged, baseName: "p")
        check(sent.filename == "p.gif" && !carriesLocation(sent.data) && sent.data == gif,
              "goes without them, the rest byte for byte")
    } else { check(false, "a GIF to test with") }

    let webp = webpWithEXIF()
    check(contains(webp, "GPS") && pixelSize(webp)?.0 == 1, "a WebP with an EXIF chunk carrying a GPS IFD")
    let sent = PhotoAttachment.prepare(webp, baseName: "p")
    check(sent.filename == "p.webp" && !contains(sent.data, "EXIF") && !contains(sent.data, "GPS"),
          "goes without its EXIF chunk")
    let riff = [UInt8](sent.data)
    let riffSize = riff.count >= 8 ? Int(riff[4]) | Int(riff[5]) << 8 | Int(riff[6]) << 16 | Int(riff[7]) << 24 : -1
    check(riffSize == riff.count - 8 && riff.count > 20 && riff[20] & 0x08 == 0 && pixelSize(sent.data)?.0 == 1,
          "with its RIFF size and its header's EXIF flag set right, and it still decodes")
}

/// The chunks of a PNG, as (type, body).
func chunks(_ data: Data) -> [(type: String, body: [UInt8])] {
    let b = [UInt8](data)
    var out: [(type: String, body: [UInt8])] = []
    var i = 8
    while i + 12 <= b.count {
        let n = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
        guard i + 12 + n <= b.count else { break }
        out.append((String(bytes: b[(i + 4)..<(i + 8)], encoding: .ascii) ?? "?", Array(b[(i + 8)..<(i + 8 + n)])))
        i += 12 + n
    }
    return out
}

/// `gif` with a comment extension and an XMP application extension naming
/// the city, put before its first block.
func gifWithMetadata(_ gif: Data) -> Data {
    var b = [UInt8](gif)
    var at = 13
    if b[10] & 0x80 != 0 { at += 3 << (Int(b[10] & 0x07) + 1) }
    let comment: [UInt8] = [0x21, 0xFE, UInt8(city.utf8.count)] + Array(city.utf8) + [0x00]
    let xmp = Array("<x:xmpmeta><photoshop:City>\(city)</photoshop:City></x:xmpmeta>".utf8)
    let app: [UInt8] = [0x21, 0xFF, 11] + Array("XMP DataXMP".utf8) + [UInt8(xmp.count)] + xmp + [0x00]
    b.insert(contentsOf: comment + app, at: at)
    return Data(b)
}

/// A 1 x 1 lossless WebP (the well-known one), in the extended format with
/// an EXIF chunk holding a GPS IFD.
func webpWithEXIF() -> Data {
    let vp8l = [UInt8](Data(base64Encoded: "UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==")!)[12...]
    let tiff: [UInt8] = [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08,
                         0x00, 0x01, 0x88, 0x25, 0x00, 0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x1A,
                         0x00, 0x00, 0x00, 0x00,
                         0x00, 0x01, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x4E, 0x00, 0x00, 0x00,
                         0x00, 0x00, 0x00, 0x00] + Array("GPS".utf8) + [0x00]
    func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let n = body.count
        return Array(type.utf8) + [UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), 0, 0] + body + (n % 2 == 1 ? [0] : [])
    }
    let vp8x = chunk("VP8X", [0x08, 0, 0, 0, 0, 0, 0, 0, 0, 0])  // EXIF flag, 1 x 1 canvas
    let body = Array("WEBP".utf8) + vp8x + Array(vp8l) + chunk("EXIF", tiff)
    let n = body.count
    return Data(Array("RIFF".utf8) + [UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), 0, 0] + body)
}

// MARK: - Formats and names

func testAHeicPhotoGoesAsAnUprightJPEG() {
    guard let heic = encodedImage(.heic, orientation: 6) else {
        check(false, "this Mac's ImageIO encodes a HEIC to test with")
        return
    }
    if case .isoMedia = PhotoAttachment.format(of: heic) {
        check(true, "a HEIC is told by its ftyp box")
    } else {
        check(false, "a HEIC is told by its ftyp box")
    }
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

func testFormatsEveryClientShowsKeepTheirName() {
    for (type, ext) in [(UTType.jpeg, "jpg"), (.png, "png"), (.gif, "gif")] {
        if let data = encodedImage(type) {
            let sent = PhotoAttachment.prepare(data, baseName: "p")
            check(sent.filename == "p.\(ext)" && pixelSize(sent.data)?.0 == 64, "a \(ext.uppercased()) is sent as one, named .\(ext)")
        } else { check(false, "a \(ext) to test with") }
    }
    check(PhotoAttachment.format(of: webpWithEXIF()) == .webp, "a WebP is told by its RIFF header")
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
        testAJPEGLosesItsLocationAndKeepsItsPicture()
        testEveryOtherFormatLosesItsLocation()
        testAHeicPhotoGoesAsAnUprightJPEG()
        testFormatsEveryClientShowsKeepTheirName()
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
