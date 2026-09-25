// RNodeRadioConfigTests.swift
//
// RNode frequency with 4 decimal places and spreading factors down to SF5
// (James, 2026-09-25: someone asked for both). Until then the editor showed
// and parsed 3 decimals through a Double: reopening the editor on 868.1234
// MHz rewrote it as 868.123, and UInt64(256.0001 * 1_000_000) stored
// 256000099 Hz. The spreading factor picker offered only SF7..SF12, though
// RNS 1.5.2 and Reticulum-rust accept 5..12.
//
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/rnode-radio-config \
//     -import-objc-header Retichat-ios/Retichat/Bridge/CRetichatFFI.h \
//     Retichat-ios/Retichat/Models/RNodeRadioConfig.swift \
//     Retichat-ios/tests/RNodeRadioConfigTests.swift && \
//     /private/tmp/claude-501/rnode-radio-config
//
// The header supplies the RnsRNodeRadioConfig struct; nothing here calls the
// FFI, so no library is linked. The view checks read the source, like
// HeldSendsTests.swift: the views need SwiftUI and the FFI, so what they
// parse and show with is asserted on the code itself.

import Foundation

var failures: [String] = []

func check(_ condition: @autoclosure () -> Bool, _ name: String, _ detail: String = "") {
    if condition() {
        print("ok    - \(name)")
    } else {
        let message = detail.isEmpty ? name : "\(name) — \(detail)"
        print("FAIL  - \(message)")
        failures.append(message)
    }
}

func parse(_ text: String) -> UInt64? { RNodeRadioConfig.frequencyHz(fromMegahertz: text) }
func format(_ hz: UInt64) -> String { RNodeRadioConfig.megahertzText(forHz: hz) }

// MARK: - Frequency

func testFourDecimalsParseExactly() {
    let cases: [(String, UInt64)] = [
        ("868.1234", 868_123_400),
        ("433.05", 433_050_000),
        ("869.525", 869_525_000),
        ("256.0001", 256_000_100),   // UInt64(256.0001 * 1_000_000) is 256000099
        ("512.0002", 512_000_200),   // and this one 512000199
        ("868", 868_000_000),
        ("868.", 868_000_000),       // mid-typing
        (" 915.0 ", 915_000_000),
        ("868,1234", 868_123_400),   // the decimal pad's comma
        ("137", 137_000_000),
        ("3000", 3_000_000_000),
    ]
    for (text, hz) in cases {
        check(parse(text) == hz, "\"\(text)\" is \(hz) Hz", "got \(String(describing: parse(text)))")
    }
}

func testRejectsWhatTheInterfaceWouldNot() {
    let cases: [(String, String)] = [
        ("868.12345", "more than 4 decimal places"),
        ("136.9999", "below 137 MHz (FREQ_MIN)"),
        ("3000.0001", "above 3000 MHz (FREQ_MAX)"),
        ("86.1", "a typo below the range"),
        ("", "empty"),
        (".5", "no whole MHz"),
        ("abc", "not a number"),
        ("868.1.2", "two decimal points"),
        ("-868", "negative"),
        ("1e3", "exponent"),
        ("868.12a", "trailing letters"),
        ("99999999999999999999", "overflows UInt64"),
    ]
    for (text, why) in cases {
        check(parse(text) == nil, "\"\(text)\" is rejected: \(why)", "got \(String(describing: parse(text)))")
    }
    check(RNodeRadioConfig.frequencyRange == 137_000_000...3_000_000_000,
          "the range is RNS FREQ_MIN...FREQ_MAX")
    check(RNodeRadioConfig.frequencyRequirement == "137 to 3000 MHz, at most 4 decimal places",
          "the editor's message states the range and places",
          RNodeRadioConfig.frequencyRequirement)
}

func testFormatsFourDecimals() {
    check(format(868_123_400) == "868.1234", "868123400 Hz shows 868.1234", format(868_123_400))
    check(format(433_050_000) == "433.0500", "433050000 Hz shows 433.0500", format(433_050_000))
    check(format(867_500_000) == "867.5000", "the default shows 867.5000", format(867_500_000))
    check(format(3_000_000_000) == "3000.0000", "3000 MHz shows 3000.0000", format(3_000_000_000))
    // A value the old parse stored shows (and re-saves) as the intended one.
    check(format(256_000_099) == "256.0001", "256000099 Hz shows 256.0001", format(256_000_099))
    check(parse(format(256_000_099)) == 256_000_100, "and re-parses to 256000100 Hz")
}

func testRoundTrips() {
    // Every 100 Hz step in bands where a Double product truncates (256,
    // 512, 1024, 2048 MHz) and in common LoRa bands.
    var mismatches: [String] = []
    for mhz: UInt64 in [256, 433, 512, 868, 869, 915, 1024, 2048, 2400] {
        for step: UInt64 in 0..<10_000 {
            let hz = mhz * 1_000_000 + step * 100
            let text = format(hz)
            if parse(text) != hz || format(parse(text) ?? 0) != text {
                mismatches.append("\(hz) -> \(text)")
            }
        }
    }
    check(mismatches.isEmpty, "every 100 Hz step round-trips through the text",
          "\(mismatches.count), e.g. \(mismatches.prefix(3))")
}

// MARK: - Spreading factor

func testSpreadingFactorFiveToTwelve() {
    check(LoRaSpreadingFactor(rawValue: 5) != nil, "SF5 is accepted")
    check(LoRaSpreadingFactor(rawValue: 12) != nil, "SF12 is accepted")
    check(LoRaSpreadingFactor(rawValue: 4) == nil, "SF4 is not")
    check(LoRaSpreadingFactor(rawValue: 13) == nil, "SF13 is not")
    check(LoRaSpreadingFactor.allCases.map(\.rawValue) == Array(5...12),
          "the pickers offer SF5..SF12", "\(LoRaSpreadingFactor.allCases.map(\.rawValue))")
    check(LoRaSpreadingFactor.allCases.first?.label == "SF5", "the first is labelled SF5")

    var radio = RNodeRadioConfig.default
    radio.spreadingFactor = LoRaSpreadingFactor(rawValue: 5) ?? .sf12
    let saved = try? JSONEncoder().encode(radio)
    let loaded = saved.flatMap { try? JSONDecoder().decode(RNodeRadioConfig.self, from: $0) }
    check(loaded?.spreadingFactor.rawValue == 5, "a saved SF5 profile loads back as SF5")
    check(radio.withCConfig { $0.sf } == 5, "SF5 reaches the C config")

    let json = String(data: saved ?? Data(), encoding: .utf8) ?? ""
    let sf4 = json.replacingOccurrences(of: "\"spreadingFactor\":5", with: "\"spreadingFactor\":4")
    check(sf4 != json && (try? JSONDecoder().decode(RNodeRadioConfig.self, from: Data(sf4.utf8))) == nil,
          "a saved SF4 does not load")

    // RNode firmware (1.85) runs SF5 on an SX127x as SF6 and reports SF5,
    // and an SX127x takes SF6 only in implicit-header mode, which RNS never
    // selects: SF5 and SF6 carry a note, SF7..SF12 none.
    for sf in LoRaSpreadingFactor.allCases {
        let noted = sf.rawValue <= 6
        check((sf.radioCaveat != nil) == noted,
              "\(sf.label) \(noted ? "carries the" : "has no") SX127x note", sf.radioCaveat ?? "nil")
    }
    check(LoRaSpreadingFactor(rawValue: 5)?.radioCaveat
            == "SF5 and SF6 need an SX126x or SX128x radio. An SX127x RNode cannot use SF5 "
            + "(its firmware substitutes SF6 and still reports SF5).",
          "the note does not promise SF6 works on an SX127x")
}

// MARK: - Views (source)

func sourceFile(_ components: [String]) throws -> String {
    let url = components.reduce(
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    ) { $0.appendingPathComponent($1) }
    return try String(contentsOf: url, encoding: .utf8)
}

func testViewsUseTheModel() {
    let editor, standalone, settings: String
    do {
        editor = try sourceFile(["Retichat", "Views", "Settings", "RNodeInterfaceEditorView.swift"])
        standalone = try sourceFile(["Retichat", "Views", "Settings", "RNodeSettingsView.swift"])
        settings = try sourceFile(["Retichat", "Views", "Settings", "SettingsView.swift"])
    } catch {
        check(false, "reads the Settings view sources", String(describing: error))
        return
    }

    check(editor.contains("RNodeRadioConfig.frequencyHz(fromMegahertz: freqMHzText)"),
          "the editor parses with the model")
    check(editor.contains("freqMHzText = RNodeRadioConfig.megahertzText(forHz: profile.radio.frequency)"),
          "the editor shows the model's 4 decimals")
    check(editor.contains(".disabled(name.isEmpty || frequencyHz == nil)"),
          "the editor cannot save a frequency the interface rejects")
    check(editor.contains("RNodeRadioConfig.frequencyRequirement"),
          "the editor says why")
    check(standalone.contains("RNodeRadioConfig.frequencyHz(fromMegahertz: freqMHz)")
            && standalone.contains("RNodeRadioConfig.frequencyRequirement"),
          "RNodeSettingsView parses with the model and says why")
    check(settings.contains("RNodeRadioConfig.megahertzText(forHz: p.radio.frequency)"),
          "the interface row shows the model's 4 decimals")
    check(settings.contains("guard RNodeRadioConfig.frequencyRange.contains(p.radio.frequency) else {\n"
                            + "                    return \"RNode • \\(dev) • \\(mhz) • frequency out of range\""),
          "the interface row flags a saved frequency the interface rejects")

    for (name, source) in [("RNodeInterfaceEditorView", editor), ("RNodeSettingsView", standalone),
                           ("SettingsView", settings)] {
        check(!source.contains("%.3f"), "\(name) formats no frequency with 3 decimals")
        check(!source.contains("* 1_000_000"), "\(name) multiplies no Double into Hz")
    }
    for (name, source, selection) in [("RNodeInterfaceEditorView", editor, "profile.radio.spreadingFactor"),
                                      ("RNodeSettingsView", standalone, "sf")] {
        check(source.contains("ForEach(LoRaSpreadingFactor.allCases"),
              "\(name) offers every spreading factor the model has")
        check(source.contains("if let caveat = \(selection).radioCaveat {\n                Text(caveat)"),
              "\(name) shows the SX127x note under the chosen spreading factor")
    }
}

@main
enum RNodeRadioConfigTests {
    static func main() {
        testFourDecimalsParseExactly()
        testRejectsWhatTheInterfaceWouldNot()
        testFormatsFourDecimals()
        testRoundTrips()
        testSpreadingFactorFiveToTwelve()
        testViewsUseTheModel()

        if failures.isEmpty {
            print("all RNode radio config tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
