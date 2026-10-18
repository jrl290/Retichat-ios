// CopyLabelTests.swift
//
// The copy buttons' "Copied!" feedback (L83, from the 09-29/30 device round):
// the label's text was swapped for "Copied!", so the button changed width as
// it switched, which moved Share beside Copy name on the channel sheet, and
// the two texts crossfaded over each other. CopyLabel lays out both and shows
// one, unanimated; every copy button uses it.
//
// Run from the workspace root with:
//
//   swiftc -parse-as-library -o /private/tmp/claude-501/copy-label \
//     Retichat-ios/tests/CopyLabelTests.swift && \
//     /private/tmp/claude-501/copy-label
//
// CopyLabel needs SwiftUI, so it and the buttons are asserted on the source,
// like NSEChannelPullTests.swift; the widths are checked in the simulator.

import Foundation

nonisolated(unsafe) var failures: [String] = []

func check(_ ok: Bool, _ what: String, _ detail: String = "") {
    if ok {
        print("ok    - \(what)")
    } else {
        let message = detail.isEmpty ? what : "\(what) — \(detail)"
        failures.append(message)
        print("FAIL  - \(message)")
    }
}

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func source(_ path: String) -> String {
    (try? String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

/// From `signature` to the next top-level declaration.
func body(of signature: String, in text: String) -> String {
    guard let start = text.range(of: signature) else { return "" }
    let rest = text[start.upperBound...]
    let end = rest.range(of: "\n// MARK: ")?.lowerBound ?? rest.endIndex
    return String(rest[..<end])
}

func testCopyLabelKeepsItsWidth() {
    let label = body(of: "struct CopyLabel: View {", in: source("Retichat/Views/Components/GlassComponents.swift"))
    check(!label.isEmpty, "CopyLabel is in GlassComponents.swift")
    check(label.contains("ZStack {")
          && label.contains("Label(title, systemImage: systemImage)")
          && label.contains("Label(\"Copied!\", systemImage: systemImage)"),
          "both labels are laid out, so the button is as wide as the wider")
    check(label.contains(".opacity(copied ? 0 : 1)") && label.contains(".opacity(copied ? 1 : 0)"),
          "and one is shown")
    check(label.contains(".accessibilityHidden(copied)") && label.contains(".accessibilityHidden(!copied)"),
          "VoiceOver reads only the one shown")
    check(label.contains(".animation(nil, value: copied)"), "the switch is not animated, so they never crossfade")
}

func testEveryCopyButtonUsesIt() {
    let channel = source("Retichat/Views/Channels/ChannelView.swift")
    let qr = source("Retichat/Views/QRCode/QRCodeView.swift")
    check(channel.contains("CopyLabel(\"Copy name\", systemImage: \"doc.on.doc\", copied: copiedName)"),
          "the channel sheet's Copy name")
    check(qr.contains("CopyLabel(\"Copy Hash\", systemImage: \"doc.on.doc\", copied: copiedHash)"),
          "the QR code sheet's Copy Hash")
    check(qr.contains("CopyLabel(\"Copy Contact URI\", systemImage: \"link\", copied: copiedUri)"),
          "the QR code sheet's Copy Contact URI")

    var swapping: [String] = []
    let app = repoRoot.appendingPathComponent("Retichat")
    let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
    while let url = files?.nextObject() as? URL {
        guard url.pathExtension == "swift",
              let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        if text.contains("? \"Copied!\" :") { swapping.append(url.lastPathComponent) }
    }
    check(swapping.isEmpty, "no label swaps its text for \"Copied!\"", swapping.joined(separator: ", "))
}

@main
enum CopyLabelTests {
    static func main() {
        testCopyLabelKeepsItsWidth()
        testEveryCopyButtonUsesIt()
        if failures.isEmpty {
            print("all copy label tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
