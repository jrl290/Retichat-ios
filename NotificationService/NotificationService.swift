import UserNotifications
import Intents
import UIKit

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
// The Rust delivery callback fires on a background thread.  It stores the
// message here and signals the semaphore so the main NSE thread can pick
// it up without polling.

private enum NSEDelivery {
    static var message: PendingNotification.NSEMessage?
    static var semaphore = DispatchSemaphore(value: 0)
    static var delivered = false      // accept only the first callback per run
    static var syncComplete = false   // prop sync finished (0 or N messages)
    static func reset() {
        message = nil
        delivered = false
        syncComplete = false
        // Replace semaphore to drain any stale signals from prior runs
        semaphore = DispatchSemaphore(value: 0)
    }
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

    // Accept only the first delivered message per NSE run
    guard !NSEDelivery.delivered else {
        NSLog("[NSE-CB] ignoring extra delivery")
        return
    }
    NSEDelivery.delivered = true

    NSEDelivery.message = PendingNotification.NSEMessage(
        messageHash:     msgHash.map { String(format: "%02x", $0) }.joined(),
        senderHash:      srcHex,
        destHash:        dest.map { String(format: "%02x", $0) }.joined(),
        title:           titleStr,
        content:         contentStr,
        timestamp:       timestamp,
        signatureValid:  signatureValid != 0,
        fieldsRawBase64: fields.base64EncodedString()
    )
    NSEDelivery.semaphore.signal()
}

// MARK: - C callback trampoline for sync-complete

private func nseSyncCompleteTrampoline(
    context: UnsafeMutableRawPointer?,
    messageCount: UInt32
) {
    NSLog("[NSE-CB] sync complete, %d messages", messageCount)
    NSEDelivery.syncComplete = true
    // Only signal if no message was delivered (delivery callback already signalled)
    if !NSEDelivery.delivered {
        NSEDelivery.semaphore.signal()
    }
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
/// 3. Wait for the delivery callback (semaphore, no polling).
/// 4. Rewrite the notification with real sender + content.
/// 5. Store the full message in the App Group for main-app import.
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
        requestPropagation()
        NSLog("[NSE] after requestPropagation, prop state=0x%02x", lxmfClient?.propagationState ?? -1)

        // Wait for delivery or sync-complete callback — keep ~3s margin before iOS kills at 30s
        let budget = max(27.0 - Date().timeIntervalSince(start), 1.0)
        NSLog("[NSE] waiting %.1fs for callback...", budget)
        let waitResult = NSEDelivery.semaphore.wait(timeout: .now() + budget)
        let elapsed = Int(Date().timeIntervalSince(start))
        let finalState = lxmfClient?.propagationState ?? -1
        NSLog("[NSE] wait done: signaled=%d delivered=%d syncComplete=%d state=0x%02x elapsed=%ds",
              waitResult == .success ? 1 : 0,
              NSEDelivery.delivered ? 1 : 0,
              NSEDelivery.syncComplete ? 1 : 0,
              finalState,
              elapsed)

        if let msg = NSEDelivery.message {
            NSLog("[NSE] delivered after %ds", elapsed)

            let chatNames = PendingNotification.readChatNames()
            let chatName = chatNames[msg.senderHash]
            let senderName: String
            if let name = chatName, !name.isEmpty {
                senderName = name
            } else if !msg.title.isEmpty {
                senderName = msg.title
            } else {
                senderName = String(msg.senderHash.prefix(8)) + "\u{2026}"
            }
            // --- Explicit APNs push receipt log ---
            NSLog("[NSE] APNs push received and processed: sender=%@ hash=%@", senderName, msg.messageHash)

            best.title = senderName
            best.body  = msg.content
            best.subtitle = ""
            best.threadIdentifier = msg.senderHash
            best.categoryIdentifier = "MESSAGE"
            best.userInfo["chatId"] = msg.senderHash

            // Store in App Group for main app to import on next open
            PendingNotification.appendNSEMessage(msg)

            // Wrap with INSendMessageIntent so iOS shows the avatar to the left
            // of the notification (Communication Notification, iOS 15+).
            let updated = attachAvatar(to: best, senderName: senderName, senderHash: msg.senderHash, content: msg.content)
            finishWithContent(updated)
            return

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
            displayName: "",
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

    private func requestPropagation() {
        guard let client = lxmfClient else {
            NSLog("[NSE] requestPropagation: no client")
            return
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
                return
            }
            NSLog("[NSE] sync failed for %@", String(hex.prefix(8)))
        }
        NSLog("[NSE] no propagation nodes succeeded")
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
