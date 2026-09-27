// NSEChannelPullTests.swift
//
// A push for a channel message (2026-09-26): the NSE pulls that channel from
// RFed, saves every blob for the app first, shows only a signature-verified
// message named as the app names channel notifications, and keeps the alert
// when the pull did not complete; the app shares what the pull needs and
// ingests the saved blobs. Also the push toggle's disable path, which passed
// the unregister hash where the register hash belongs.
//
// Run from the workspace root with:
//
//   { echo 'import Foundation'; \
//     sed -n '/^\/\/ BEGIN NSEChannelUnpackDecoder/,/^\/\/ END NSEChannelUnpackDecoder/p' \
//     Retichat-ios/NotificationService/NSEChannelPull.swift; } \
//     > /private/tmp/claude-501/NSEChannelUnpackDecoder.swift && \
//   swiftc -o /private/tmp/claude-501/nse-channel-pull \
//     /private/tmp/claude-501/NSEChannelUnpackDecoder.swift \
//     Retichat-ios/Retichat/Bridge/LxmfFields.swift \
//     Retichat-ios/Retichat/Services/PendingNotification.swift \
//     Retichat-ios/tests/NSEChannelPullTests.swift && \
//     /private/tmp/claude-501/nse-channel-pull
//
// Since 2026-09-27 (DISPLAY_NAMES.md) the unpack output ends in the post's
// Channel Display Name, parsed by ChannelUnpackLayout in LxmfFields.swift,
// which the app's RetichatBridge.channelLxmUnpack uses too.
//
// The directory, the blob store and the unpack decoder run for real (the store
// against a scratch directory, never the App Group). The NSE and app wiring
// needs UIKit, the FFI and SwiftData, so it is asserted on the source, like
// NSEDistroPullTests.swift.

import Foundation

nonisolated(unsafe) var failures: [String] = []

func check(_ ok: Bool, _ what: String) {
    if !ok { failures.append(what); print("FAIL: \(what)") }
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

func testTheDirectoryRoundTrips() {
    let entry = PendingNotification.ChannelPushEntry(
        channel: "AB" + String(repeating: "cd", count: 15), name: "public.general",
        pull: String(repeating: "11", count: 16), sources: [String(repeating: "22", count: 16)], notify: false)
    guard let data = PendingNotification.encodeChannelPushDirectory([entry]) else {
        check(false, "the directory encodes")
        return
    }
    let decoded = PendingNotification.decodeChannelPushDirectory(data)
    check(decoded[entry.channel.lowercased()] == entry, "an entry comes back under its lowercase channel hex")
    check(decoded[entry.channel.lowercased()]?.notify == false, "the Notifications toggle travels with it")
    check(PendingNotification.decodeChannelPushDirectory(Data("not json".utf8)).isEmpty, "garbage decodes to no entries")
}

func testSavedChannelBlobsComeBackOnceWithTheirChannel() {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("nse-channel-blobs-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let a = Data(repeating: 0xA1, count: 16), b = Data(repeating: 0xB2, count: 16)
    check(PendingNotification.saveNSEChannelBlobs([(a, Data([1, 2, 3])), (b, Data(repeating: 9, count: 400))], in: dir),
          "round 1 saved")
    Thread.sleep(forTimeInterval: 0.01)
    check(PendingNotification.saveNSEChannelBlobs([(a, Data([7]))], in: dir), "round 2 saved")
    let read = PendingNotification.readAndClearNSEChannelBlobs(in: dir)
    check(read.map { $0.channel } == [a, b, a], "each blob keeps its channel, oldest round first")
    check(read.map { $0.blob } == [Data([1, 2, 3]), Data(repeating: 9, count: 400), Data([7])], "and its bytes")
    check(PendingNotification.readAndClearNSEChannelBlobs(in: dir).isEmpty, "and only once")
}

/// `trailer`: the name_state | name_len u16 BE | name bytes the Rust side
/// appends; nil leaves them off.
func unpackOutput(sigOk: Bool, title: String, content: String, truncateBy: Int = 0,
                  trailer: Data? = Data([0, 0, 0])) -> Data {
    var d = Data(repeating: 0x5C, count: 16)
    var ts = UInt64(1_790_000_000_123).bigEndian
    d.append(Data(bytes: &ts, count: 8))
    d.append(sigOk ? 1 : 0)
    d.append(sigOk ? 0 : 1)
    let t = Data(title.utf8), c = Data(content.utf8)
    var tl = UInt16(t.count).bigEndian, cl = UInt32(c.count).bigEndian
    d.append(Data(bytes: &tl, count: 2))
    d.append(Data(bytes: &cl, count: 4))
    d.append(t)
    d.append(c)
    if let trailer { d.append(trailer) }
    return d.dropLast(truncateBy)
}

func nameTrailer(_ name: String) -> Data {
    let n = Data(name.utf8)
    return Data([2, UInt8(n.count >> 8), UInt8(n.count & 0xFF)]) + n
}

func testTheUnpackLayoutDecodes() {
    let m = NSEChannelUnpackDecoder.decode(unpackOutput(sigOk: true, title: "t", content: "hello channel"))
    check(m?.sourceHash == Data(repeating: 0x5C, count: 16), "source hash")
    check(m?.timestampMs == 1_790_000_000_123, "timestamp in ms, big-endian")
    check(m?.signatureValidated == true, "signature flag")
    check(m?.title == "t" && m?.content == "hello channel", "title and content")
    check(NSEChannelUnpackDecoder.decode(unpackOutput(sigOk: false, title: "", content: "x"))?.signatureValidated == false,
          "an unverified message says so")
    check(NSEChannelUnpackDecoder.decode(unpackOutput(sigOk: true, title: "t", content: "hello", truncateBy: 5)) == nil,
          "a truncated output is rejected")

    // The trailer: the post's Channel Display Name (DISPLAY_NAMES.md §2.3).
    check(m?.displayName == .absent, "a post without 0xD1 names nobody")
    let named = NSEChannelUnpackDecoder.decode(unpackOutput(sigOk: true, title: "", content: "hi",
                                                            trailer: nameTrailer("Zoë \u{1F600}")))
    check(named?.displayName == .name("Zoë \u{1F600}"), "a validated post's name is read as UTF-8")
    check(named?.content == "hi", "and the content still ends where content_len says")
    check(NSEChannelUnpackDecoder.decode(unpackOutput(sigOk: true, title: "", content: "hi",
                                                      trailer: Data([1, 0, 0])))?.displayName == .clear,
          "an empty 0xD1 is a clear")
    check(NSEChannelUnpackDecoder.decode(unpackOutput(sigOk: false, title: "", content: "hi",
                                                      trailer: nameTrailer("Mallory")))?.displayName == .absent,
          "an unvalidated post names nobody, whatever its trailer says")
    check(NSEChannelUnpackDecoder.decode(unpackOutput(sigOk: true, title: "", content: "hi",
                                                      trailer: nil))?.displayName == .absent,
          "no trailer reads as no name")
}

func testTheWiring() {
    let pull = source("NotificationService/NSEChannelPull.swift")
    check(before(pull, "NSEDistroPull.ensurePath(to: dest", "NSEDistroPull.linkRequest("),
          "the NSE has a confirmed path to rfed.channel.pull before its request (the distro lesson)")
    check(pull.contains("aspects: \"channel,pull\", path: \"/rfed/pull\""), "it pulls /rfed/pull on rfed.channel.pull")
    check(before(pull, "PendingNotification.saveNSEChannelBlobs(", "unpackToShow(name: entry.name"),
          "every pulled blob is saved before any is unpacked (the pull drained RFed)")
    check(pull.contains("if entry.notify {"), "nothing is unpacked to show when the channel's Notifications are off")
    check(pull.contains("message.signatureValidated else { return nil }"), "only a signature-verified message is shown")
    check(pull.contains("shown.senderHash != ownHex"), "our own echoed message is not shown (the app never notifies it)")

    let nse = source("NotificationService/NotificationService.swift")
    check(nse.contains("(request.content.userInfo[\"rfed\"] as? [String: Any])?[\"channel\"] as? String"),
          "the NSE reads the channel from the push (apns-bridge rfed.channel)")
    check(before(nse, "channelPull = NSEChannelPull.run(", "distro = NSEDistroPull.run("),
          "a channel push pulls the channel; any other push pulls the distro")
    check(nse.contains("DisplayNames.channelNotificationTitle(channelName: channelPull.channelName, label: label)")
            && source("Retichat/Services/RfedChannelClient.swift").contains(
                "senderName: DisplayNames.channelNotificationTitle(channelName: channel.channelName, label: label)"),
          "a channel message is named as the app names its channel notifications")
    check(nse.contains("best.userInfo[\"chatId\"] = msg.thread"), "tapping opens the channel")
    check(before(nse, "} else if channelPull.failed {", "} else if summary.dropped > 0 || distro.pulled > 0 || channelPull.pulled > 0 {"),
          "an incomplete channel pull keeps the alert; it is decided before any suppression")
    check(before(nse, "} else if channelPull.silenced {", "} else if channelPull.failed {")
            && before(nse, "} else if channelPull.silenced {", "NSLog(\"[NSE] sync failed after %ds — showing generic alert\", elapsed)"),
          "a silenced channel shows nothing, not even the generic alert when its pull or the sync fails")
    check(nse.contains("if start.addingTimeInterval(20).timeIntervalSinceNow > 8 {\n                    distro = NSEDistroPull.run("),
          "a channel push also pulls the distro while time is left (APNs keeps one pending push)")

    let client = source("Retichat/Services/RfedChannelClient.swift")
    let disable = client.range(of: "func disableChannelPush(channelHashHex: String) {")
        .map { String(client[$0.lowerBound...].prefix(1200)) } ?? ""
    check(disable.contains("aspects: [\"notify\", \"register\"])") && !disable.contains("aspects: [\"notify\", \"unregister\"])"),
          "disable passes the register hash, so switching push back on sends again")
    check(client.components(separatedBy: "publishPushDirectory()").count >= 5,
          "the directory is rewritten on enable, disable, leave and load")
    check(client.contains("guard didLoadPersistedState, !ownHashHex.isEmpty, !channels.isEmpty else { return }\n        let pairs = PendingNotification.readAndClearNSEChannelBlobs()"),
          "saved blobs are read only once channels, messages and our own hash are loaded (review of 793a542)")
    check(client.contains("dispatchBlob(channelHashHex: pair.channel.hexString, blob: pair.blob, notify: false)")
            && client.contains("if notify, !isOutgoing, let channel = channels.first"),
          "blobs the NSE showed are stored without a second notification")
    let distroClient = source("Retichat/Services/RfedDistroClient.swift")
    let repo = source("Retichat/Services/ChatRepository.swift")
    check(distroClient.contains("ingestBlob(blob, shownByNSE: true)") && repo.contains("notify: !m.shownByNSE")
            && repo.contains("if notify {\n            let notifyName = contactDisplayName(for: srcHex)"),
          "distro blobs the NSE showed are stored without a second notification")
    check(source("Retichat/Views/Navigation/ContentView.swift").contains(
            "if let channel = channelClient.channels.first(where: { $0.id.lowercased() == chatId.lowercased() }) {"),
          "tapping a channel notification opens the channel, not a DM to its hash")
    check(source("Retichat/RetichatApp.swift").components(separatedBy: "channelClient.importNSEBlobs()").count == 4,
          "the app ingests them wherever it imports the NSE's messages")
    check(source("Retichat/Views/Channels/ChannelView.swift").contains("defer { channelClient.publishPushDirectory() }"),
          "the Notifications toggle rewrites the directory")
}

@main
enum NSEChannelPullTests {
    static func main() {
        testTheDirectoryRoundTrips()
        testSavedChannelBlobsComeBackOnceWithTheirChannel()
        testTheUnpackLayoutDecodes()
        testTheWiring()
        if failures.isEmpty {
            print("all NSE channel pull tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
