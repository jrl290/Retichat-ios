import UserNotifications
import Intents
import UIKit
import Security

// MARK: - Hex helper

private extension Data {
    init?(hexString: String) {
        let hex = hexString.replacingOccurrences(of: " ", with: "")
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}

// MARK: - Delivery synchronization
//
// The Rust delivery callback fires on a background thread.  It stores every
// message in the App Group as it arrives (PendingNotification.NSERun).  The
// sync-complete callback signals the semaphore: the router raises it only
// after the run's last delivery, so the main NSE thread then has them all.
//
// This state is static, so two requests iOS runs at once in one process
// share it, and the second reset() replaces the first's run (older than
// U2; left for H5). The hand-off file's lock is per process, so both
// runs' writes are kept.

private enum NSEDelivery {
    static var run = newRun()
    static var semaphore = DispatchSemaphore(value: 0)
    static var syncComplete = false   // prop sync finished (0 or N messages)
    static func reset() {
        run = newRun()
        syncComplete = false
        // Replace semaphore to drain any stale signals from prior runs
        semaphore = DispatchSemaphore(value: 0)
    }
    /// The only place a run is built: every delivery goes through
    /// nseHandOffForm, which keeps a distro transfer's private key out of
    /// the container file and drops sent copies.
    private static func newRun() -> PendingNotification.NSERun {
        PendingNotification.NSERun(prepare: nseHandOffForm)
    }
}

/// The form a delivered message is stored in for the app, or nil when it is
/// not stored.
private func nseHandOffForm(_ msg: PendingNotification.NSEMessage) -> PendingNotification.NSEMessage? {
    let fields = LxmfFieldsDecoder.decode(Data(base64Encoded: msg.fieldsRawBase64) ?? Data())
    if fields.isDistroSentCopy {
        // RFed SPEC §17.11: a distro sent copy is the user's own message,
        // and is filed only from distro fan-out (RfedDistroClient). One
        // reaching this device's address is not stored and not shown —
        // never an incoming bubble or a notification.
        NSLog("[NSE] distro sent-copy marker from %@ outside fan-out — dropped",
              String(msg.senderHash.prefix(8)))
        return nil
    }
    // A distro identity transfer carries the distro private key in field
    // 0xFC: move it to the Keychain first and persist the message without
    // its fields, so the key never sits in the container file
    // (PendingNotification.stashDistroTransferKey).
    guard let key = fields.distroTransferKey else { return msg }
    let status = PendingNotification.stashDistroTransferKey(key, messageHash: msg.messageHash)
    if status == errSecSuccess {
        return msg.strippedForDistroTransfer(.keychain)
    }
    // Dropped, not written to disk: the app reports it so the user can
    // send it again from the other device.
    NSLog("[NSE] distro transfer key not stored (Keychain %d); dropped", status)
    return msg.strippedForDistroTransfer(.lost)
}

// MARK: - C callback trampoline

private func nseDeliveryTrampoline(
    context: UnsafeMutableRawPointer?,
    hash: UnsafePointer<UInt8>?, hashLen: UInt32,
    srcHash: UnsafePointer<UInt8>?, srcLen: UInt32,
    destHash: UnsafePointer<UInt8>?, destLen: UInt32,
    title: UnsafePointer<CChar>?,
    content: UnsafePointer<CChar>?,
    timestamp: Double,
    signatureValid: Int32,
    unverifiedReason: Int32,
    fieldsRaw: UnsafePointer<UInt8>?, fieldsLen: UInt32
) {
    let msgHash  = hash.map     { Data(bytes: $0, count: Int(hashLen)) }  ?? Data()
    let src      = srcHash.map  { Data(bytes: $0, count: Int(srcLen)) }   ?? Data()
    let dest     = destHash.map { Data(bytes: $0, count: Int(destLen)) }  ?? Data()
    let fields   = fieldsRaw.map { Data(bytes: $0, count: Int(fieldsLen)) } ?? Data()
    let titleStr   = title.map   { String(cString: $0) } ?? ""
    let contentStr = content.map { String(cString: $0) } ?? ""
    let srcHex = src.map { String(format: "%02x", $0) }.joined()

    NSLog("[NSE-CB] message: sender=%@ content_len=%d", String(srcHex.prefix(8)), contentStr.count)

    // Every delivery is written to the hand-off before this returns, and so
    // before the router acknowledges it to the propagation node (U2). A
    // failed write is logged and counted, and not shown.
    NSEDelivery.run.deliver(PendingNotification.NSEMessage(
        messageHash:     msgHash.map { String(format: "%02x", $0) }.joined(),
        senderHash:      srcHex,
        destHash:        dest.map { String(format: "%02x", $0) }.joined(),
        title:           titleStr,
        content:         contentStr,
        timestamp:       timestamp,
        signatureValid:  signatureValid != 0,
        fieldsRawBase64: fields.base64EncodedString(),
        unverifiedReason: Int(unverifiedReason)
    ))
}

// MARK: - C callback trampoline for sync-complete

private func nseSyncCompleteTrampoline(
    context: UnsafeMutableRawPointer?,
    messageCount: UInt32
) {
    NSLog("[NSE-CB] sync complete, %d messages", messageCount)
    NSEDelivery.syncComplete = true
    NSEDelivery.semaphore.signal()
}

// MARK: - Avatar image generation
//
// Matches the AvatarView logic in GlassComponents.swift (main app).
// Uses a deterministic hash so colors are consistent across process boundaries.

private func avatarColorHue(for name: String) -> CGFloat {
    var hash = 5381
    for scalar in name.unicodeScalars {
        hash = (hash &* 33) &+ Int(scalar.value)
    }
    return CGFloat(abs(hash) % 360) / 360.0
}

private func makeAvatarImage(name: String, size: CGFloat = 60) -> UIImage? {
    let hue = avatarColorHue(for: name)
    let baseColor = UIColor(hue: hue, saturation: 0.5, brightness: 0.7, alpha: 1.0)

    let parts = name.split(separator: " ")
    let initials: String
    if parts.count >= 2 {
        initials = (String(parts[0].prefix(1)) + String(parts[1].prefix(1))).uppercased()
    } else {
        initials = String(name.prefix(2)).uppercased()
    }

    let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
    return renderer.image { _ in
        let rect = CGRect(x: 0, y: 0, width: size, height: size)

        // Filled circle
        baseColor.withAlphaComponent(0.3).setFill()
        UIBezierPath(ovalIn: rect).fill()

        // Stroke circle
        let strokePath = UIBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        baseColor.withAlphaComponent(0.5).setStroke()
        strokePath.lineWidth = 1.0
        strokePath.stroke()

        // Initials
        let fontSize = size * 0.35
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: baseColor
        ]
        let str = NSAttributedString(string: initials, attributes: attrs)
        let strSize = str.size()
        let strRect = CGRect(
            x: (size - strSize.width) / 2,
            y: (size - strSize.height) / 2,
            width: strSize.width,
            height: strSize.height
        )
        str.draw(in: strRect)
    }
}

// MARK: - Notification Service Extension

/// Intercepts APNs pushes with `mutable-content: 1`.
///
/// 1. Start a lightweight Reticulum stack using shared App Group config.
/// 2. Connect to interfaces, sync from the propagation node.
/// 3. Store every delivered message in the App Group for main-app import,
///    as each one arrives.
/// 4. Wait for the sync-complete callback, when a sync started (semaphore,
///    no polling).
/// 5. Rewrite the notification with the newest message, plus how many more.
class NotificationService: UNNotificationServiceExtension {

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var lxmfClient: LxmfClient?
    private var handlerCalled = false

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent

        guard let best = bestAttemptContent else {
            contentHandler(request.content)
            return
        }

        handlerCalled = false
        NSEDelivery.reset()
        let start = Date()

        guard startStack() else {
            NSLog("[NSE] stack failed to start")
            best.subtitle = "[NSE no-stack]"
            contentHandler(best)
            return
        }
        NSLog("[NSE] stack started: client=%llu", lxmfClient?.handle ?? 0)

        // Give interfaces time to connect (TCP handshake)
        NSLog("[NSE] sleeping 4s for TCP handshake...")
        Thread.sleep(forTimeInterval: 4.0)
        NSLog("[NSE] awake, prop state=0x%02x", lxmfClient?.propagationState ?? -1)

        // Request messages from propagation node
        let syncStarted = requestPropagation()
        NSLog("[NSE] after requestPropagation, prop state=0x%02x", lxmfClient?.propagationState ?? -1)

        // Distro and channel messages wait in RFed's queue, not the
        // propagation node's: pull them while the sync runs. A push for a
        // channel names it (apns-bridge payload rfed.channel) and pulls that
        // channel (NSEChannelPull); any other push pulls the distro
        // (NSEDistroPull). One of the two, so each has the budget.
        let channelHex = (request.content.userInfo["rfed"] as? [String: Any])?["channel"] as? String
        var distro = NSEDistroPull.Result()
        var channelPull = NSEChannelPull.Result()
        if let client = lxmfClient {
            if let channelHex, !channelHex.isEmpty {
                channelPull = NSEChannelPull.run(channelHex: channelHex, identityHandle: client.identityHandle,
                                                 ownHash: client.destHash, deadline: start.addingTimeInterval(20))
                NSLog("[NSE] channel pull %@: unknown=%d pulled=%d shown=%d notify=%d failed=%d",
                      String(channelHex.prefix(8)), channelPull.unknownChannel ? 1 : 0, channelPull.pulled,
                      channelPull.shown.count, channelPull.notify ? 1 : 0, channelPull.failed ? 1 : 0)
                // APNs keeps one pending push per app for an offline device,
                // so this push may stand in for an earlier distro wake: pull
                // the distro too while enough of the budget is left.
                if start.addingTimeInterval(20).timeIntervalSinceNow > 8 {
                    distro = NSEDistroPull.run(identityHandle: client.identityHandle,
                                               deadline: start.addingTimeInterval(20))
                    NSLog("[NSE] distro pull after the channel: noDistro=%d pulled=%d shown=%d failed=%d",
                          distro.noDistro ? 1 : 0, distro.pulled, distro.shown.count, distro.failed ? 1 : 0)
                }
            } else {
                distro = NSEDistroPull.run(identityHandle: client.identityHandle, deadline: start.addingTimeInterval(20))
                NSLog("[NSE] distro pull: noDistro=%d pulled=%d shown=%d failed=%d",
                      distro.noDistro ? 1 : 0, distro.pulled, distro.shown.count, distro.failed ? 1 : 0)
            }
        }

        // Wait for the sync-complete callback — keep ~3s margin before iOS kills at 30s.
        // With no sync started it can never come, so there is nothing to
        // wait for: anything delivered during the sleep has already been
        // through the run.
        var waitResult = DispatchTimeoutResult.timedOut
        if syncStarted {
            let budget = max(27.0 - Date().timeIntervalSince(start), 1.0)
            NSLog("[NSE] waiting %.1fs for callback...", budget)
            waitResult = NSEDelivery.semaphore.wait(timeout: .now() + budget)
        } else {
            NSLog("[NSE] no sync started, so no sync-complete to wait for")
        }
        let elapsed = Int(Date().timeIntervalSince(start))
        let finalState = lxmfClient?.propagationState ?? -1
        let summary = NSEDelivery.run.summary()
        let stored = summary.newest == nil ? 0 : summary.others + 1
        NSLog("[NSE] wait done: syncStarted=%d signaled=%d stored=%d failed=%d dropped=%d syncComplete=%d state=0x%02x elapsed=%ds",
              syncStarted ? 1 : 0,
              waitResult == .success ? 1 : 0,
              stored,
              summary.failed,
              summary.dropped,
              NSEDelivery.syncComplete ? 1 : 0,
              finalState,
              elapsed)

        // The newest message of the run, from the sync, the distro pull or
        // the channel pull, and how many others came with it. `thread` is the
        // conversation it opens (chatId): the sender, or the channel. Every
        // title is named by the app's resolver order (DISPLAY_NAMES.md §5.3):
        // the app's resolved name (chat_names.json), else the message's own
        // accepted 0xD1, else the cached announce name, else the short hash;
        // a channel message as the app names it in its channel notifications
        // (DisplayNames.channelNotificationTitle).
        let chatNames = PendingNotification.readChatNames()
        func contactTitle(_ sender: String, _ name: DisplayNames.NameField, _ reason: Int) -> String {
            DisplayNames.notificationName(
                hash: sender, appName: chatNames[sender], messageName: name, unverifiedReason: reason,
                announceName: NSEDistroPull.hexData(sender).flatMap { lxmfClient?.recallDisplayName(for: $0) })
        }
        var candidates: [(sender: String, content: String, timestamp: Double, hash: String,
                          thread: String, display: String)] = []
        if let m = summary.newest {
            let fields = Data(base64Encoded: m.fieldsRawBase64) ?? Data()
            let reason = m.unverifiedReason ?? (m.signatureValid ? 0 : 2)
            candidates.append((m.senderHash, m.content, m.timestamp, m.messageHash, m.senderHash,
                               contactTitle(m.senderHash, LxmfClient.decodeDisplayName(fieldsRaw: fields), reason)))
        }
        candidates += distro.shown.map {
            ($0.senderHash, $0.content, $0.timestamp, "distro", $0.senderHash,
             contactTitle($0.senderHash, $0.displayName, $0.unverifiedReason))
        }
        let channelNames = PendingNotification.readChannelSenderNames()[channelPull.channelHex] ?? [:]
        for shown in channelPull.shown {
            let label = DisplayNames.channelLabel(
                hash: shown.senderHash,
                channelName: DisplayNames.channelName(afterPost: shown.displayName,
                                                      stored: channelNames[shown.senderHash]),
                contactName: chatNames[shown.senderHash])
            candidates.append((shown.senderHash, shown.content, shown.timestamp, "channel", channelPull.channelHex,
                               DisplayNames.channelNotificationTitle(channelName: channelPull.channelName, label: label)))
        }
        if let msg = candidates.max(by: { $0.timestamp < $1.timestamp }) {
            let others = stored + distro.shown.count + channelPull.shown.count - 1
            let body = others == 0 ? msg.content
                : (msg.content.isEmpty ? "+\(others) more" : msg.content + "\n+\(others) more")
            NSLog("[NSE] delivered after %ds: %d stored, %d from the distro, %d from the channel, %d not stored, showing the newest",
                  elapsed, stored, distro.shown.count, channelPull.shown.count, summary.failed)

            // Never the LXMF title: a subject line the sender chooses, not a
            // name (audit M3).
            let senderName = msg.display
            // --- Explicit APNs push receipt log ---
            NSLog("[NSE] APNs push received and processed: sender=%@ hash=%@", senderName, msg.hash)

            // The newest message, and "+N more" in the body when the run
            // brought others (all of them are already in the App Group for
            // the app's import). The count goes in the body, and in the
            // intent's content below, so it shows whatever the
            // communication-notification rewrite does with the header.
            best.title = senderName
            best.body  = body
            best.subtitle = ""
            best.threadIdentifier = msg.thread
            best.categoryIdentifier = "MESSAGE"
            best.userInfo["chatId"] = msg.thread

            // Wrap with INSendMessageIntent so iOS shows the avatar to the left
            // of the notification (Communication Notification, iOS 15+).
            let updated = attachAvatar(to: best, senderName: senderName, senderHash: msg.thread, content: body)
            finishWithContent(updated)
            return

        } else if summary.failed > 0 {
            // Messages arrived but none could be written for the app (each
            // failure is logged in appendNSEMessage). That is not "0 new":
            // keep the original alert rather than suppress it.
            NSLog("[NSE] %d message(s) not stored — showing generic alert after %ds",
                  summary.failed, elapsed)
            best.subtitle = "[NSE not stored]"

        } else if distro.failed {
            // This device has a distro and its pull did not complete: the
            // push may be for a message still waiting in RFed. Not "0 new".
            NSLog("[NSE] distro pull incomplete — showing generic alert after %ds", elapsed)

        } else if channelPull.silenced {
            // A push for a channel whose Notifications are off: nothing about
            // it is shown, even when its pull or the sync failed.
            NSLog("[NSE] channel %@ is silenced — suppressing after %ds",
                  String(channelPull.channelHex.prefix(8)), elapsed)
            best.title = ""
            best.body  = ""
            best.sound = nil

        } else if channelPull.failed {
            // The channel's pull did not complete: its message may still be
            // waiting in RFed. Not "0 new".
            NSLog("[NSE] channel pull incomplete — showing generic alert after %ds", elapsed)

        } else if summary.dropped > 0 || distro.pulled > 0 || channelPull.pulled > 0 {
            // Only distro sent copies, transfers or receipts, or channel
            // messages that are not to be shown (the channel's Notifications
            // toggle is off, or no signature verified), arrived: nothing to
            // show (the app files them on import).
            NSLog("[NSE] nothing to show among what arrived — suppressing after %ds", elapsed)
            best.title = ""
            best.body  = ""
            best.sound = nil

        } else if NSEDelivery.syncComplete {
            // Prop node had nothing — main app already got it. Suppress.
            NSLog("[NSE] sync complete, 0 new messages — suppressing after %ds", elapsed)
            best.title = ""
            best.body  = ""
            best.sound = nil

        } else {
            // Failed to sync — keep original APNs "New message" fallback
            NSLog("[NSE] sync failed after %ds — showing generic alert", elapsed)
        }

        finishWithContent(best)
    }

    override func serviceExtensionTimeWillExpire() {
        if let best = bestAttemptContent {
            best.subtitle = "[NSE expired]"
            finishWithContent(best)
        }
    }

    /// Call contentHandler exactly once, then tear down.
    private func finishWithContent(_ content: UNNotificationContent) {
        guard !handlerCalled else { return }
        handlerCalled = true
        tearDown()
        contentHandler?(content)
    }

    // MARK: - Reticulum stack

    private func startStack() -> Bool {
        guard let configDir = PendingNotification.nseReticulumDir() else { return false }

        let configFile = configDir + "/config"
        let idFile     = configDir + "/identity"
        guard FileManager.default.fileExists(atPath: configFile),
              FileManager.default.fileExists(atPath: idFile) else {
            NSLog("[NSE] missing config or identity in App Group")
            return false
        }

        let storage = configDir + "/lxmf_storage"
        try? FileManager.default.createDirectory(atPath: storage, withIntermediateDirectories: true)

        let config = LxmfClientConfig(
            configDir: configDir,
            storagePath: storage,
            identityPath: idFile,
            createIdentity: false,
            messageDisplayName: "",
            logLevel: 4,
            stampCost: -1
        )

        do {
            let client = try LxmfClient.start(config: config)
            let idHex = client.identityHashHex
            NSLog("[NSE] identity: %@", idHex)

            client.setDeliveryCallback(nseDeliveryTrampoline)
            client.setSyncCompleteCallback(nseSyncCompleteTrampoline)
            self.lxmfClient = client
            return true
        } catch {
            NSLog("[NSE] start failed: %@", error.localizedDescription)
            return false
        }
    }

    /// Whether a sync started: only then can sync-complete come.
    private func requestPropagation() -> Bool {
        guard let client = lxmfClient else {
            NSLog("[NSE] requestPropagation: no client")
            return false
        }
        let nodes = PendingNotification.readPropagationNodes()
        NSLog("[NSE] propagation nodes: %@", nodes.joined(separator: ", "))

        for hex in nodes {
            guard let data = Data(hexString: hex), data.count == 16 else {
                NSLog("[NSE] skipping invalid node hex: %@", hex)
                continue
            }
            if client.sync(nodeHash: data) {
                NSLog("[NSE] sync started for %@", String(hex.prefix(8)))
                return true
            }
            NSLog("[NSE] sync failed for %@", String(hex.prefix(8)))
        }
        NSLog("[NSE] no propagation nodes succeeded")
        return false
    }

    private func tearDown() {
        lxmfClient?.shutdown()
        lxmfClient = nil
    }

    // MARK: - Communication Notification (avatar to the left)

    /// Wraps the notification content in an INSendMessageIntent so iOS
    /// displays the sender's avatar to the left of the notification banner.
    /// Falls back to `base` unchanged on any failure.
    private func attachAvatar(
        to base: UNMutableNotificationContent,
        senderName: String,
        senderHash: String,
        content: String
    ) -> UNNotificationContent {
        guard #available(iOSApplicationExtension 15.0, *) else { return base }

        guard let avatarImg = makeAvatarImage(name: senderName, size: 120),
              let pngData = avatarImg.pngData() else {
            NSLog("[NSE] failed to render avatar PNG")
            return base
        }

        let inImage = INImage(imageData: pngData)
        let handle  = INPersonHandle(value: senderHash, type: .unknown)
        let sender  = INPerson(
            personHandle:      handle,
            nameComponents:    nil,
            displayName:       senderName,
            image:             inImage,
            contactIdentifier: nil,
            customIdentifier:  senderHash
        )

        let intent = INSendMessageIntent(
            recipients:              nil,
            outgoingMessageType:     .outgoingMessageText,
            content:                 content,
            speakableGroupName:      nil,
            conversationIdentifier:  senderHash,
            serviceName:             nil,
            sender:                  sender,
            attachments:             nil
        )

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)

        do {
            let updated = try base.updating(from: intent)
            NSLog("[NSE] communication notification created OK")
            return updated
        } catch {
            NSLog("[NSE] content.updating(from:) failed: %@", error.localizedDescription)
            return base
        }
    }
}
