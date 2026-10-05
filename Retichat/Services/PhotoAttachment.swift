//
//  PhotoAttachment.swift
//  Retichat
//
//  What a photo or video picked in a conversation is sent as. Until
//  2026-10-05 the picker's bytes were sent as they came, named
//  "photo_<time>.jpg": an iPhone photo is HEIC, which browsers cannot show
//  and Android does not take for an image, so the web and Android saw a
//  broken picture or a file. The name now always says what the bytes are,
//  and a still image the other clients cannot be relied on to show goes as
//  JPEG. Foundation and ImageIO only, so tests/PhotoAttachmentTests.swift
//  runs it for real (on macOS, whose ImageIO is iOS's).
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum PhotoAttachment {
    /// The formats told apart by their first bytes.
    enum Format: Equatable {
        case jpeg, png, gif, webp
        /// An ISO base media file (HEIC/HEIF, AVIF, MP4, QuickTime) with its
        /// major brand.
        case isoMedia(brand: String)
        case unknown
    }

    /// Kept as they are: every client shows these (Android's image types:
    /// jpg, png, gif, webp; browsers all four).
    static func passThroughExtension(_ format: Format) -> String? {
        switch format {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .gif: return "gif"
        case .webp: return "webp"
        default: return nil
        }
    }

    static func format(of data: Data) -> Format {
        let b = [UInt8](data.prefix(12))
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return .jpeg }
        if b.count >= 8, b[0..<8] == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return .png }
        if b.count >= 6, let head = String(bytes: b[0..<6], encoding: .ascii),
           head == "GIF87a" || head == "GIF89a" { return .gif }
        if b.count >= 12, String(bytes: b[0..<4], encoding: .ascii) == "RIFF",
           String(bytes: b[8..<12], encoding: .ascii) == "WEBP" { return .webp }
        if b.count >= 12, String(bytes: b[4..<8], encoding: .ascii) == "ftyp",
           let brand = String(bytes: b[8..<12], encoding: .ascii) {
            return .isoMedia(brand: brand)
        }
        return .unknown
    }

    /// The attachment for bytes the picker gave, named `baseName` plus the
    /// extension of what is sent:
    /// - JPEG, PNG, GIF and WebP are sent as they are (".jpg", ".png", ...);
    /// - any other still image ImageIO reads (HEIC, HEIF, AVIF, TIFF, ...)
    ///   is drawn upright (its orientation applied) and sent as JPEG;
    /// - anything else (a video) is sent as it is, named by
    ///   `fallbackExtension` (the picked item's own type, e.g. "mov"), else
    ///   by its container (".mov" for QuickTime, ".mp4" for another ISO
    ///   media file), else ".bin". Never ".jpg" for bytes that are not JPEG.
    static func prepare(_ data: Data, baseName: String, fallbackExtension: String? = nil) -> (filename: String, data: Data) {
        let format = format(of: data)
        if let ext = passThroughExtension(format) { return ("\(baseName).\(ext)", data) }
        if let jpeg = uprightJPEG(from: data) { return ("\(baseName).jpg", jpeg) }
        let ext: String
        if let fallbackExtension, !fallbackExtension.isEmpty {
            ext = fallbackExtension
        } else if case .isoMedia(let brand) = format {
            ext = brand == "qt  " ? "mov" : "mp4"
        } else {
            ext = "bin"
        }
        return ("\(baseName).\(ext)", data)
    }

    /// The first image in `data` as JPEG, with its orientation applied to
    /// the pixels (receivers that ignore the EXIF orientation still show it
    /// upright) at full size; nil when `data` holds no still image.
    static func uprightJPEG(from data: Data, quality: Double = 0.85) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              let uti = UTType(type), uti.conforms(to: .image),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}
