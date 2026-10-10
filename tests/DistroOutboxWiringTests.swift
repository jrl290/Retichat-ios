// DistroOutboxWiringTests.swift
//
// How channels and the distro are wired into the app (RFed-rust SPEC §17.12,
// §17.11, RFed-spec Channel.md "Distro holders"): who owes what, what starts the
// outbox, what must never send a membership message, which identity does what,
// and the C surface under it. The app's classes need SwiftData, UIKit and the FFI
// and are not run by a swiftc test: their source is what is pinned, as the other
// wiring tests here do. The rules themselves run for real in
// DistroOutboxTests.swift, DistroChannelSyncTests.swift and
// DistroChannelsMigrationTests.swift. A port of Retichat-android's
// DistroOutboxWiringTest, DistroChannelPostsTest (its wiring half) and
// PropagationJniContractTest.
//
// Run from the workspace root with:
//
//   swiftc -parse-as-library -o /private/tmp/claude-501/distro-outbox-wiring \
//     Retichat-ios/tests/DistroOutboxWiringTests.swift && \
//     /private/tmp/claude-501/distro-outbox-wiring

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

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func read(_ path: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

/// The text from `from` to the next `to` after it ("" and a failed check when either is missing).
func body(_ text: String, _ from: String, _ to: String) -> String {
    guard let start = text.range(of: from) else { check(false, "found: \(from)"); return "" }
    guard let end = text.range(of: to, range: start.upperBound..<text.endIndex) else { check(false, "found after it: \(to)"); return "" }
    return String(text[start.lowerBound..<end.lowerBound])
}

/// `a` appears, and before `b`.
func before(_ text: String, _ a: String, _ b: String) -> Bool {
    guard let ra = text.range(of: a), let rb = text.range(of: b) else { return false }
    return ra.lowerBound < rb.lowerBound
}

func count(_ text: String, _ needle: String) -> Int { text.components(separatedBy: needle).count - 1 }

/// The code of a Swift file with its comments taken out, so a mention is not a call.
func code(_ text: String) -> String {
    var out = text
    while let start = out.range(of: "/*"), let end = out.range(of: "*/", range: start.upperBound..<out.endIndex) {
        out.removeSubrange(start.lowerBound..<end.upperBound)
    }
    return out.components(separatedBy: "\n").map { line -> String in
        var result = ""
        var inString = false
        var previous: Character = " "
        for ch in line {
            if ch == "\"" && previous != "\\" { inString.toggle(); result.append(ch); previous = ch; continue }
            if inString { previous = ch; continue }
            result.append(ch)
            previous = ch
        }
        if let cut = result.range(of: "//") { return String(result[..<cut.lowerBound]) }
        return result
    }.joined(separator: "\n")
}

let runtime = read("Retichat/Services/DistroOutboxRuntime.swift")
let channelClient = read("Retichat/Services/RfedChannelClient.swift")
let distroClient = read("Retichat/Services/RfedDistroClient.swift")
let repository = read("Retichat/Services/ChatRepository.swift")
let bridge = read("Retichat/Bridge/RetichatBridge.swift")
let header = read("Retichat/Bridge/CRetichatFFI.h")
let rust = read("rust/retichat-ffi/src/lib.rs")
let app = read("Retichat/RetichatApp.swift")

// MARK: - The stack and the outbox

func theStackStartsTheOutboxAfterTheLinksAreWiredAndStopsItFirst() {
    let start = body(repository, "private func finishStartService(", "func stopService()")
    check(before(start, "ConnectionStateManager.shared.register(lxmfClient: client)", "DistroOutboxRuntime.shared.start(client: client)"),
          "the outbox starts after the app links are registered")
    // The router has its propagation node (and so is opening the held link) before the outbox listens.
    check(before(start, "startPropagationPolling()", "DistroOutboxRuntime.shared.start(client: client)"),
          "the router has its propagation node before the outbox listens")
    check(before(start, "DistroOutboxRuntime.shared.start(client: client)", "RfedDistroClient.shared.onStackStarted(client: client)")
            && before(start, "DistroOutboxRuntime.shared.start(client: client)", "releaseHeldSends()"),
          "and before the distro registers and before any held send is released")
    check(count(start, "DistroOutboxRuntime.shared.start(") == 1, "it is started from one place")
    let stop = body(repository, "func stopService()", "private static var bluetoothEndpointHost")
    check(stop.contains("DistroOutboxRuntime.shared.stop()")
            && before(stop, "DistroOutboxRuntime.shared.stop()", "ConnectionStateManager.shared.deregister()")
            && before(stop, "DistroOutboxRuntime.shared.stop()", "client?.shutdown()"),
          "the outbox is stopped before the stack's own shutdown drops the link callbacks")
    check(app.contains("DistroOutboxRuntime.shared.configure(container: modelContainer)")
            && before(app, "DistroOutboxRuntime.shared.configure(container: modelContainer)", "return true"),
          "the store's container is given at launch, before any stack start")
    for entity in ["ChannelNameStateEntity.self", "ChannelMembershipEntity.self", "DistroOutboxEntity.self"] {
        check(app.contains(entity), "the container holds \(entity)")
    }
}

func onlyTheUsersOwnJoinLeaveAndSendOweAnything() {
    // C is owed from one place, RfedChannelClient.recordUsersAction; the sent copy from one, ChatRepository.
    check(count(channelClient, "DistroOutboxRuntime.shared.oweChannelSync(") == 1, "C is owed from one place")
    check(count(repository, "DistroOutboxRuntime.shared.oweSentCopy(") == 1, "the sent copy is owed from one place")
    // Nothing else in the app owes the distro anything.
    for path in ["Retichat/Services/RfedDistroClient.swift", "Retichat/Services/ConnectionStateManager.swift",
                 "Retichat/RetichatApp.swift", "Retichat/Services/GroupChatManager.swift"] {
        let text = read(path)
        check(!text.contains("oweChannelSync(") && !text.contains("oweSentCopy("), "\(path) owes nothing")
    }
    let record = body(channelClient, "private func recordUsersAction(", "func handleDistroChannelSync(")
    check(record.contains("if !DistroManager.shared.has { return }"), "no distro, no message")
    // The record is made with or without a distro; the message only with one.
    check(before(record, "ChannelMembershipStore.upsert(", "DistroOutboxRuntime.shared.oweChannelSync("),
          "the record is made before the message is owed")
    check(before(record, "DistroChannelSync.stampLocal(", "ChannelMembershipStore.upsert("),
          "and stamped after any record held")
}

func theUsersOwnActionIsTheOnlyCallerOfRecordUsersAction() {
    // Its declaration and its two callers, joinChannel and leaveChannel.
    check(count(channelClient, "recordUsersAction(") == 3, "the declaration and two callers")
    let join = body(channelClient, "func joinChannel(", "/// Leave a channel.")
    // A join of a channel already in the list is no change: no message (it returns before the end).
    check(before(join, "if let existing = channels.first(where: { $0.id == channelHashHex }) {", "channels.append(channel)")
            && before(join, "channels.append(channel)", "await recordUsersAction(op: DistroChannelSync.opJoin")
            && count(join, "recordUsersAction(") == 1,
          "a join of a channel not in the list is recorded, once, after it is added")
    let leave = body(channelClient, "func leaveChannel(", "@discardableResult\n    private func leaveHere(")
    check(leave.contains("await recordUsersAction(op: DistroChannelSync.opLeave")
            && before(leave, "guard leaveHere(channelHashHex: channelHashHex) else { return }", "recordUsersAction("),
          "a leave is recorded after the channel is left, and only when it was")
}

func applyingASiblingsChangeSendsNothingAndSubscribesWithTheDevicesKey() {
    let apply = body(channelClient, "private func applyDistroChannelSync(", "/// Subscribe a channel the device has stored")
    // Never re-sent, never echoed: applying C calls neither the record nor the outbox.
    for call in ["recordUsersAction", "oweChannelSync", "joinChannel(", "leaveChannel(", "DistroOutboxRuntime"] {
        check(!apply.contains(call), "applying C does not call \(call)")
    }
    // The leave is the shared clean-up, which sends nothing; the join is stored before it is subscribed.
    check(apply.contains("leaveHere(channelHashHex: channelHash)"), "a leave is the shared clean-up")
    check(before(apply, "ctx.insert(ChannelEntity(", "Task { await self.subscribeStoredChannel(channel) }"),
          "a join is stored before it is subscribed")
    // The record is kept for every apply, including a leave (what stops an older join coming back).
    check(apply.contains("ChannelMembershipStore.upsert(channelHash: channelHash, record: .init(op: op, atMs: atMs), in: ctx)"),
          "the record is kept for every apply")
    let leaveHere = body(channelClient, "private func leaveHere(", "// MARK: - Channels and the distro")
    check(!leaveHere.contains("recordUsersAction") && !leaveHere.contains("DistroOutboxRuntime"), "the clean-up sends nothing")
    check(leaveHere.contains("ChannelNameStateStore.forget(channelHash: hash, in: ctx)"), "and takes the channel's names with it")
    // Subscribing is the device's, by the device's identity.
    let subscribe = body(channelClient, "private func subscribeStoredChannel(", "// MARK: - Channel push, for the NSE")
    check(subscribe.contains("subscribeOnServer(") && !subscribe.contains("DistroManager") && !subscribe.contains("postingHandle"),
          "subscribing a joined channel is the device's")
    // A message that arrives before the channel list is loaded is held and judged once it is.
    let handle = body(channelClient, "func handleDistroChannelSync(", "/// §17.12 rule 6")
    check(handle.contains("guard didLoadPersistedState, modelContext != nil, !ownHashHex.isEmpty else {\n            pendingChannelSync.append("),
          "a membership message before the list is loaded is held, not lost")
    check(before(channelClient, "drainPendingChannelSync()\n\n        guard identityHandle != 0 else { return }", "scheduleResubscribeOnRfedChannelActive()"),
          "and judged at start")
}

func aMembershipMessageIsReadBeforeTheGenericDedupeAndTheDeliveryNotificationTest() {
    let unwrap = body(distroClient, "nonisolated private static func unwrapAndDeliver(", "private func deliver(")
    let readAt = unwrap.range(of: "DistroChannelSync.read(parsed.fieldsRaw)")
    check(readAt != nil, "the marker is read from the unwrap's fields")
    check(before(unwrap, "DistroChannelSync.read(parsed.fieldsRaw)", "DistroCodec.seenKey(sourceHex: srcHex, timestamp: parsed.timestamp)")
            && before(unwrap, "DistroChannelSync.read(parsed.fieldsRaw)", "parsed.is_delivery_notification")
            && before(unwrap, "DistroChannelSync.read(parsed.fieldsRaw)", "parsed.distro_transfer_key"),
          "before the generic dedupe, the transfer test and the delivery-notification test, which C also passes")
    // Its own repeat key, and a dropped one is judged again.
    check(unwrap.contains("DistroChannelSync.repeatKey(sourceHex: srcHex, timestamp: parsed.timestamp, marker: marker)")
            && unwrap.contains("if held { blobQueue.async { seen.record(key) } }"),
          "its own repeat key, recorded only when held")
    // Rules 1 and 2: the source is D, and the signature is D's.
    check(unwrap.contains("let fromDistro = !distroHex.isEmpty && srcHex == distroHex")
            && unwrap.contains("signedByDistro: fromDistro && (parsed.signature_validated ?? false)"),
          "rules 1 and 2: the source is the distro, and its signature is the distro's")
    check(distroClient.contains("case .channelSync(let c):\n            guard let onChannelSync else {\n                print(\"[Distro] no channel-sync sink; not recorded\")\n                return false"),
          "with no sink it is not recorded")
    check(app.contains("RfedDistroClient.shared.onChannelSync = {")
            && app.contains("channelClient?.handleDistroChannelSync(marker: marker, fromDistro: fromDistro, signedByDistro: signedByDistro) ?? false"),
          "the app routes it to the channel client")
}

func theSentCopyIsOwedNotHandedToTheRouterOnce() {
    let owe = body(repository, "nonisolated private static func oweDistroSentCopy(", "/// Create an outbound DM whose source is the distro")
    check(owe.contains("DistroOutboxRuntime.shared.oweSentCopy(recipient: recipient, title: title, content: content)"),
          "the copy is owed")
    check(repository.contains("if DistroCodec.needsSentCopy(sentAsDistro: sentAsDistro, destHex: destHashHex,")
            && repository.contains("Self.oweDistroSentCopy(recipient: destData, title: \"\", content: content)"),
          "only a message sent as the distro, to someone else, has a copy")
    // It no longer goes through the router, whose own re-send is paced by a timer and gives up after a count.
    check(!owe.contains("sendViaAppLinks") && !owe.contains("messageCreate"), "it does not go through the router")
    check(!repository.contains("distroSentCopies") && !repository.contains("Self.sendDistroSentCopy("),
          "no router handle or state is kept for it")
}

func anOwedMessageIsSignedByTheKeyItsSourceNames() {
    // The distro and the handle that signs as it are read together (DistroManager.signing), so a
    // generate, import or forget between two reads cannot give a source that the key does not match.
    let channel = body(runtime, "func oweChannelSync(", "func oweSentCopy(")
    let sent = body(runtime, "func oweSentCopy(", "private func fail(")
    for (name, text) in [("C", channel), ("sent copy", sent)] {
        check(count(text, "DistroManager.shared.signing()") == 1, "\(name): one atomic read of the distro and its handle")
        check(!text.contains("DistroManager.shared.handle") && !text.contains("DistroManager.shared.info()")
                && !text.contains("DistroManager.shared.sendingIdentity"), "\(name): no second read")
    }
    let pack = body(runtime, "private static func pack(", "}.value\n    }")
    check(pack.contains("identityHandle: signer") && !pack.contains("DistroManager"), "the message is made with the handle it was read with")
    let signing = body(read("Retichat/Services/DistroManager.swift"), "func signing()", "/// The private key as hex.")
    check(signing.contains("stateLock.lock(); defer { stateLock.unlock() }") && signing.contains("return (DistroInfo("),
          "DistroManager.signing reads both under one lock")
}

func theRuntimeStartsNoLinkAndOnlyALinksComingUpFlushes() {
    let source = code(runtime)
    // It never opens, reopens or closes the propagation link, nor sets the router's node.
    for call in ["appLinkOpen", "openHeldAppLink", "closeAppLink", "appLinkReopen", "setPropagationNode", "rotateToNext", "sync(nodeHash"] {
        check(!source.contains(call), "the runtime does not call \(call)")
    }
    // onLinkEstablished: the link callback's ACTIVE event and the check at start, nothing else.
    check(count(source, "onLinkEstablished(") == 2, "onLinkEstablished is called from two places")
    // onLinkRecovered: the link callback's RECOVERED event (a STALE link that heard the node again),
    // from the runtime alone; no clock and no poll of the link, and nothing else in the app calls it.
    check(count(source, "onLinkRecovered(") == 1, "onLinkRecovered is called from one place")
    for path in ["Retichat/Services/ChatRepository.swift",
                 "Retichat/Services/RfedChannelClient.swift", "Retichat/Services/RfedDistroClient.swift",
                 "Retichat/Services/ConnectionStateManager.swift", "Retichat/RetichatApp.swift"] {
        check(count(code(read(path)), "onLinkRecovered(") == 0, "\(path) never calls onLinkRecovered")
    }
    // Its one clock is the §1 watch, which only logs.
    check(count(source, "Task.sleep") == 1, "one sleep")
    let watch = body(runtime, "Task.detached(priority: .utility) {\n                try? await Task.sleep", "return UploadLeft(")
    check(watch.contains("print(\"[DistroOutbox] §1 VIOLATION") && !watch.contains("onLost") && !watch.contains("sink."),
          "the §1 watch only logs")
    // The node is the RFed node's own lxmf.propagation or the Settings override, set at start.
    check(runtime.contains("UserPreferences.shared.effectiveLxmfPropagationHash")
            && before(runtime, "refreshNode()", "PropagationLinkTarget.set(node: port.node(), outbox: outbox)"),
          "the node is the one the distro's messages are fanned out from")
    // On a background launch before the first unlock the Keychain cannot be read, and "no distro" is no
    // finding: the outbox starts only once the device knows what it holds, and drops nothing before.
    check(runtime.contains("guard DistroManager.shared.isSettled else {")
            && runtime.contains("RfedDistroClient.shared.$distroSettled.sink")
            && runtime.contains("distroKnown: { DistroManager.shared.isSettled }"),
          "the outbox starts once the distro is known, and drops nothing on a distro it cannot see")
    check(read("Retichat/Services/DistroOutbox.swift").contains("guard distroKnown() else {"),
          "and the drop itself refuses to run on a distro that is not known")
    // Start and stop run in the order asked, and a start that finds a stop after it registers nothing.
    check(runtime.contains("guard mine == generation else { return }") && count(source, "chain {") == 2,
          "start and stop are serialized, and a stopped start registers nothing")
}

func aStaleLinksRecoveryIsTheRecoveredEventForTheNodesLinkOnly() {
    let deliver = body(runtime, "static func deliver(dest: Data, status: UInt8, linkId: Data?) {", "// MARK: - The runtime")
    // The same guards for both events: only the propagation node's link, and only with the link's id.
    check(deliver.contains("guard let current, dest.hexString == current.node, let linkId, !linkId.isEmpty else { return }"),
          "only the node's link, carrying its id")
    // An establishment is ACTIVE; a STALE link's recovery is RECOVERED. Each is its own coming-up, on the outbox's executor.
    check(deliver.contains("if status == RetichatBridge.appLinkActive {")
            && deliver.contains("current.outbox.spawn { await current.outbox.onLinkEstablished(id) }"),
          "an ACTIVE event is a coming-up by establishment")
    check(deliver.contains("else if status == RetichatBridge.appLinkRecovered {")
            && deliver.contains("current.outbox.spawn { await current.outbox.onLinkRecovered(id) }"),
          "a RECOVERED event is a coming-up by recovery")
    check(before(deliver, "onLinkEstablished(id)", "onLinkRecovered(id)") && !deliver.contains("Task.sleep"),
          "nothing in it waits")
    // The status is AppLinks' own code 5 (a glue-crate test pins it to app-links' constant), and the docs list it.
    check(bridge.contains("nonisolated static let appLinkRecovered: UInt8 = 5"), "RetichatBridge.appLinkRecovered is 5")
    check(header.contains("5 recovered") && rust.contains("4 disconnected, 5 recovered"),
          "the header and the glue crate list the status")
    check(bridge.contains("its RECOVERED event"), "the wrapper's docs say what the event is")
}

/// James, 2026-10-06 (DESIGN_PRINCIPLES §3, what a device owes its distro): an owed upload that never
/// left the device goes when an interface comes back online, as well as at the next coming-up. The
/// event is the Reticulum interface's own up-edge (Transport::set_interface_online), never the
/// system's "the network is available", and the runtime hands it to the outbox from one place.
func anInterfaceComingBackIsTheStacksOwnUpEdgeHandedToTheOutboxFromOnePlace() {
    let source = code(runtime)
    check(count(source, "onInterfaceUp(") == 1, "onInterfaceUp is called from one place in the runtime")
    for path in ["Retichat/Services/ChatRepository.swift", "Retichat/Services/RfedChannelClient.swift",
                 "Retichat/Services/RfedDistroClient.swift", "Retichat/Services/ConnectionStateManager.swift",
                 "Retichat/RetichatApp.swift", "Retichat/Services/DistroOutbox.swift"] {
        check(count(code(read(path)), ".onInterfaceUp(") == 0, "\(path) never calls onInterfaceUp on the outbox")
    }
    let deliver = body(runtime, "static func deliverInterfaceUp(name: String) {", "// MARK: - The runtime")
    check(deliver.contains("current.outbox.spawn { await current.outbox.onInterfaceUp(name) }") && !deliver.contains("Task.sleep"),
          "an up-edge is handed to the outbox's own executor, and nothing waits")
    // Not the system's reachability, and no link of its own.
    for text in ["NWPathMonitor", "SCNetworkReachability", "Reachability", "NetworkMonitor"] {
        check(!source.contains(text), "the runtime does not listen to \(text)")
    }
    // Registered at start with the link events, cleared at stop with them; the stack's listener is added once.
    let listen = body(runtime, "private func listen(", "/// The stack is stopping")
    check(listen.contains("bridge.interfaceUpRegister(handler: { name in PropagationLinkTarget.deliverInterfaceUp(name: name) })")
            && before(listen, "propagationLinkEventsRegister", "interfaceUpRegister"),
          "start registers the interface up-edge after the link events")
    let stop = body(runtime, "func stop() {", "// MARK: What the user's actions owe")
    check(stop.contains("bridge.interfaceUpClear()") && stop.contains("interfaceUpRegistered = false"),
          "stop clears it, so a start registers it again")
    check(count(code(rust), "Transport::add_interface_up_listener(") == 1, "the glue adds one listener for the process")
    check(rust.contains("INTERFACE_UP_HOOKED.call_once("), "once, whatever the number of starts")
    // The outbox reads only the port's answer for "never left": nothing else decides it.
    let outbox = code(read("Retichat/Services/DistroOutbox.swift"))
    check(count(outbox, "return .neverLeft") == 1, "one never-left decision, the port's nil with the link up")
}

func theChannelScreenClosesWhenASiblingLeaves() {
    let content = read("Retichat/Views/Navigation/ContentView.swift")
    check(content.contains(".onChange(of: channelClient.channels.map(\\.id)) { _, ids in\n            if let current = selectedChannel, !ids.contains(current.id) {\n                selectedChannel = nil"),
          "an open channel that leaves the list closes, and asks nothing")
}

// MARK: - Posting: the identity, own posts, dedupe

func aPostIsPackedWithThePostingIdentityAndRecordedUnderItsHash() {
    let identity = body(channelClient, "private func postingIdentity()", "private func sendMessageAsync(")
    check(identity.contains("DistroManager.shared.sendingIdentity(deviceHash: device, deviceHandle: identityHandle)"),
          "the posting identity is the distro when one is held, else the device")
    let send = body(channelClient, "private func sendMessageAsync(", "/// Mark the optimistic entity")
    check(send.contains("let (postingHex, postingHandle) = postingIdentity()")
            && before(send, "let (postingHex, postingHandle) = postingIdentity()", "optimisticEntity = ChannelMessageEntity(")
            && count(send, "postingIdentity()") == 1,
          "decided once, before the optimistic row")
    check(send.contains("senderHash: postingHex,") && !send.contains("senderHash: ownHashHex"),
          "the optimistic post is the posting identity's")
    let trySend = body(channelClient, "private func trySend(", "// MARK: - Pull deferred blobs")
    check(trySend.contains("senderIdentityHandle: postingHandle,"), "a post is packed with the posting identity")
    check(trySend.contains("(Data(hexString: postingHex) ?? Data()).hexString\n            + String(format: \"%016llx\", tsMs)"),
          "its id is the posting source and its timestamp: the echo is dropped against it")
    check(trySend.contains("temp.senderHash = postingHex") && trySend.contains("recordPostName(postName, channelHashHex: channel.id, postingHex: postingHex)"),
          "the row and the name state are the posting identity's")
    check(!trySend.contains("ownHashHex") && !trySend.contains("senderIdentityHandle: identityHandle"),
          "the device's own hash is no longer what a post is filed under")
}

func subscribingTheStreamPullsAndPushStayTheDevices() {
    // RFed keys a subscription, a bound link, a deferred bucket and a wake by subscriber hash: under
    // the distro the devices would steal each other's posts.
    let spans: [(String, String, String)] = [
        ("subscribe", "private func subscribeOnServer(", "/// Parse the subscribe response"),
        ("pull", "func pullDeferred(channel: Channel) async -> Bool {", "// MARK: - Live channel stream receive"),
        ("stream", "private func buildChannelStreamPayload(", "nonisolated private static func channelStreamResponseOk("),
        ("unsubscribe", "private func leaveHere(", "// MARK: - Channels and the distro"),
        ("push on", "func enableChannelPush(", "/// Disable push wakeups for a channel"),
        ("push off", "func disableChannelPush(", "// MARK: - Send"),
        ("resubscribe", "private func resubscribePersistedChannels()", "private func reconfigureChannelStreams()"),
    ]
    for (name, from, to) in spans {
        let text = body(channelClient, from, to)
        check(!text.contains("postingHandle") && !text.contains("postingIdentity()") && !text.contains("sendingIdentity")
                && !text.contains("DistroManager.shared.handle"), "\(name) is the device's, not the distro's")
    }
    check(body(channelClient, "private func subscribeOnServer(", "/// Parse the subscribe response").contains("bridge.identityPublicKey(handle: identityHandle)"),
          "subscribing signs with the device's identity")
    check(body(channelClient, "private func leaveHere(", "// MARK: - Channels and the distro").contains("identityHandle: identityHandle"),
          "the push registration is removed with the device's identity")
}

func aReceivedPostIsOwnByTheSharedRuleAndOwnPostsAreNeverNotifiedOrCountedAsSenders() {
    let dispatch = body(channelClient, "private func dispatchVerifiedLxmf(", "private func appendMessage(")
    check(dispatch.contains("DistroCodec.isOwnChannelPost(sourceHex: senderHashHex, deviceHex: ownHashHex, distroHex: distroHex)"),
          "own is the device's hash or the held distro's")
    check(dispatch.contains("if !isOutgoing {\n            noteSender("), "an own post is never counted as a sender seen in the channel")
    check(dispatch.contains("let deliveryState = Self.verifiedChannelMessageDeliveryState(isOutgoing: isOutgoing)")
            && channelClient.contains("isOutgoing ? DeliveryState.sent : DeliveryState.delivered"),
          "an own post stored from RFed is SENT, never DELIVERED, never sending or failed")
    check(dispatch.contains("if notify, !isOutgoing,"), "an own post is never notified")
    // Dedupe by (source, timestamp), persisted: the id is both, held with every stored post, checked before anything is stored.
    check(dispatch.contains("let msgId = senderHashHex + String(format: \"%016llx\", tsMs)")
            && before(dispatch, "guard !existingForChannel else {", "modelContext?.insert(entity)"),
          "a post whose (source, timestamp) is held is dropped before it is stored")
    check(channelClient.contains("let entities = (try? ctx.fetch(FetchDescriptor<ChannelMessageEntity>())) ?? []\n        var grouped"),
          "every stored post is loaded at start, so the dedupe holds after a restart")
    // Its name teaches the state only from the posting identity.
    check(dispatch.contains("if isOutgoing && senderHashHex.lowercased() == postingHex.lowercased() {"),
          "what the distro's posts teach is from the posting identity only")
}

// MARK: - The C surface the outbox stands on (the JNI contract of Android)

func everyCFunctionTheSwiftWrapperCallsIsDeclaredAndExported() {
    let functions = ["retichat_message_set_distro_channel_sync", "retichat_message_pack",
                     "retichat_propagation_build_upload", "retichat_propagation_link",
                     "retichat_propagation_upload", "retichat_propagation_link_events_register",
                     "retichat_interface_up_register", "retichat_interface_up_clear",
                     "retichat_group_unpack_packed", "retichat_message_set_retichat_statuses",
                     "retichat_distro_seal", "retichat_propagation_build_sealed_upload",
                     "retichat_interface_up_mark", "retichat_interface_came_up_since"]
    let wrapper = code(bridge)
    for name in functions {
        check(header.contains("\(name)("), "\(name) is declared in the header")
        check(rust.contains("pub extern \"C\" fn \(name)("), "\(name) is exported by the glue crate")
        check(count(wrapper, "\(name)(") == 1, "\(name) is called once, by its wrapper")
    }
}

func theCallbacksTheLibraryCallsAreTheSignaturesSwiftDeclares() {
    let flat = header.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    check(flat.contains("typedef void (*retichat_upload_event_t)(void *context, int32_t event);"), "the event typedef")
    check(flat.contains("typedef void (*retichat_upload_release_t)(void *context);"), "the release typedef")
    check(bridge.contains("nonisolated func propagationUploadEvent(context: UnsafeMutableRawPointer?, event: Int32)"),
          "the event trampoline takes what the typedef says")
    check(bridge.contains("nonisolated func propagationUploadRelease(context: UnsafeMutableRawPointer?)"),
          "the release trampoline too")
    check(flat.contains("typedef void (*retichat_interface_up_t)(void *context, const uint8_t *name, uint32_t name_len);"),
          "the interface up-edge typedef")
    check(bridge.contains("nonisolated func interfaceUpEvent(context: UnsafeMutableRawPointer?, name: UnsafePointer<UInt8>?, nameLen: UInt32)"),
          "and its trampoline takes what the typedef says")
    check(bridge.contains("""
        nonisolated func propagationLinkEvent(
            context: UnsafeMutableRawPointer?,
            dest: UnsafePointer<UInt8>?, destLen: UInt32,
            status: UInt8,
            linkId: UnsafePointer<UInt8>?, linkIdLen: UInt32
        )
        """), "and the link event trampoline")
    // The library owns the sink's retain from the call on and releases it once; Swift never releases it itself.
    let upload = body(bridge, "nonisolated func propagationUpload(", "/// Register `handler` for every app-link status change")
    check(count(upload, "Unmanaged.passRetained(") == 1 && !upload.contains(".release()")
            && upload.contains("propagationUploadEvent, propagationUploadRelease, context, &outLen"),
          "the sink's retain goes to the library, which releases it")
    check(count(bridge, "Unmanaged<PropagationUploadSinkBox>.fromOpaque(context).release()") == 1, "released in one place")
}

func anUploadOnlyLeavesOnTheLinkTheStackHoldsAndNothingIsResentByTheCrate() {
    let upload = body(rust, "pub extern \"C\" fn retichat_propagation_upload(", "type LinkEventCallback")
    // The one send is AppLinks::send_on_held_link_owed (2026-10-10, Stage 0): no race, no tiers,
    // no second try, and a Resource whose first advertisement no interface carried is told as
    // never-left, not lost.
    check(count(upload, "send_on_held_link") == 1
            && upload.contains("AppLinks::send_on_held_link_owed(&node, data, true, on_delivered, on_failed, Some(watch.on_progress()), on_never_left)"),
          "one send, on the held link, with the Resource's progress watched and its never-left told")
    check(!upload.contains("thread::sleep") && !upload.contains("thread::spawn"), "no clock and no thread of its own")
    // A loss tears down the link the upload went on, then says so.
    check(before(upload, "tear_down_link_of_upload(&lost_node, &link)", "lost_report.lost()"),
          "a loss tears the link down before it is reported")
    // Never left: nothing was sent, the link did nothing wrong. No teardown.
    let neverLeft = body(upload, "let on_never_left:", "});")
    check(neverLeft.contains("never_left_report.never_left();") && !neverLeft.contains("tear_down"),
          "a never-left upload is told, and its link kept")
    // Made first, so that every way out releases the context.
    check(before(upload, "let report = Arc::new(UploadReport::new(event, release, context));", "let node = slice_from_raw(node, node_len);"),
          "the context is the library's before anything can fail")
}

/// DESIGN_PRINCIPLES §1, bulk transfers (James, 2026-10-10, "Panic at the end"): the watch's
/// `finish` is the last call of whichever outcome concludes the upload, once the host has been
/// told, and of a send that returned an error; the progress callback only feeds it.
func theResourceWatchIsFinishedLastByEveryOutcomeAndDecidesNothing() {
    let upload = body(rust, "pub extern \"C\" fn retichat_propagation_upload(", "type LinkEventCallback")
    check(upload.contains("let watch = ResourceSilenceWatch::new("), "one watch per upload")
    for (name, from, told, finish) in [
        ("proved", "let on_delivered:", "proved_report.proved();", "proved_watch.finish();"),
        ("lost", "let on_failed:", "lost_report.lost();", "lost_watch.finish();"),
        ("never left", "let on_never_left:", "never_left_report.never_left();", "never_left_watch.finish();"),
    ] {
        let outcome = body(upload, from, "});")
        let lines = outcome.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }
        check(lines.last == finish, "\(name): finish is the last call")
        check(before(outcome, told, finish), "\(name): after the host is told")
        check(count(outcome, ".finish()") == 1, "\(name): once")
    }
    check(before(body(upload, "let on_delivered:", "});"), "proved_watch.delivered();", "proved_report.proved();"),
          "the proof marks the watch delivered first")
    let err = body(upload, "Err(e) => {", "emit_error(out_len, e)")
    check(err.contains("watch.finish();"), "a send that returned an error finishes the watch")
    check(count(upload, ".finish()") == 4, "and nothing else finishes it")
    check(!upload.contains("watch.decid") && !upload.contains("watch.on_progress()(") ,
          "the watch is fed, never asked to decide")
}

/// The distro sync proof (RFed SPEC §17.13; DISTRO-SYNC-PROOF-DESIGN.md §5.1, §5.4, §12.16): each
/// owed message is sealed once, by the distro handle it was packed with, in the write that owes
/// it; the build sends the proof only to the configured RFed's own lxmf.propagation.
func anOwedMessageIsSealedOnceAndItsProofGoesOnlyToTheRfedsOwnNode() {
    let pack = body(runtime, "private static func pack(", "}.value\n    }")
    check(count(pack, "bridge.distroSeal(distroHandle: signer, packed: packed)") == 1,
          "sealed once, with the handle that packed it, from the packed bytes")
    check(before(pack, "bridge.messagePack(handle: handle)", "bridge.distroSeal("), "after packing")
    check(pack.contains("print(\"[DistroOutbox] ERROR: \\(label) could not be sealed"),
          "a seal that fails is said as an error and the message still owed")
    check(count(code(runtime), "distroSeal(") == 1, "nothing else seals")
    for (name, from, to) in [("C", "func oweChannelSync(", "func oweSentCopy("), ("sent copy", "func oweSentCopy(", "private func fail(")] {
        let owe = body(runtime, from, to)
        check(owe.contains("guard let (packed, hash, sealed) = await Self.pack(")
                && owe.contains("sealed: sealed?.sealed, syncSig: sealed?.syncSig))"),
              "\(name): both kinds are owed with their seal, in the one owe")
    }
    let build = body(runtime, "nonisolated(nonsending) func build(_ entry: OwedEntry)", "func upEdgeMark()")
    check(build.contains("let how = UploadBuild.of(entry, node: node, rfedDerived: rfedDerived)"), "the build asks the gate")
    check(build.contains("withClaim: withClaim, node: node)") && count(build, "propagationBuildSealedUpload(") == 1
            && count(build, "propagationBuildUpload(") == 1,
          "the claim goes only as the gate says; an unsealed entry goes the legacy way")
    check(runtime.contains("rfedDerived: hash16(UserPreferences.shared.rfedDerivedLxmfPropagationHash)"),
          "the RFed's own node is derived from its identity, never the override")
    check(read("Retichat/Services/UserPreferences.swift").contains("var rfedDerivedLxmfPropagationHash: String {"),
          "UserPreferences derives it")
    // The proof is kept with the entry: the store maps it both ways, the model holds it.
    let rows = body(read("Retichat/Services/DistroChannelStores.swift"), "nonisolated enum DistroOutboxRows {", "/// The distro outbox's storage")
    check(count(rows, "sealed: entry.sealed, syncSig: entry.syncSig") == 1
            && rows.contains("row.sealed = entry.sealed") && rows.contains("row.syncSig = entry.syncSig")
            && rows.contains("sealed: row.sealed, syncSig: row.syncSig"),
          "the rows keep and give back the seal and the proof")
    let model = body(read("Retichat/Models/Models.swift"), "final class DistroOutboxEntity {", "init(")
    check(model.contains("var sealed: Data?") && model.contains("var syncSig: Data?"),
          "optional attributes: an old store opens by lightweight migration")
    // The stack's never-left reaches the outbox; the watch notes it decided.
    check(bridge.contains("case 3: box.sink.neverLeft()"), "event 3 is never-left")
    let watched = body(runtime, "nonisolated private final class WatchedSink", "\n}\n")
    check(watched.contains("func neverLeft() { mark(); inner.neverLeft() }"), "the §1 watch notes a never-left as decided")
    check(runtime.contains("func upEdgeMark() -> UInt64 { bridge.interfaceUpMark() }")
            && runtime.contains("func cameUpSince(_ mark: UInt64) -> Bool { bridge.interfaceCameUpSince(mark) }"),
          "the mark is Transport's up-edge count")
}

/// What rfed pushed down a dead link waits for /rfed/pull: an accepted
/// propagation.stream open pulls it once, as the web and Android do (staging,
/// 2026-10-06).
func anAcceptedStreamOpenPullsWhatRfedHeldBack() {
    let open = body(repository, "private func sendPropagationStreamOpen()", "private static func streamOpenResponseOk")
    check(open.contains("await RfedDistroClient.shared.pull()"), "an accepted open pulls the distro's deferred queue")
    check(before(open, "guard Self.streamOpenResponseOk(response) else", "await RfedDistroClient.shared.pull()"),
          "the pull comes only after the open is accepted")
}

let allTests: [(String, () -> Void)] = [
    ("an accepted stream open pulls what rfed held back", anAcceptedStreamOpenPullsWhatRfedHeldBack),
    ("the stack starts the outbox after the links are wired and stops it first", theStackStartsTheOutboxAfterTheLinksAreWiredAndStopsItFirst),
    ("only the user's own join, leave and send owe anything", onlyTheUsersOwnJoinLeaveAndSendOweAnything),
    ("the user's own action is the only caller of recordUsersAction", theUsersOwnActionIsTheOnlyCallerOfRecordUsersAction),
    ("applying a sibling's change sends nothing and subscribes with the device's key", applyingASiblingsChangeSendsNothingAndSubscribesWithTheDevicesKey),
    ("a membership message is read before the generic dedupe and the delivery-notification test", aMembershipMessageIsReadBeforeTheGenericDedupeAndTheDeliveryNotificationTest),
    ("the sent copy is owed, not handed to the router once", theSentCopyIsOwedNotHandedToTheRouterOnce),
    ("an owed message is signed by the key its source names", anOwedMessageIsSignedByTheKeyItsSourceNames),
    ("the runtime starts no link and only a link's coming-up flushes", theRuntimeStartsNoLinkAndOnlyALinksComingUpFlushes),
    ("a STALE link's recovery is the recovered event for the node's link only", aStaleLinksRecoveryIsTheRecoveredEventForTheNodesLinkOnly),
    ("an interface coming back is the stack's own up-edge, handed to the outbox from one place", anInterfaceComingBackIsTheStacksOwnUpEdgeHandedToTheOutboxFromOnePlace),
    ("the channel screen closes when a sibling leaves", theChannelScreenClosesWhenASiblingLeaves),
    ("a post is packed with the posting identity and recorded under its hash", aPostIsPackedWithThePostingIdentityAndRecordedUnderItsHash),
    ("subscribing, the stream, pulls and push stay the device's", subscribingTheStreamPullsAndPushStayTheDevices),
    ("a received post is own by the shared rule; own posts are never notified or counted as senders", aReceivedPostIsOwnByTheSharedRuleAndOwnPostsAreNeverNotifiedOrCountedAsSenders),
    ("every C function the Swift wrapper calls is declared and exported", everyCFunctionTheSwiftWrapperCallsIsDeclaredAndExported),
    ("the callbacks the library calls are the signatures Swift declares", theCallbacksTheLibraryCallsAreTheSignaturesSwiftDeclares),
    ("an upload only leaves on the link the stack holds and nothing is resent by the crate", anUploadOnlyLeavesOnTheLinkTheStackHoldsAndNothingIsResentByTheCrate),
    ("the Resource watch is finished last by every outcome and decides nothing", theResourceWatchIsFinishedLastByEveryOutcomeAndDecidesNothing),
    ("an owed message is sealed once and its proof goes only to the RFed's own node", anOwedMessageIsSealedOnceAndItsProofGoesOnlyToTheRfedsOwnNode),
]

@main
enum DistroOutboxWiringTests {
    static func main() {
        for (name, run) in [("the sources are readable", {
            for (path, text) in [("DistroOutboxRuntime", runtime), ("RfedChannelClient", channelClient), ("RfedDistroClient", distroClient),
                                 ("ChatRepository", repository), ("RetichatBridge", bridge), ("CRetichatFFI.h", header),
                                 ("retichat-ffi lib.rs", rust), ("RetichatApp", app)] {
                check(!text.isEmpty, "\(path) is readable from the tests")
            }
        })] + allTests {
            currentTest = name
            let before = failures.count
            run()
            print(failures.count == before ? "ok    - \(name)" : "FAIL  - \(name)")
        }
        print("\n\(allTests.count + 1) tests, \(checks) checks, \(failures.count) failure(s)")
        exit(failures.isEmpty ? 0 : 1)
    }
}
