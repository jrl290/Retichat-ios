//
//  PhotoMetadata.swift
//  Retichat
//
//  No photo leaves the phone with its location (James, 2026-10-05: "strip
//  from every photo"). EXIF carries GPS, and XMP, IPTC and other text can
//  carry it too (coordinates, city, country), so each format keeps only what
//  draws the picture: the compressed image itself, byte for byte, and what
//  its colours need (an ICC profile, Adobe's colour transform, PNG's colour
//  chunks). Everything else in the file goes: EXIF, XMP, IPTC, comments,
//  text chunks, vendor segments and trailing images. A JPEG keeps its
//  orientation as a minimal EXIF holding only that tag, so it stays upright
//  without being decoded again; a PNG or WebP that needs turning is redrawn
//  upright by PhotoAttachment instead. Foundation only, so
//  tests/PhotoAttachmentTests.swift runs it for real.
//

import Foundation

nonisolated enum PhotoMetadata {
    // MARK: JPEG

    /// `data` (a JPEG) with every metadata segment removed and, when
    /// `orientation` is not 1, a minimal EXIF holding only that orientation:
    /// the tables, frame headers and scans are copied as they are, up to
    /// the first end-of-image (data after it, such as the extra images of a
    /// multi-picture file, goes too). Kept: APP0 (JFIF), APP2 when it is an
    /// ICC profile, APP14 (Adobe colour transform) and every non-APP
    /// segment. Dropped: APP1 (EXIF and XMP), APP13 (IPTC), every other APPn
    /// and comments. nil when `data` is not a JPEG this reads to the end.
    static func strippedJPEG(_ data: Data, orientation: Int) -> Data? {
        let b = [UInt8](data)
        let n = b.count
        guard n >= 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var segments: [UInt8] = []
        var leadingAPP0: [UInt8] = []
        var i = 2
        var ended = false
        while i < n {
            guard b[i] == 0xFF else { return nil }
            var m = i + 1
            while m < n, b[m] == 0xFF { m += 1 }  // fill bytes
            guard m < n else { return nil }
            let marker = b[m]
            if marker == 0xD9 {
                segments += [0xFF, 0xD9]
                ended = true
                break
            }
            if (0xD0...0xD7).contains(marker) || marker == 0x01 {
                segments += [0xFF, marker]
                i = m + 1
                continue
            }
            guard m + 2 < n else { return nil }
            let length = Int(b[m + 1]) << 8 | Int(b[m + 2])
            let end = m + 1 + length
            guard length >= 2, end <= n else { return nil }
            if marker == 0xDA {
                // Start of scan: its header, then the entropy-coded data up
                // to the next marker (FF00 is a stuffed byte, FFD0-FFD7 a
                // restart).
                var j = end
                while j < n {
                    if b[j] == 0xFF, j + 1 < n {
                        let next = b[j + 1]
                        if next == 0x00 || (0xD0...0xD7).contains(next) { j += 2; continue }
                        break
                    }
                    j += 1
                }
                segments += [0xFF, marker]
                segments += b[(m + 1)..<j]
                i = j
                continue
            }
            let segment = [0xFF, marker] + Array(b[(m + 1)..<end])
            if keepsJPEGSegment(marker, payload: b[(m + 3)..<end]) {
                if marker == 0xE0, segments.isEmpty, leadingAPP0.isEmpty {
                    leadingAPP0 = segment
                } else {
                    segments += segment
                }
            }
            i = end
        }
        guard ended else { return nil }
        var out: [UInt8] = [0xFF, 0xD8] + leadingAPP0
        if (2...8).contains(orientation) { out += orientationEXIF(orientation) }
        out += segments
        return Data(out)
    }

    private static func keepsJPEGSegment(_ marker: UInt8, payload: ArraySlice<UInt8>) -> Bool {
        switch marker {
        case 0xE0, 0xEE:
            return true  // JFIF, Adobe
        case 0xE2:
            return payload.starts(with: Array("ICC_PROFILE\u{0}".utf8))
        case 0xE1, 0xE3...0xED, 0xEF, 0xFE:
            return false  // EXIF, XMP, IPTC, other vendor data, comments
        default:
            return true
        }
    }

    /// An APP1 EXIF segment holding only the orientation (TIFF big-endian,
    /// IFD0 with the one entry 0x0112).
    static func orientationEXIF(_ orientation: Int) -> [UInt8] {
        let tiff: [UInt8] = [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08,  // "MM", 42, IFD0 at 8
                             0x00, 0x01,                                      // one entry
                             0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01,  // Orientation, SHORT, 1
                             0x00, UInt8(orientation), 0x00, 0x00,
                             0x00, 0x00, 0x00, 0x00]                          // no next IFD
        let payload = Array("Exif".utf8) + [0x00, 0x00] + tiff
        let length = payload.count + 2
        return [0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
    }

    // MARK: PNG

    /// The chunks a PNG needs to draw its picture, kept as they are.
    static let pngChunksKept: Set<String> = [
        "IHDR", "PLTE", "IDAT", "IEND", "tRNS", "gAMA", "cHRM", "sRGB", "iCCP", "sBIT", "bKGD", "pHYs",
        "cICP", "mDCv", "cLLi", "acTL", "fcTL", "fdAT",
    ]

    /// `data` (a PNG) with only `pngChunksKept`: eXIf (EXIF), the text
    /// chunks (tEXt, zTXt, iTXt, where XMP lives) and every other chunk go.
    /// nil when `data` is not a PNG this reads to IEND.
    static func strippedPNG(_ data: Data) -> Data? {
        let b = [UInt8](data)
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard b.count >= 8, Array(b[0..<8]) == signature else { return nil }
        var out = signature
        var i = 8
        while i + 12 <= b.count {
            let length = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            let end = i + 12 + length
            guard length >= 0, end <= b.count, let type = String(bytes: b[(i + 4)..<(i + 8)], encoding: .ascii)
            else { return nil }
            if pngChunksKept.contains(type) { out += b[i..<end] }
            if type == "IEND" { return Data(out) }
            i = end
        }
        return nil
    }

    // MARK: GIF

    /// `data` (a GIF) without comment extensions and application
    /// extensions other than the looping ones (NETSCAPE2.0, ANIMEXTS1.0) and
    /// an ICC profile (ICCRGBG1): XMP rides in one ("XMP DataXMP"). Frames,
    /// colour tables and timing are copied as they are. nil when `data` is
    /// not a GIF this reads to its trailer.
    static func strippedGIF(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count >= 13, let head = String(bytes: b[0..<6], encoding: .ascii),
              head == "GIF87a" || head == "GIF89a" else { return nil }
        var i = 13
        if b[10] & 0x80 != 0 { i += 3 << (Int(b[10] & 0x07) + 1) }
        guard i <= b.count else { return nil }
        var out = Array(b[0..<i])
        /// The end of the sub-blocks starting at `at` (after the zero block).
        func subBlocksEnd(_ at: Int) -> Int? {
            var j = at
            while j < b.count {
                let size = Int(b[j])
                if size == 0 { return j + 1 }
                j += size + 1
            }
            return nil
        }
        while i < b.count {
            switch b[i] {
            case 0x3B:
                out.append(0x3B)
                return Data(out)
            case 0x2C:
                guard i + 10 <= b.count else { return nil }
                var j = i + 10
                if b[i + 9] & 0x80 != 0 { j += 3 << (Int(b[i + 9] & 0x07) + 1) }
                guard j < b.count, let end = subBlocksEnd(j + 1) else { return nil }
                out += b[i..<end]
                i = end
            case 0x21:
                guard i + 2 < b.count, let end = subBlocksEnd(i + 2) else { return nil }
                let label = b[i + 1]
                var keep = label == 0xF9 || label == 0x01  // graphic control, plain text
                if label == 0xFF, b[i + 2] == 11, i + 14 <= b.count,
                   let id = String(bytes: b[(i + 3)..<(i + 14)], encoding: .ascii) {
                    keep = id == "NETSCAPE2.0" || id == "ANIMEXTS1.0" || id == "ICCRGBG1012"
                }
                if keep { out += b[i..<end] }
                i = end
            default:
                return nil
            }
        }
        return nil
    }

    // MARK: WebP

    /// The chunks a WebP needs to draw its picture, kept as they are.
    static let webpChunksKept: Set<String> = ["VP8 ", "VP8L", "VP8X", "ALPH", "ANIM", "ANMF", "ICCP"]

    /// `data` (a WebP) with only `webpChunksKept` (EXIF, XMP and every other
    /// chunk go), the extended header's EXIF and XMP flags cleared and the
    /// RIFF size made to match. nil when `data` is not a WebP this reads.
    static func strippedWebP(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count >= 12, String(bytes: b[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: b[8..<12], encoding: .ascii) == "WEBP" else { return nil }
        var body: [UInt8] = Array("WEBP".utf8)
        var i = 12
        while i < b.count {
            guard i + 8 <= b.count, let type = String(bytes: b[i..<(i + 4)], encoding: .ascii) else { return nil }
            let size = Int(b[i + 4]) | Int(b[i + 5]) << 8 | Int(b[i + 6]) << 16 | Int(b[i + 7]) << 24
            let end = i + 8 + size + (size & 1)
            guard end <= b.count else { return nil }
            if webpChunksKept.contains(type) {
                var chunk = Array(b[i..<end])
                if type == "VP8X", size >= 1 { chunk[8] &= ~UInt8(0x08 | 0x04) }  // no EXIF, no XMP
                body += chunk
            }
            i = end
        }
        let size = body.count
        return Data(Array("RIFF".utf8) + [UInt8(size & 0xFF), UInt8(size >> 8 & 0xFF),
                                          UInt8(size >> 16 & 0xFF), UInt8(size >> 24 & 0xFF)] + body)
    }
}
