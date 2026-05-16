//
//  ChatRepository.swift
//  Retichat
//
//  Core data repository: message send/receive, group chat, attachments.
//  Mirrors the Android ChatRepository.kt.
//

import Foundation
import SwiftData
import Combine

@MainActor
final class ChatRepository: ObservableObject, MessageCallback, AnnounceCallback, MessageStateCallback {
    // MARK: - Published state

    @Published var chats: [Chat] = []
    @Published var serviceRunning = false
    @Published var ownHashHex: String = ""
    @Published var statusMessage: String = "Idle"

    // MARK: - Handles

    private(set) var lxmfClient: LxmfClient?
    private(set) var ownHash: Data = Data()

    // MARK: - Dependencies

    private let bridge = RetichatBridge.shared
    private let prefs = UserPreferences.shared
    private let propManager = PropagationNodeManager.shared
    private let notifManager = NotificationManager.shared

    private var modelContext: ModelContext?
    private var pollTimer: Timer?
    private var serviceStarting = false

    /// Last time `pollPropagationNode` was actually allowed to issue an FFI
    /// `client.sync(...)`. Used to throttle redundant callers (background-task
    /// expiry, NSE bridges, etc.) so the propagation node sees at most one
    /// query per `pollMinInterval`. Foreground transitions explicitly bypass
    /// the throttle by passing `force: true`.
    private var lastPollTime: Date = .distantPast
    private let pollMinInterval: TimeInterval = 290  // ~5 min, slightly < timer

    /// Set to `true` whenever the system suspends us (background-task
    /// expiration fires) — sockets will be torn down by iOS while we're
    /// suspended, so the next foreground transition needs a fresh PSYNC.
    /// Cleared on each foreground PSYNC so a quick app-switch that didn't
    /// trigger a real suspension won't re-fire the propagation node.
    var psyncNeededOnForeground: Bool = false

    // MARK: - Outbound message state tracking
    //
    // Keyed by LXMF message hash hex.  Populated at send time, removed when
    // the message reaches a terminal state (delivered, sent-to-prop, or failed).
    // The message_state_callback from Rust drives all state transitions.

    private struct PendingOutbound {
        let messageId: String      // DB record primary key (= original msg hash hex)
        let chatId: String
        let peerHash: Data
        let method: UInt8          // LxmfMethod.direct or .propagated
        let msgHandle: UInt64
        let content: String
        let title: String
        let hasAttachments: Bool
    }

    private var pendingOutbound: [String: PendingOutbound] = [:]

    /// Timers for the 5-second propagation fallback. Keyed by direct msg hash hex.
    private var propFallbackTimers: [String: DispatchWorkItem] = [:]
    /// Message IDs that already had a propagation fallback dispatched.
    private var propFallbackSent: Set<String> = []

    /// Serial queue for all FFI calls into the Rust LXMF library.
    /// Keeps the main thread responsive while crypto, link establishment,
    /// and outbound processing run in the background.
    ///
    /// QoS is `.utility` (not `.userInitiated`) deliberately: FFI calls
    /// can block on link-actor mailboxes that ultimately wait on socket
    /// writes to remote peers. If this queue ran at `.userInitiated`,
    /// any user-driven UI work that later awaited the same queue would
    /// inherit a priority inversion against the default-QoS Rust threads
    /// servicing those sockets (Thread Performance Checker warning, and
    /// in pathological cases a permanent UI freeze).
    private let ffiQueue = DispatchQueue(label: "chat.retichat.ffi", qos: .utility)

    // MARK: - Init

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Service lifecycle

    func startService() {
        guard !serviceRunning, !serviceStarting else { return }
        serviceStarting = true

        print("[Retichat] v1.0 build 2 starting")

        statusMessage = "Starting…"

        let configDir = reticulumConfigDir()
        let needsFallbackEndpoints = enabledTCPClientInterfaces().isEmpty

        Task { [weak self] in
            guard let self else { return }
            let fallbackEndpoints = needsFallbackEndpoints
                ? await DefaultEndpointManager.selectFallbackEndpoints()
                : []
            self.continueStartService(configDir: configDir, fallbackEndpoints: fallbackEndpoints)
        }
    }

    private func continueStartService(configDir: String, fallbackEndpoints: [(host: String, port: Int)]) {
        generateConfig(configDir: configDir, fallbackEndpoints: fallbackEndpoints)

        let idPath = configDir + "/identity"
        let storagePath = configDir + "/lxmf_storage"
        try? FileManager.default.createDirectory(
            atPath: storagePath, withIntermediateDirectories: true
        )

        let config = LxmfClientConfig(
            configDir: configDir,
            storagePath: storagePath,
            identityPath: idPath,
            createIdentity: true,
            displayName: prefs.displayName,
            logLevel: 4,
            stampCost: -1
        )

        // Heavy FFI call (TCP connect, transport init, ratchet load) runs off
        // the main thread so the UI stays responsive during startup.
        Task.detached(priority: .userInitiated) { [config, idPath, configDir, storagePath] in
            let result: Result<LxmfClient, Error> = Result {
                try LxmfClient.start(config: config)
            }

            // Persist the live router state before mirroring files into the App
            // Group, otherwise the NSE can read an older ratchet snapshot.
            if case .success(let client) = result {
                client.persist()
            }

            // App Group file copies are pure I/O — keep them off main thread too
            PendingNotification.copyIdentityToAppGroup(from: idPath)
            PendingNotification.copyConfigToAppGroup(from: configDir + "/config")
            PendingNotification.syncStorageToAppGroup(from: configDir + "/storage")
            PendingNotification.syncRatchetsToAppGroup(from: storagePath)

            await MainActor.run { [weak self] in
                self?.finishStartService(result: result, configDir: configDir, storagePath: storagePath)
            }
        }
    }

    /// Second half of startup — runs on @MainActor after the FFI call completes.
    ///
    /// Startup ordering (deterministic; do not rearrange casually):
    ///   1. Stash client + own-hash so other layers can find them.
    ///   2. Wire up the FFI callbacks (must be before any traffic flows).
    ///   3. Configure announce-drop policy (must be before path discovery).
    ///   4. Register with `ConnectionStateManager` — this kicks off the
    ///      single, coordinated `requestEssentialPaths` + `openRfedNodeLink`
    ///      sequence. RFed/propagation components use their own request/link
    ///      flows and do not depend on AppLinks.
    ///   5. Flip `serviceRunning = true` — this lets the App scene's
    ///      `.onReceive` handler wire up `RfedChannelClient` exactly once.
    ///   6. Start RNode interfaces (independent of the path/link stack).
    ///   7. Hand delivery destination to publish daemon (auto-re-announce).
    ///   8. Side-tasks: ratchet sync, periodic poll, rfed notify register.
    ///
    /// Each step that touches the FFI is hopped to `ffiQueue` (serial) or to
    /// a detached Task; all on-main-actor work above runs synchronously in
    /// the order written, so component callbacks observe a consistent state.
    private func finishStartService(result: Result<LxmfClient, Error>, configDir: String, storagePath: String) {
        serviceStarting = false
        let client: LxmfClient
        switch result {
        case .success(let c):
            client = c
        case .failure(let error):
            print("[Retichat] Failed to start: \(error.localizedDescription)")
            statusMessage = "Failed to start"
            return
        }

        self.lxmfClient = client
        ownHash = client.destHash
        ownHashHex = client.destHashHex
        print("[Retichat] Identity hash: \(client.identityHashHex)")

        // Set callbacks
        bridge.wireCallbacks(to: lxmfClient!, messageCallback: self, announceCallback: self, messageStateCallback: self)

        // Leaf-node mode: drop unsolicited network-wide announces; only PATH_RESPONSE
        // replies to our own transportRequestPath calls pass through.
        let t_drop = CFAbsoluteTimeGetCurrent()
        bridge.setDropAnnounces(enabled: prefs.dropAnnounces)
        print("[DIAG][finishStart] setDropAnnounces took=\(String(format:"%.3f", CFAbsoluteTimeGetCurrent()-t_drop))s")

        // Register with the connection state manager (path requests, peer tracking).
        ConnectionStateManager.shared.register(lxmfClient: client)

        serviceRunning = true
        statusMessage = "Connected — \(ownHashHex.prefix(8))…"

        // Bring up any saved RNode interfaces alongside the TCP transports
        // configured via TOML. RNode rows are not in the TOML; they are
        // attached via the FFI `rns_rnode_iface_register` callback transport.
        let rnodeRows: [(id: String, name: String, configJSON: String?)] =
            interfaces()
                .filter { $0.enabled && $0.type == InterfaceKind.rnode.rawValue }
                .map { ($0.id, $0.name, $0.configJSON) }
        RNodeInterfaceCoordinator.shared.start(with: rnodeRows)

        // Hand the delivery destination off to Transport's auto-announce
        // daemon: it will announce immediately, on every interface up-edge,
        // and every 30 minutes thereafter.  Replaces the previous Timer +
        // onConnect re-announce + foreground re-announce pattern.
        let publishClient = lxmfClient
        ffiQueue.async {
            guard let publishClient else { return }
            _ = publishClient.publish(refreshSecs: 30 * 60)
        }

        // Sync ratchets to App Group after announce (so the NSE can decrypt).
        // Heavy file-copy I/O runs off the main thread.
        Task.detached(priority: .utility) {
            PendingNotification.syncRatchetsToAppGroup(from: storagePath)
        }

        // Start propagation polling
        startPropagationPolling()

        // Register with rfed notify service so the relay can wake this device.
        registerRfedNotify()

        // Network reconnect handler.  Transport now auto-re-announces on
        // every interface up-edge, so we no longer need to explicitly call
        // announce() here — just nudge the TCP reconnect loops awake and
        // flush any deferred outbound traffic.
        NetworkMonitor.shared.onConnect = { [weak self] in
            // Immediately wake any TCP reconnect loops that are sleeping
            RetichatBridge.shared.nudgeReconnect()
            Task { @MainActor in
                ConnectionStateManager.shared.onNetworkReconnect()
                self?.flushPendingMessages()
            }
        }

        // Import any messages the NSE delivered while we were dead
        importNSEMessages()

        print("[Retichat] Service started. Hash: \(ownHashHex)")
    }

    func stopService() {
        pollTimer?.invalidate()
        pollTimer = nil

        // Stop Transport's auto-announce of our delivery destination.
        if let client = lxmfClient {
            ffiQueue.async { _ = client.unpublish() }
        }

        // Tear down RNode interfaces before shutting down the LXMF client so
        // the Rust side stops before the callback transports are dropped.
        RNodeInterfaceCoordinator.shared.stop()

        // Destroy any message handles still in flight.
        for (_, pending) in pendingOutbound {
            LxmfClient.messageDestroy(pending.msgHandle)
        }
        pendingOutbound.removeAll()

        lxmfClient?.shutdown()
        lxmfClient = nil
        serviceRunning = false
        statusMessage = "Stopped"
    }

    // MARK: - RFed APNs token registration

    /// Registers this device for push notifications:
    /// 1. Sends APNs token to the apns_bridge (rfed.apns, hardcoded).
    /// 2. Registers the relay hash with rfed (rfed.notify Link request).
    private func registerRfedNotify() {
        guard !ownHash.isEmpty, let client = lxmfClient else { return }
        // 1. Register APNs token with the apns_bridge (plain packet → rfed.apns)
        ApnsTokenRegistrar.shared.registerIfNeeded(subscriberHash: ownHash)
        // 2. Register relay hash with rfed (Link request → rfed.notify)
        RfedNotifyRegistrar.shared.registerIfNeeded(identityHandle: client.identityHandle)
    }

    // MARK: - Config generation

    private func reticulumConfigDir() -> String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.path
        let dir = appSupport + "/reticulum"
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        return dir
    }

    private func enabledTCPClientInterfaces() -> [InterfaceConfigEntity] {
        guard let ctx = modelContext else { return [] }
        let tcpType = InterfaceKind.tcpClient.rawValue
        let descriptor = FetchDescriptor<InterfaceConfigEntity>(
            predicate: #Predicate { $0.enabled == true && $0.type == tcpType }
        )
        return (try? ctx.fetch(descriptor)) ?? []
    }

    private func generateConfig(configDir: String, fallbackEndpoints: [(host: String, port: Int)]) {
        let configPath = configDir + "/config"

        // Build config with proper format:
        //   [[InterfaceName]]      <- user-friendly name as section header
        //     type = TCPClientInterface   <- type key inside section
        var lines: [String] = []
        lines.append("[reticulum]")
        lines.append("  enable_transport = false")
        lines.append("  share_instance = false")
        lines.append("  panic_on_interface_errors = false")
        lines.append("")
        lines.append("[logging]")
        lines.append("  loglevel = 4")
        lines.append("")
        lines.append("[interfaces]")

        // Explicitly disable AutoInterface so the app never does local network
        // discovery (IPv6 multicast). Without this, when running on a simulator
        // the app can discover and directly connect to local Reticulum nodes
        // (hops=0), bypassing the configured public backbone endpoints.
        lines.append("")
        lines.append("  [[AutoInterface]]")
        lines.append("    type = AutoInterface")
        lines.append("    enabled = No")

        // Get user-configured interfaces from database (TCP client only —
        // RNode rows are realised through the BLE bridge + rns_rnode_iface_*
        // FFI, not the TOML config).
        var addedInterfaces = false
        let interfaces = enabledTCPClientInterfaces()
        if !interfaces.isEmpty {
            for iface in interfaces {
                lines.append("")
                lines.append("  [[\(iface.name)]]")
                lines.append("    type = TCPClientInterface")
                lines.append("    target_host = \(iface.targetHost)")
                lines.append("    target_port = \(iface.targetPort)")
                lines.append("    enabled = yes")
            }
            addedInterfaces = true
        }

        if !addedInterfaces {
            let endpoints = fallbackEndpoints.isEmpty
                ? Array(DefaultEndpointManager.shuffled().prefix(DefaultEndpointManager.fallbackEndpointCount))
                : fallbackEndpoints
            print("[DefaultEndpoint] selected fallback endpoints: \(endpoints.map { "\($0.host):\($0.port)" }.joined(separator: ", "))")
            // Default: connect to the first reachable public backbone endpoints
            // from a randomized probe pool, padded from the same pool if the
            // network is offline during startup.
            for (index, endpoint) in endpoints.enumerated() {
                lines.append("")
                lines.append("  [[DefaultBackbone\(index + 1)]]")
                lines.append("    type = TCPClientInterface")
                lines.append("    target_host = \(endpoint.host)")
                lines.append("    target_port = \(endpoint.port)")
                lines.append("    enabled = yes")
            }
        }

        let config = lines.joined(separator: "\n") + "\n"
        try? config.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Propagation polling

    private func startPropagationPolling() {
        // Apply user-configured node before the first poll fires.
        propManager.setUserConfiguredNode(prefs.effectiveLxmfPropagationHash)

        // Share propagation node list with NSE so it can sync on its own.
        syncPropagationNodesToAppGroup()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollPropagationNode()
            }
        }
        // Initial poll after 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.pollPropagationNode()
        }
    }

    /// Write the full propagation node list to the App Group so the NSE can
    /// request messages when the main app is dead (force-quit).
    private func syncPropagationNodesToAppGroup() {
        let hashes = propManager.orderedNodeHashes()
        // Heavy I/O (persist + file copies) runs off the main thread
        let configDir = reticulumConfigDir()
        let client = lxmfClient
        let hashSnapshot = hashes
        let queue = ffiQueue
        Task.detached(priority: .utility) {
            PendingNotification.writePropagationNodes(hashSnapshot)
            queue.async { client?.persist() }
            PendingNotification.syncStorageToAppGroup(from: configDir + "/storage")
            PendingNotification.syncRatchetsToAppGroup(from: configDir + "/lxmf_storage")
        }
    }

    /// Flush in-memory path table and ratchets to disk so they survive app suspension.
    func persist() {
        guard let client = lxmfClient else { return }
        ffiQueue.async {
            client.persist()
        }
    }

    // MARK: - NSE message import

    /// Import messages that the NSE delivered while the app was not running.
    func importNSEMessages() {
        let messages = PendingNotification.readAndClearNSEMessages()
        guard !messages.isEmpty, let ctx = modelContext else { return }
        print("[Retichat] importing \(messages.count) NSE message(s)")

        for msg in messages {
            // Dedup — skip if we already have this message
            let hashHex = msg.messageHash
            let dup = FetchDescriptor<MessageEntity>(
                predicate: #Predicate { $0.id == hashHex }
            )
            if let existing = try? ctx.fetch(dup), !existing.isEmpty { continue }

            let srcHex = msg.senderHash

            // Decode LXMF fields
            let fieldsData = Data(base64Encoded: msg.fieldsRawBase64) ?? Data()
            let fields = LxmfFieldsDecoder.decode(fieldsData)

            if let groupId = fields.groupId {
                // For invites: filter by sender, not groupId (groupId not in allowlist yet)
                // For all other group actions: filter by groupId (must be a known group)
                let shouldProcess: Bool
                if fields.groupAction == GroupAction.invite {
                    shouldProcess = isAllowlisted(destHash: srcHex)
                } else {
                    shouldProcess = isAllowlisted(destHash: groupId)
                }
                if shouldProcess {
                    handleGroupMessage(
                        hash: Data(hexString: msg.messageHash) ?? Data(),
                        srcHash: Data(hexString: srcHex) ?? Data(),
                        content: msg.content,
                        timestamp: msg.timestamp,
                        fields: fields,
                        groupId: groupId
                    )
                }
                continue
            }

            // Filter: drop messages from senders not in the contact allowlist
            guard isAllowlisted(destHash: srcHex) else { continue }

            let chatId = srcHex
            ensureChat(id: chatId, peerHash: srcHex)
            ensureContact(destHash: srcHex)

            let entity = MessageEntity(
                id: hashHex,
                chatId: chatId,
                senderHash: srcHex,
                content: msg.content,
                title: msg.title,
                timestamp: msg.timestamp,
                isOutgoing: false,
                deliveryState: DeliveryState.delivered,
                signatureValid: msg.signatureValid
            )
            ctx.insert(entity)

            for (filename, data) in fields.attachments {
                let att = AttachmentEntity(
                    id: UUID().uuidString,
                    messageId: hashHex,
                    filename: filename,
                    data: data
                )
                ctx.insert(att)
            }

            updateChatTimestamp(chatId: chatId, timestamp: msg.timestamp)
        }

        try? ctx.save()
        refreshChats()
    }

    func pollPropagationNode(force: Bool = false) {
        guard let client = lxmfClient else { return }

        // Throttle: only foreground transitions (force=true) may bypass the
        // 5-minute floor. The background-task hooks, the periodic timer, and
        // any other casual caller all share the same minimum cadence so we
        // never spam the propagation node like the pre-2026-04 logs showed.
        let now = Date()
        if !force, now.timeIntervalSince(lastPollTime) < pollMinInterval {
            return
        }
        lastPollTime = now

        propManager.setUserConfiguredNode(prefs.effectiveLxmfPropagationHash)

        if let nodeHash = propManager.currentNode() {
            // PSYNC link establishment needs the propagation node's identity
            // (public key), not just a cached path. On cold start the path
            // table loads from disk while known-destinations is empty until
            // an announce arrives. Kick a path request if identity is
            // missing — PATH_RESPONSE is an announce and will populate the
            // known-destinations table on receipt. The next poll cycle then
            // succeeds. See DESIGN_PRINCIPLES.md §1: no retries here, the
            // existing periodic poll IS the retry cadence.
            let bridge = RetichatBridge.shared
            if !bridge.transportIdentityKnown(destHash: nodeHash) {
                _ = bridge.transportRequestPath(destHash: nodeHash)
                print("[Retichat] pollPropagationNode: requested path for \(nodeHash.hexString.prefix(8)) (identity not yet known) — skipping this cycle")
                return
            }
            ffiQueue.async { [weak self] in
                let ok = client.sync(nodeHash: nodeHash)
                if !ok {
                    Task { @MainActor [weak self] in
                        self?.propManager.rotateToNext()
                    }
                }
            }
        }
    }

    // MARK: - Send message

    func sendMessage(chatId: String, content: String, attachments: [(String, Data)] = []) {
        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[Retichat] sendMessage called chatId=\(chatId.prefix(8)) content=\(content.prefix(20))")
        guard let ctx = modelContext else {
            print("[Retichat] sendMessage: ABORT - modelContext is nil")
            return
        }

        // Look up the chat
        let chatDescriptor = FetchDescriptor<ChatEntity>(
            predicate: #Predicate { $0.id == chatId }
        )
        guard let chat = try? ctx.fetch(chatDescriptor).first else {
            print("[Retichat] sendMessage: ABORT - chat not found for id=\(chatId)")
            return
        }

        // Branch: group vs. direct
        if chat.isGroup {
            sendGroupMessage(chat: chat, chatId: chatId, content: content, attachments: attachments)
            return
        }

        let destHashHex = chat.peerHash
        print("[Retichat] sendMessage: destHashHex=\(destHashHex.prefix(8)) lxmfClientNil=\(lxmfClient == nil)")
        guard let destData = Data(hexString: destHashHex) else {
            print("[Retichat] sendMessage: ABORT - invalid destHashHex=\(destHashHex)")
            return
        }

        guard let client = lxmfClient else {
            print("[Retichat] sendMessage: ABORT - lxmfClient is nil")
            return
        }

        // Decide delivery method at send time from live link state.
        //
        // If a link to this peer is currently being established (we just
        // opened the conversation, an announce just arrived, etc.) the Rust
        // process_outbound stagger will handle the DIRECT→PROPAGATED fallback
        // within 3 s. No need to pre-decide here.
        // NEVER REMOVE EVER — see DESIGN_PRINCIPLES.md §1
        let initialName = ConnectionStateManager.shared.deliveryMethod(for: destData) == LxmfMethod.direct ? "DIRECT" : "PROPAGATED"
        print("[Retichat] sendMessage: initial method=\(initialName) dest=\(destHashHex.prefix(8))")

        // --- Optimistic bubble: insert immediately so the UI responds without waiting for FFI ---
        let tempId = "pending_\(UUID().uuidString)"
        let optimisticTimestamp = Date().timeIntervalSince1970
        let msgEntity = MessageEntity(
            id: tempId,
            chatId: chatId,
            senderHash: ownHashHex,
            content: content,
            timestamp: optimisticTimestamp,
            isOutgoing: true,
            deliveryState: DeliveryState.pending
        )
        ctx.insert(msgEntity)
        for (filename, data) in attachments {
            ctx.insert(AttachmentEntity(
                id: UUID().uuidString,
                messageId: tempId,
                filename: filename,
                data: data
            ))
        }
        chat.lastMessageTime = optimisticTimestamp
        try? ctx.save()
        refreshChats()

        // Capture values for the background closure
        let ownHex = ownHashHex
        let attachmentsCopy = attachments

        // Resolve delivery method synchronously — Rust (process_outbound)
        // owns the DIRECT→PROPAGATED stagger and backstop, so there is no
        // reason to wait here.  We always pass DIRECT if a path or active
        // link exists; Rust falls back to PROPAGATED after its 3-second
        // stagger if the link doesn't materialise in time.
        let method = ConnectionStateManager.shared.deliveryMethod(for: destData)
        let methodName = method == LxmfMethod.direct ? "DIRECT" : "PROPAGATED"
        print("[Retichat] sendMessage: method=\(methodName) dest=\(destHashHex.prefix(8))")

        let ffiQueueRef = ffiQueue
        Task.detached(priority: .userInitiated) { [weak self] in
            ffiQueueRef.async { [weak self] in
                let msgHandle = client.createMessage(
                    to: destData,
                    content: content,
                    title: "",
                    method: method
                )
            guard msgHandle != 0 else {
                print("[Retichat] Failed to create message: \(LxmfClient.lastError ?? "")")
                Task { @MainActor [weak self] in
                    guard let ctx = self?.modelContext else { return }
                    let desc = FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.id == tempId })
                    if let temp = try? ctx.fetch(desc).first {
                        temp.deliveryState = DeliveryState.failed
                        try? ctx.save()
                    }
                    self?.refreshChats()
                }
                return
            }

            for (filename, data) in attachmentsCopy {
                _ = LxmfClient.messageAddAttachment(msgHandle, filename: filename, data: data)
            }

            // pack() + process_outbound() run here, off the main thread.
            guard client.sendMessage(msgHandle) else {
                print("[Retichat] Failed to send message: \(LxmfClient.lastError ?? "")")
                LxmfClient.messageDestroy(msgHandle)
                Task { @MainActor [weak self] in
                    guard let ctx = self?.modelContext else { return }
                    let desc = FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.id == tempId })
                    if let temp = try? ctx.fetch(desc).first {
                        temp.deliveryState = DeliveryState.failed
                        try? ctx.save()
                    }
                    self?.refreshChats()
                }
                return
            }

            guard let msgHashData = LxmfClient.messageHash(msgHandle), !msgHashData.isEmpty else {
                print("[Retichat] Failed to get message hash after send")
                LxmfClient.messageDestroy(msgHandle)
                Task { @MainActor [weak self] in
                    guard let ctx = self?.modelContext else { return }
                    let desc = FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.id == tempId })
                    if let temp = try? ctx.fetch(desc).first {
                        temp.deliveryState = DeliveryState.failed
                        try? ctx.save()
                    }
                    self?.refreshChats()
                }
                return
            }
            let msgHashHex = msgHashData.hexString

            // Hop back to @MainActor for database writes and UI updates.
            Task { @MainActor [weak self] in
                guard let self, let ctx = self.modelContext else { return }

                // Update the optimistic entity in-place with the real hash and handle.
                let desc = FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.id == tempId })
                if let temp = try? ctx.fetch(desc).first {
                    temp.id = msgHashHex
                    temp.nativeHandle = msgHandle
                    // Update attachment foreign keys to point to the real message id.
                    let attDesc = FetchDescriptor<AttachmentEntity>(
                        predicate: #Predicate { $0.messageId == tempId }
                    )
                    for att in (try? ctx.fetch(attDesc)) ?? [] {
                        att.messageId = msgHashHex
                    }
                } else {
                    // Fallback: optimistic entity was lost — insert fresh.
                    ctx.insert(MessageEntity(
                        id: msgHashHex,
                        chatId: chatId,
                        senderHash: ownHex,
                        content: content,
                        timestamp: optimisticTimestamp,
                        isOutgoing: true,
                        deliveryState: DeliveryState.pending,
                        nativeHandle: msgHandle
                    ))
                    for (filename, data) in attachmentsCopy {
                        ctx.insert(AttachmentEntity(
                            id: UUID().uuidString,
                            messageId: msgHashHex,
                            filename: filename,
                            data: data
                        ))
                    }
                }

                try? ctx.save()

                self.pendingOutbound[msgHashHex] = PendingOutbound(
                    messageId: msgHashHex,
                    chatId: chatId,
                    peerHash: destData,
                    method: method,
                    msgHandle: msgHandle,
                    content: content,
                    title: "",
                    hasAttachments: !attachmentsCopy.isEmpty
                )

                // The 5-second propagation fallback is now owned by Rust
                // (AppLinks Timer P).  It fires PROP_FALLBACK_REQUESTED (0x10)
                // via message_state_callback at exactly 5 s after send starts.
                // No iOS-side timer needed.

                self.refreshChats()
            }
            }  // ffiQueueRef.async
        }  // Task.detached
    }

    // MARK: - Group message send (fanout to all accepted members)

    private func sendGroupMessage(
        chat: ChatEntity, chatId: String, content: String, attachments: [(String, Data)]
    ) {
        guard let ctx = modelContext, let client = lxmfClient else { return }

        // Get accepted members excluding self
        let memberDesc = FetchDescriptor<GroupMemberEntity>(
            predicate: #Predicate { $0.groupId == chatId }
        )
        let allMembers = (try? ctx.fetch(memberDesc)) ?? []
        let targets = allMembers
            .filter { $0.inviteStatus == MemberStatus.accepted && $0.memberHash != ownHashHex }
            .map { $0.memberHash }

        // Generate a stable local ID for this outbound group message
        let msgId = "grp_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(8))"

        // Insert optimistically
        let msgEntity = MessageEntity(
            id: msgId,
            chatId: chatId,
            senderHash: ownHashHex,
            content: content,
            timestamp: Date().timeIntervalSince1970,
            isOutgoing: true,
            deliveryState: DeliveryState.sent   // fanout is fire-and-forget
        )
        ctx.insert(msgEntity)

        for (filename, data) in attachments {
            ctx.insert(AttachmentEntity(
                id: UUID().uuidString, messageId: msgId, filename: filename, data: data
            ))
        }

        chat.lastMessageTime = msgEntity.timestamp
        try? ctx.save()

        // Fan out to accepted members — FFI calls run off the main thread.
        let groupName = chat.groupName ?? "Group"
        let selfHash = ownHashHex
        ffiQueue.async {
            GroupChatManager.shared.fanoutMessage(
                groupId: chatId,
                groupName: groupName,
                content: content,
                attachments: attachments,
                to: targets,
                from: selfHash,
                via: client
            )
        }

        refreshChats()
    }

    // MARK: - Group invite / accept / leave

    /// Accept a pending group invite: mark all members as allowlisted,
    /// record ourselves as accepted, and broadcast acceptance to others.
    func acceptGroupInvite(groupId: String) {
        guard let ctx = modelContext, let client = lxmfClient else { return }

        let chatDesc = FetchDescriptor<ChatEntity>(predicate: #Predicate { $0.id == groupId })
        guard let chat = try? ctx.fetch(chatDesc).first else { return }

        // Promote from pending to active
        chat.groupStatus = "active"

        // Gather the full member list stored from the invite
        let memberDesc = FetchDescriptor<GroupMemberEntity>(
            predicate: #Predicate { $0.groupId == groupId }
        )
        let existingMembers = (try? ctx.fetch(memberDesc)) ?? []
        let allHashes = existingMembers.map { $0.memberHash }

        // Mark ourselves as accepted (add our entry if absent)
        if let selfEntry = existingMembers.first(where: { $0.memberHash == ownHashHex }) {
            selfEntry.inviteStatus = MemberStatus.accepted
        } else {
            ctx.insert(GroupMemberEntity(groupId: groupId, memberHash: ownHashHex,
                                         inviteStatus: MemberStatus.accepted))
        }

        // Add all group members to allowlist (key spec requirement)
        for hash in allHashes {
            ensureAllowlistedContact(destHash: hash)
            if hash != ownHashHex, let hashData = Data(hexString: hash) {
                RetichatBridge.shared.watchAnnounce(destHash: hashData)
            }
        }
        ensureAllowlistedContact(destHash: groupId)

        try? ctx.save()

        // Broadcast acceptance to everyone else — FFI off main thread
        let targets = allHashes.filter { $0 != ownHashHex }
        let selfHash = ownHashHex
        ffiQueue.async {
            GroupChatManager.shared.sendAccept(
                groupId: groupId, to: targets, from: selfHash, via: client
            )
        }

        refreshChats()
    }

    /// Decline a pending group invite and remove all local state.
    func declineGroupInvite(groupId: String) {
        deleteChat(chatId: groupId)
    }

    /// Leave an active group: notify accepted members, then delete local state.
    func leaveGroup(chatId: String) {
        guard let client = lxmfClient else {
            deleteChat(chatId: chatId)
            return
        }

        let acceptedMembers = (groupMembersWithStatus(groupId: chatId) ?? [])
            .filter { $0.inviteStatus == MemberStatus.accepted && $0.memberHash != ownHashHex }
            .map { $0.memberHash }

        let selfHash = ownHashHex
        ffiQueue.async {
            GroupChatManager.shared.sendLeave(
                groupId: chatId, to: acceptedMembers, from: selfHash, via: client
            )
        }
        deleteChat(chatId: chatId)
    }

    // MARK: - Conversation lifecycle (delegates to ConnectionStateManager)

    /// Call when a conversation screen appears.  Opens app links for the peer
    /// (direct chat) or all accepted members (group chat) so links are
    /// pre-established before the user taps send.
    func openConversation(chatId: String) {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<ChatEntity>(predicate: #Predicate { $0.id == chatId })
        guard let chat = try? ctx.fetch(desc).first else { return }

        if chat.isGroup {
            let memberDesc = FetchDescriptor<GroupMemberEntity>(
                predicate: #Predicate { $0.groupId == chatId }
            )
            let members = (try? ctx.fetch(memberDesc)) ?? []
            for member in members where member.memberHash != ownHashHex {
                if let peerHash = Data(hexString: member.memberHash) {
                    ConnectionStateManager.shared.openConversation(peerHash: peerHash)
                }
            }
        } else {
            guard let peerHash = Data(hexString: chat.peerHash) else { return }
            ConnectionStateManager.shared.openConversation(peerHash: peerHash)
        }
    }

    /// Call when a conversation screen disappears.  Closes app links for
    /// all peers that were opened by openConversation.
    func closeConversation(chatId: String) {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<ChatEntity>(predicate: #Predicate { $0.id == chatId })
        guard let chat = try? ctx.fetch(desc).first else { return }

        if chat.isGroup {
            let memberDesc = FetchDescriptor<GroupMemberEntity>(
                predicate: #Predicate { $0.groupId == chatId }
            )
            let members = (try? ctx.fetch(memberDesc)) ?? []
            for member in members where member.memberHash != ownHashHex {
                if let peerHash = Data(hexString: member.memberHash) {
                    ConnectionStateManager.shared.closeConversation(peerHash: peerHash)
                }
            }
        } else {
            guard let peerHash = Data(hexString: chat.peerHash) else { return }
            ConnectionStateManager.shared.closeConversation(peerHash: peerHash)
        }
    }

    // MARK: - MessageStateCallback

    @MainActor func onMessageState(hash: Data, state: UInt8) {
        handleMessageState(hash: hash, state: state)
    }

    private func handleMessageState(hash: Data, state: UInt8) {
        let hashHex = hash.hexString
        guard let pending = pendingOutbound[hashHex] else { return }

        switch state {

        case 0x04:  // SENT — propagated message accepted by the prop node.
            cancelPropFallback(directHashHex: hashHex)
            updateDeliveryState(messageId: pending.messageId, state: DeliveryState.sent)
            completePending(hashHex: hashHex, pending: pending)

        case 0x08:  // DELIVERED — recipient downloaded and decrypted the message.
            cancelPropFallback(directHashHex: hashHex)
            updateDeliveryState(messageId: pending.messageId, state: DeliveryState.delivered)
            completePending(hashHex: hashHex, pending: pending)

        case 0x10:  // PROP_FALLBACK_REQUESTED — Rust Timer P fired at 5 s.
            // The direct send is still running; start propagation in parallel.
            // LXMF dedup on the receiver handles any double-delivery.
            if pending.method == LxmfMethod.direct && !pending.hasAttachments {
                if !propFallbackSent.contains(pending.messageId) {
                    propFallbackSent.insert(pending.messageId)
                    updateDeliveryState(messageId: pending.messageId, state: DeliveryState.propagating)
                    retrySendViaPropNode(pending)
                }
            }

        case 0xFD, 0xFE, 0xFF:  // REJECTED, CANCELLED, FAILED.
            cancelPropFallback(directHashHex: hashHex)
            if pending.method == LxmfMethod.direct && !pending.hasAttachments {
                if propFallbackSent.contains(pending.messageId) {
                    // Prop fallback already dispatched — just clean up this direct entry.
                    print("[Retichat] Direct FAILED but prop fallback already in flight for \(pending.messageId.prefix(8))")
                    completePending(hashHex: hashHex, pending: pending)
                } else {
                    // No fallback yet — retry now via prop node.
                    ConnectionStateManager.shared.markPeerDegraded(
                        destHex: pending.peerHash.hexString
                    )
                    propFallbackSent.insert(pending.messageId)
                    pendingOutbound.removeValue(forKey: hashHex)
                    LxmfClient.messageDestroy(pending.msgHandle)
                    retrySendViaPropNode(pending)
                }
            } else if pending.method == LxmfMethod.propagated {
                // Propagated terminal failure — clean up fallback tracking.
                propFallbackSent.remove(pending.messageId)
                updateDeliveryState(messageId: pending.messageId, state: DeliveryState.failed)
                completePending(hashHex: hashHex, pending: pending)
            } else {
                // Has attachments or other — final failure.
                updateDeliveryState(messageId: pending.messageId, state: DeliveryState.failed)
                completePending(hashHex: hashHex, pending: pending)
            }

        default:
            break  // Intermediate states (e.g. SENDING=0x02) — no DB update.
        }
    }

    private func completePending(hashHex: String, pending: PendingOutbound) {
        pendingOutbound.removeValue(forKey: hashHex)
        LxmfClient.messageDestroy(pending.msgHandle)
        // Clean up fallback tracking when a propagated message reaches terminal state.
        if pending.method == LxmfMethod.propagated {
            propFallbackSent.remove(pending.messageId)
        }
    }

    // MARK: - 5-second propagation fallback

    private static let propFallbackDelay: TimeInterval = 5.0

    private func schedulePropFallback(directHashHex: String) {
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let pending = self.pendingOutbound[directHashHex],
                      pending.method == LxmfMethod.direct,
                      !self.propFallbackSent.contains(pending.messageId) else { return }

                print("[Retichat] 5s fallback: direct msg \(directHashHex.prefix(8)) not delivered, sending via propagation")
                self.propFallbackSent.insert(pending.messageId)
                self.updateDeliveryState(messageId: pending.messageId, state: DeliveryState.propagating)
                self.retrySendViaPropNode(pending)
            }
        }
        propFallbackTimers[directHashHex] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.propFallbackDelay, execute: work)
    }

    private func cancelPropFallback(directHashHex: String) {
        propFallbackTimers.removeValue(forKey: directHashHex)?.cancel()
    }

    /// Retry a failed direct-mode message via the propagation node.
    private func retrySendViaPropNode(_ original: PendingOutbound) {
        guard let client = lxmfClient else {
            updateDeliveryState(messageId: original.messageId, state: DeliveryState.failed)
            return
        }

        // Run FFI calls off the main thread.
        ffiQueue.async { [weak self] in
            let msgHandle = client.createMessage(
                to: original.peerHash,
                content: original.content,
                title: original.title,
                method: LxmfMethod.propagated
            )
            guard msgHandle != 0 else {
                Task { @MainActor [weak self] in
                    self?.updateDeliveryState(messageId: original.messageId, state: DeliveryState.failed)
                }
                return
            }

            guard client.sendMessage(msgHandle) else {
                LxmfClient.messageDestroy(msgHandle)
                Task { @MainActor [weak self] in
                    self?.updateDeliveryState(messageId: original.messageId, state: DeliveryState.failed)
                }
                return
            }

            guard let hashData = LxmfClient.messageHash(msgHandle), !hashData.isEmpty else {
                LxmfClient.messageDestroy(msgHandle)
                Task { @MainActor [weak self] in
                    self?.updateDeliveryState(messageId: original.messageId, state: DeliveryState.failed)
                }
                return
            }

            let newHashHex = hashData.hexString
            Task { @MainActor [weak self] in
                self?.pendingOutbound[newHashHex] = PendingOutbound(
                    messageId: original.messageId,
                    chatId: original.chatId,
                    peerHash: original.peerHash,
                    method: LxmfMethod.propagated,
                    msgHandle: msgHandle,
                    content: original.content,
                    title: original.title,
                    hasAttachments: false
                )
            }
        }
    }

    private func updateDeliveryState(messageId: String, state: Int) {
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<MessageEntity>(
            predicate: #Predicate { $0.id == messageId }
        )
        if let msg = try? ctx.fetch(descriptor).first {
            msg.deliveryState = state
            try? ctx.save()
        }
    }

    // MARK: - Flush pending

    func flushPendingMessages() {
        guard let client = lxmfClient else { return }
        ffiQueue.async {
            client.processOutbound()
        }
    }

    // MARK: - MessageCallback

    @MainActor func onMessage(hash: Data, srcHash: Data, destHash: Data,
                               title: String, content: String, timestamp: Double,
                               signatureValid: Bool, fieldsRaw: Data) {
        handleIncomingMessage(
            hash: hash, srcHash: srcHash, destHash: destHash,
            title: title, content: content, timestamp: timestamp,
            signatureValid: signatureValid, fieldsRaw: fieldsRaw
        )
    }

    private func handleIncomingMessage(hash: Data, srcHash: Data, destHash: Data,
                                        title: String, content: String, timestamp: Double,
                                        signatureValid: Bool, fieldsRaw: Data) {
        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let srcHexForLog = srcHash.hexString
        let msgHashHexForLog = hash.hexString
        print("[Retichat] handleIncomingMessage: hash=\(msgHashHexForLog.prefix(8)) src=\(srcHexForLog.prefix(8)) dest=\(destHash.hexString.prefix(8)) len=\(content.count)")
        guard let ctx = modelContext else {
            print("[Retichat] handleIncomingMessage: DROPPED - modelContext is nil")
            return
        }

        let srcHex = srcHash.hexString
        let msgHashHex = hash.hexString

        // Check for duplicate
        let dupDescriptor = FetchDescriptor<MessageEntity>(
            predicate: #Predicate { $0.id == msgHashHex }
        )
        if let existing = try? ctx.fetch(dupDescriptor), !existing.isEmpty {
            print("[Retichat] handleIncomingMessage: DROPPED duplicate \(msgHashHex.prefix(8))")
            return  // Already have this message
        }

        // Decode LXMF fields
        let fields = LxmfFieldsDecoder.decode(fieldsRaw)

        // Handle group message
        if let groupId = fields.groupId {
            // For invites: filter by sender; for other group actions: filter by known groupId
            let shouldProcess: Bool
            if fields.groupAction == GroupAction.invite {
                shouldProcess = isAllowlisted(destHash: srcHex)
            } else {
                shouldProcess = isAllowlisted(destHash: groupId)
            }
            if shouldProcess {
                handleGroupMessage(
                    hash: hash, srcHash: srcHash, content: content,
                    timestamp: timestamp, fields: fields, groupId: groupId
                )
            }
            return
        }

        // Filter: drop direct messages from senders not in the contact allowlist.
        // Do this before any DB writes so strangers consume no resources.
        guard isAllowlisted(destHash: srcHex) else {
            print("[Retichat] handleIncomingMessage: DROPPED filterStrangers=\(prefs.filterStrangers) src=\(srcHex.prefix(8))")
            return
        }
        print("[Retichat] handleIncomingMessage: ACCEPTED src=\(srcHex.prefix(8))")

        // Direct message — find or create chat
        let chatId = srcHex
        ensureChat(id: chatId, peerHash: srcHex)
        ensureContact(destHash: srcHex)

        // Watch for announces from this sender so their display name is received
        RetichatBridge.shared.watchAnnounce(destHash: srcHash)
        lxmfClient?.watch(destHash: srcHash)

        // Attempt to fill in the contact's display name from the Identity
        // announce cache right now (covers the case where their announce
        // arrived before they were added to the watch list).
        if let name = lxmfClient?.recallDisplayName(for: srcHash), !name.isEmpty {
            updateContactNameIfEmpty(destHash: srcHex, name: name)
        }

        // Insert message
        let msgEntity = MessageEntity(
            id: msgHashHex,
            chatId: chatId,
            senderHash: srcHex,
            content: content,
            title: title,
            timestamp: timestamp,
            isOutgoing: false,
            deliveryState: DeliveryState.delivered,
            signatureValid: signatureValid
        )
        ctx.insert(msgEntity)

        // Handle attachments from fields
        for (filename, data) in fields.attachments {
            let att = AttachmentEntity(
                id: UUID().uuidString,
                messageId: msgHashHex,
                filename: filename,
                data: data
            )
            ctx.insert(att)
        }

        // Update chat timestamp
        updateChatTimestamp(chatId: chatId, timestamp: timestamp)
        try? ctx.save()

        // Get sender name for notification
        let senderName = contactDisplayName(for: srcHex)
        notifManager.postMessageNotification(
            chatId: chatId, senderName: senderName, content: content
        )

        refreshChats()
    }

    private func handleGroupMessage(hash: Data, srcHash: Data, content: String,
                                     timestamp: Double, fields: LxmfFields, groupId: String) {
        let srcHex = srcHash.hexString
        let actualSender = fields.groupSender ?? srcHex
        let action = fields.groupAction  // nil = regular message

        switch action {
        case GroupAction.invite:
            handleGroupInvite(srcHex: srcHex, content: content, timestamp: timestamp,
                              fields: fields, groupId: groupId)
        case GroupAction.accept:
            handleGroupAccept(memberHex: actualSender, groupId: groupId)
        case GroupAction.leave:
            handleGroupLeave(memberHex: actualSender, groupId: groupId,
                             timestamp: timestamp, msgId: hash.hexString)
        case GroupAction.relayRequest:
            handleGroupRelayRequest(srcHex: srcHex, content: content,
                                    fields: fields, groupId: groupId)
        case GroupAction.relayDone:
            print("[GroupChat] relay-done from \(srcHex.prefix(8)) for group \(groupId.prefix(8))")
        default:
            // Regular group message
            handleGroupChatMessage(hash: hash, srcHash: srcHash, content: content,
                                   timestamp: timestamp, fields: fields, groupId: groupId)
        }
    }

    /// Incoming invite to join a group.
    private func handleGroupInvite(
        srcHex: String, content: String, timestamp: Double,
        fields: LxmfFields, groupId: String
    ) {
        // Apply stranger filter to the inviting node
        guard isAllowlisted(destHash: srcHex) else {
            print("[GroupChat] Dropped invite from stranger \(srcHex.prefix(8))")
            return
        }

        guard let ctx = modelContext else { return }

        // Skip if we're already an active member of this group
        let chatDesc = FetchDescriptor<ChatEntity>(predicate: #Predicate { $0.id == groupId })
        if let existing = try? ctx.fetch(chatDesc).first, existing.groupStatus != "pending" {
            return
        }

        let memberList = fields.groupMembers ?? [srcHex]
        let groupName = fields.groupName ?? "Group"

        if (try? ctx.fetch(chatDesc).first) == nil {
            // Create a pending chat entry
            let chat = ChatEntity(
                id: groupId, peerHash: srcHex, isGroup: true,
                groupName: groupName, groupStatus: "pending"
            )
            ctx.insert(chat)

            // Populate member list from invite
            for memberHash in memberList {
                let member = GroupMemberEntity(groupId: groupId, memberHash: memberHash,
                                               inviteStatus: MemberStatus.invited)
                ctx.insert(member)
            }
        }

        // Add the inviting sender to our allowlist so we can reply
        ensureAllowlistedContact(destHash: srcHex)

        // Insert a system message representing the invite notification
        let inviteMsgId = "inv_\(groupId.prefix(16))"
        let dupDesc = FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.id == inviteMsgId })
        if (try? ctx.fetch(dupDesc).first) == nil {
            let msg = MessageEntity(
                id: inviteMsgId, chatId: groupId, senderHash: srcHex,
                content: "Group invite from \(contactDisplayName(for: srcHex)): \"\(groupName)\"",
                timestamp: timestamp, isOutgoing: false, deliveryState: DeliveryState.delivered
            )
            ctx.insert(msg)
        }

        updateChatTimestamp(chatId: groupId, timestamp: timestamp)
        try? ctx.save()

        notifManager.postMessageNotification(
            chatId: groupId,
            senderName: contactDisplayName(for: srcHex),
            content: "Group invite: \"\(groupName)\" — tap to accept or decline"
        )
        refreshChats()
    }

    /// Another member accepted the group invite — update their status.
    private func handleGroupAccept(memberHex: String, groupId: String) {
        guard let ctx = modelContext else { return }
        let memberDesc = FetchDescriptor<GroupMemberEntity>(
            predicate: #Predicate { $0.groupId == groupId && $0.memberHash == memberHex }
        )
        if let entry = try? ctx.fetch(memberDesc).first {
            entry.inviteStatus = MemberStatus.accepted
        } else {
            // Member not in our list yet (can happen if invite processing was partial)
            ctx.insert(GroupMemberEntity(groupId: groupId, memberHash: memberHex,
                                          inviteStatus: MemberStatus.accepted))
        }
        // Add this newly confirmed member to our allowlist and watchlist
        ensureAllowlistedContact(destHash: memberHex)
        if let hashData = Data(hexString: memberHex) {
            RetichatBridge.shared.watchAnnounce(destHash: hashData)
        }

        // Insert a system message so the group timeline shows who joined
        let sysId = "acc_\(memberHex.prefix(8))_\(groupId.prefix(8))"
        let dupDesc = FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.id == sysId })
        if (try? ctx.fetch(dupDesc).first) == nil {
            let msg = MessageEntity(
                id: sysId, chatId: groupId, senderHash: memberHex,
                content: "\(contactDisplayName(for: memberHex)) joined the group",
                timestamp: Date().timeIntervalSince1970,
                isOutgoing: false, deliveryState: DeliveryState.delivered
            )
            ctx.insert(msg)
        }

        try? ctx.save()
        refreshChats()
    }

    /// A member left the group — update their status and show a system message.
    private func handleGroupLeave(
        memberHex: String, groupId: String, timestamp: Double, msgId: String
    ) {
        guard let ctx = modelContext else { return }
        let memberDesc = FetchDescriptor<GroupMemberEntity>(
            predicate: #Predicate { $0.groupId == groupId && $0.memberHash == memberHex }
        )
        if let entry = try? ctx.fetch(memberDesc).first {
            entry.inviteStatus = MemberStatus.left
            if let hashData = Data(hexString: memberHex) {
                RetichatBridge.shared.unwatchAnnounce(destHash: hashData)
            }
        }
        let dupDesc = FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.id == msgId })
        if (try? ctx.fetch(dupDesc).first) == nil {
            let msg = MessageEntity(
                id: msgId, chatId: groupId, senderHash: memberHex,
                content: "\(contactDisplayName(for: memberHex)) left the group",
                timestamp: timestamp, isOutgoing: false, deliveryState: DeliveryState.delivered
            )
            ctx.insert(msg)
        }
        updateChatTimestamp(chatId: groupId, timestamp: timestamp)
        try? ctx.save()
        refreshChats()
    }

    /// Another member is asking us to relay their message.
    private func handleGroupRelayRequest(
        srcHex: String, content: String, fields: LxmfFields, groupId: String
    ) {
        guard let ctx = modelContext, let client = lxmfClient else { return }
        let originalSender = fields.groupSender ?? srcHex
        let alreadySeen = fields.groupRelaySeen ?? []

        // Gather all accepted members
        let accepted = (groupMembersWithStatus(groupId: groupId) ?? [])
            .filter { $0.inviteStatus == MemberStatus.accepted }
            .map { $0.memberHash }

        let chatDesc = FetchDescriptor<ChatEntity>(predicate: #Predicate { $0.id == groupId })
        let groupName = (try? ctx.fetch(chatDesc).first)?.groupName ?? "Group"

        let selfHash = ownHashHex
        ffiQueue.async {
            GroupChatManager.shared.performRelay(
                groupId: groupId,
                groupName: groupName,
                content: content,
                originalSender: originalSender,
                alreadySeen: alreadySeen,
                requester: srcHex,
                allAcceptedMembers: accepted,
                selfHash: selfHash,
                via: client
            )
        }
    }

    /// Regular group content message.
    private func handleGroupChatMessage(
        hash: Data, srcHash: Data, content: String, timestamp: Double,
        fields: LxmfFields, groupId: String
    ) {
        guard let ctx = modelContext else { return }

        let srcHex = srcHash.hexString
        let msgHashHex = hash.hexString
        let actualSender = fields.groupSender ?? srcHex

        // Only accept messages for groups we actively belong to
        let chatDesc = FetchDescriptor<ChatEntity>(predicate: #Predicate { $0.id == groupId })
        guard let chat = try? ctx.fetch(chatDesc).first,
              chat.groupStatus != "pending" else {
            print("[GroupChat] Dropped msg for unknown/pending group \(groupId.prefix(8))")
            return
        }

        // Dedup
        let dupDesc = FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.id == msgHashHex })
        if let _ = try? ctx.fetch(dupDesc).first { return }

        // Ensure the group chat exists locally (handles the incoming group name update)
        if let groupName = fields.groupName, let existingChat = try? ctx.fetch(chatDesc).first {
            if existingChat.groupName == nil { existingChat.groupName = groupName }
        }

        let msg = MessageEntity(
            id: msgHashHex, chatId: groupId, senderHash: actualSender,
            content: content, timestamp: timestamp,
            isOutgoing: actualSender == ownHashHex,
            deliveryState: DeliveryState.delivered
        )
        ctx.insert(msg)

        for (filename, data) in fields.attachments {
            ctx.insert(AttachmentEntity(
                id: UUID().uuidString, messageId: msgHashHex, filename: filename, data: data
            ))
        }

        updateChatTimestamp(chatId: groupId, timestamp: timestamp)
        try? ctx.save()

        if actualSender != ownHashHex {
            let senderName = contactDisplayName(for: actualSender)
            let groupName = chat.groupName ?? "Group"
            notifManager.postMessageNotification(
                chatId: groupId,
                senderName: "\(senderName) (\(groupName))",
                content: content
            )
        }

        refreshChats()
    }

    // MARK: - AnnounceCallback

    @MainActor func onAnnounce(destHash: Data, displayName: String?) {
        handleAnnounce(destHash: destHash, displayName: displayName)
    }

    private func handleAnnounce(destHash: Data, displayName: String?) {
        // Track announce for reachability and link-degradation recovery.
        ConnectionStateManager.shared.didReceiveAnnounce(destHash: destHash)

        guard let ctx = modelContext else { return }
        let hex = destHash.hexString

        let descriptor = FetchDescriptor<ContactEntity>(
            predicate: #Predicate { $0.destHash == hex }
        )
        if let contact = try? ctx.fetch(descriptor).first {
            // Only update displayName if the contact has no name yet (preserves user renames)
            if let name = displayName, !name.isEmpty, contact.displayName.isEmpty {
                contact.displayName = name
            }
            contact.lastSeen = Date().timeIntervalSince1970
            try? ctx.save()
            scheduleRefreshChats()  // debounced: coalesces announce bursts
        } else if let name = displayName, !name.isEmpty, !prefs.filterStrangers {
            // Only auto-create a contact stub from announces when the stranger
            // filter is off — otherwise we'd be storing data for unknown senders.
            let contact = ContactEntity(
                destHash: hex,
                displayName: name,
                lastSeen: Date().timeIntervalSince1970
            )
            ctx.insert(contact)
            try? ctx.save()
        }
    }

    // MARK: - Chat management

    func createDirectChat(destHash: String) -> String {
        // Unarchive if the chat already exists but was archived
        if let ctx = modelContext {
            let descriptor = FetchDescriptor<ChatEntity>(
                predicate: #Predicate { $0.id == destHash }
            )
            if let existing = try? ctx.fetch(descriptor).first, existing.isArchived {
                existing.isArchived = false
                try? ctx.save()
            }
        }

        ensureChat(id: destHash, peerHash: destHash)
        ensureAllowlistedContact(destHash: destHash)

        // Watch for announces
        if let hashData = Data(hexString: destHash) {
            RetichatBridge.shared.watchAnnounce(destHash: hashData)
            lxmfClient?.watch(destHash: hashData)
        }

        refreshChats()
        return destHash
    }

    func createGroupChat(name: String, memberHashes: [String]) -> String {
        guard let ctx = modelContext else { return "" }

        // Generate a 16-byte random group ID → 32-char hex string (Android-compatible)
        var randomBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &randomBytes)
        let groupId = randomBytes.map { String(format: "%02x", $0) }.joined()

        let nowMs = Date().timeIntervalSince1970 * 1000
        let chat = ChatEntity(
            id: groupId, peerHash: "", lastMessageTime: nowMs,
            isGroup: true, groupName: name, groupStatus: "active"
        )
        ctx.insert(chat)

        // Add all members, including self
        var allMembers = memberHashes
        if !allMembers.contains(ownHashHex) {
            allMembers.append(ownHashHex)
        }
        for memberHash in allMembers {
            let status = memberHash == ownHashHex ? MemberStatus.accepted : MemberStatus.invited
            let member = GroupMemberEntity(groupId: groupId, memberHash: memberHash,
                                           inviteStatus: status)
            ctx.insert(member)
            ensureAllowlistedContact(destHash: memberHash)
            if memberHash != ownHashHex, let hashData = Data(hexString: memberHash) {
                RetichatBridge.shared.watchAnnounce(destHash: hashData)
            }
        }
        // Allowlist the group ID so inbound group messages pass the filter
        ensureAllowlistedContact(destHash: groupId)

        try? ctx.save()

        // Send invites to everyone except self (fire-and-forget)
        if let client = lxmfClient {
            let selfHash = ownHashHex
            ffiQueue.async {
                GroupChatManager.shared.sendInvites(
                    groupId: groupId,
                    groupName: name,
                    allMembers: allMembers,
                    from: selfHash,
                    via: client
                )
            }
        }

        refreshChats()
        return groupId
    }

    func archiveChat(chatId: String) {
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<ChatEntity>(
            predicate: #Predicate { $0.id == chatId }
        )
        if let chat = try? ctx.fetch(descriptor).first {
            if !chat.isGroup, let hashData = Data(hexString: chat.peerHash) {
                RetichatBridge.shared.unwatchAnnounce(destHash: hashData)
            } else if chat.isGroup {
                let memberDesc = FetchDescriptor<GroupMemberEntity>(
                    predicate: #Predicate { $0.groupId == chatId }
                )
                for member in (try? ctx.fetch(memberDesc)) ?? [] where member.memberHash != ownHashHex {
                    if let hashData = Data(hexString: member.memberHash) {
                        RetichatBridge.shared.unwatchAnnounce(destHash: hashData)
                    }
                }
            }
            chat.isArchived = true
            try? ctx.save()
            refreshChats()
        }
    }

    /// Permanently delete a chat and all its messages and attachments.
    func deleteChat(chatId: String) {
        guard let ctx = modelContext else { return }

        // Remove from transport announce watchlist before deleting the entity.
        let chatLookup = FetchDescriptor<ChatEntity>(predicate: #Predicate { $0.id == chatId })
        if let chat = try? ctx.fetch(chatLookup).first {
            if !chat.isGroup, let hashData = Data(hexString: chat.peerHash) {
                RetichatBridge.shared.unwatchAnnounce(destHash: hashData)
            } else if chat.isGroup {
                let memberDesc = FetchDescriptor<GroupMemberEntity>(
                    predicate: #Predicate { $0.groupId == chatId }
                )
                for member in (try? ctx.fetch(memberDesc)) ?? [] where member.memberHash != ownHashHex {
                    if let hashData = Data(hexString: member.memberHash) {
                        RetichatBridge.shared.unwatchAnnounce(destHash: hashData)
                    }
                }
            }
        }

        // Delete all attachments for messages in this chat
        let attDescriptor = FetchDescriptor<AttachmentEntity>(
            predicate: #Predicate { $0.messageId != "" }  // fetch all; filter below
        )
        // Fetch messages first so we have their IDs
        let msgDescriptor = FetchDescriptor<MessageEntity>(
            predicate: #Predicate { $0.chatId == chatId }
        )
        if let messages = try? ctx.fetch(msgDescriptor) {
            let msgIds = Set(messages.map { $0.id })
            if let atts = try? ctx.fetch(attDescriptor) {
                for att in atts where msgIds.contains(att.messageId) {
                    ctx.delete(att)
                }
            }
            for msg in messages {
                ctx.delete(msg)
            }
        }

        // Delete group members if applicable
        let memberDescriptor = FetchDescriptor<GroupMemberEntity>(
            predicate: #Predicate { $0.groupId == chatId }
        )
        if let members = try? ctx.fetch(memberDescriptor) {
            for member in members { ctx.delete(member) }
        }

        // Delete the chat entity
        let chatDescriptor = FetchDescriptor<ChatEntity>(
            predicate: #Predicate { $0.id == chatId }
        )
        if let chat = try? ctx.fetch(chatDescriptor).first {
            ctx.delete(chat)
        }

        try? ctx.save()
        refreshChats()
    }

    /// Search across both active and archived chats. Used when the user types
    /// in the search bar so archived chats are discoverable.
    func searchAllChats(query: String) -> [Chat] {
        guard let ctx = modelContext else { return [] }
        let lower = query.lowercased()

        let descriptor = FetchDescriptor<ChatEntity>(
            sortBy: [SortDescriptor(\.lastMessageTime, order: .reverse)]
        )
        guard let entities = try? ctx.fetch(descriptor) else { return [] }

        let nameCache = batchContactDisplayNames(
            hashes: Set(entities.compactMap { $0.isGroup ? nil : $0.peerHash })
        )

        return entities.compactMap { entity -> Chat? in
            let displayName: String
            if entity.isGroup {
                displayName = entity.groupName ?? "Group"
            } else {
                displayName = nameCache[entity.peerHash] ?? shortHash(entity.peerHash)
            }
            guard displayName.localizedCaseInsensitiveContains(lower) ||
                  entity.peerHash.localizedCaseInsensitiveContains(lower) else { return nil }

            let lastMsg = lastMessage(forChatId: entity.id)
            return Chat(
                id: entity.id,
                peerHash: entity.peerHash,
                displayName: displayName,
                lastMessage: lastMsg?.content ?? "",
                lastMessageTime: entity.lastMessageTime,
                unreadCount: 0,
                isArchived: entity.isArchived,
                isGroup: entity.isGroup,
                groupName: entity.groupName,
                groupStatus: entity.groupStatus
            )
        }
    }

    // MARK: - Data queries

    func messages(forChatId chatId: String, limit: Int = 50, offset: Int = 0) -> [ChatMessage] {
        guard let ctx = modelContext else { return [] }

        var descriptor = FetchDescriptor<MessageEntity>(
            predicate: #Predicate { $0.chatId == chatId },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset

        guard let entities = try? ctx.fetch(descriptor) else { return [] }

        // Batch-fetch attachments for these messages using Array.contains
        // (SwiftData translates this to SQL IN (...) — much faster than
        //  fetching ALL blobs and filtering in memory)
        let messageIds = entities.map { $0.id }
        let attDescriptor = FetchDescriptor<AttachmentEntity>(
            predicate: #Predicate<AttachmentEntity> { att in
                messageIds.contains(att.messageId)
            }
        )
        let allAttachments = (try? ctx.fetch(attDescriptor)) ?? []
        var attachmentsByMsg: [String: [Attachment]] = [:]
        for att in allAttachments {
            let a = Attachment(id: att.id, filename: att.filename, data: att.data, mimeType: att.mimeType)
            attachmentsByMsg[att.messageId, default: []].append(a)
        }

        // Batch-fetch contact display names
        let senderHashes = Set(entities.map { $0.senderHash })
        let nameCache = batchContactDisplayNames(hashes: senderHashes)

        // Reverse back to chronological order for display
        return entities.reversed().map { entity in
            let attachments = attachmentsByMsg[entity.id] ?? []
            var progress: Float? = nil
            if entity.isOutgoing && entity.nativeHandle != 0 && !attachments.isEmpty
               && entity.deliveryState != DeliveryState.delivered
               && entity.deliveryState != DeliveryState.failed {
                let p = LxmfClient.messageProgress(entity.nativeHandle)
                if p >= 0 && p < 1.0 {
                    progress = p
                }
            }
            return ChatMessage(
                id: entity.id,
                senderHash: entity.senderHash,
                senderName: nameCache[entity.senderHash] ?? shortHash(entity.senderHash),
                content: entity.content,
                timestamp: entity.timestamp,
                isOutgoing: entity.isOutgoing,
                deliveryState: entity.deliveryState,
                attachments: attachments,
                uploadProgress: progress,
                nativeHandle: entity.nativeHandle
            )
        }
    }

    /// Lightweight query returning only (id, deliveryState) pairs — no
    /// attachment blobs, no FFI calls.  Used by the refresh timer to decide
    /// whether a full reload is needed.
    func messagesSummary(forChatId chatId: String, limit: Int = 50) -> [(String, Int)] {
        guard let ctx = modelContext else { return [] }
        var descriptor = FetchDescriptor<MessageEntity>(
            predicate: #Predicate { $0.chatId == chatId },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        guard let entities = try? ctx.fetch(descriptor) else { return [] }
        return entities.reversed().map { ($0.id, $0.deliveryState) }
    }

    func contacts() -> [Contact] {
        guard let ctx = modelContext else { return [] }
        let descriptor = FetchDescriptor<ContactEntity>(
            sortBy: [SortDescriptor(\.displayName)]
        )
        guard let entities = try? ctx.fetch(descriptor) else { return [] }
        // Only surface contacts the user explicitly added (allowlisted)
        return entities
            .filter { $0.isAllowlisted == true }
            .map { Contact(id: $0.destHash, displayName: $0.displayName, lastSeen: $0.lastSeen) }
    }

    /// Remove a contact from the allowlist.  The ContactEntity is deleted
    /// entirely; any matching chat is NOT automatically archived so the user
    /// can still see the conversation history.
    func removeContact(destHash: String) {
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<ContactEntity>(
            predicate: #Predicate { $0.destHash == destHash }
        )
        if let contact = try? ctx.fetch(descriptor).first {
            ctx.delete(contact)
            try? ctx.save()
        }
    }

    func refreshChats() {
        guard let ctx = modelContext else { return }

        let descriptor = FetchDescriptor<ChatEntity>(
            predicate: #Predicate { $0.isArchived == false },
            sortBy: [SortDescriptor(\.lastMessageTime, order: .reverse)]
        )

        guard let chatEntities = try? ctx.fetch(descriptor) else { return }

        // Batch-fetch the latest message per chat in ONE query instead of N
        let chatIds = chatEntities.map { $0.id }
        var lastMsgByChat: [String: MessageEntity] = [:]
        if !chatIds.isEmpty {
            // Fetch the most recent messages; we only need the newest per chat
            var msgDesc = FetchDescriptor<MessageEntity>(
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            )
            // Reasonable limit: one msg per chat × 2 margin
            msgDesc.fetchLimit = chatIds.count * 2
            if let msgs = try? ctx.fetch(msgDesc) {
                let idSet = Set(chatIds)
                for m in msgs where idSet.contains(m.chatId) {
                    if lastMsgByChat[m.chatId] == nil {
                        lastMsgByChat[m.chatId] = m
                    }
                }
            }
        }

        // Batch-fetch contact display names for non-group chats
        let peerHashes = Set(chatEntities.compactMap { $0.isGroup ? nil : $0.peerHash })
        let nameCache = batchContactDisplayNames(hashes: peerHashes)

        chats = chatEntities.map { entity in
            let lastMsg = lastMsgByChat[entity.id]
            let displayName: String
            if entity.isGroup {
                displayName = entity.groupName ?? "Group"
            } else {
                displayName = nameCache[entity.peerHash] ?? shortHash(entity.peerHash)
            }

            return Chat(
                id: entity.id,
                peerHash: entity.peerHash,
                displayName: displayName,
                lastMessage: lastMsg?.content ?? "",
                lastMessageTime: entity.lastMessageTime,
                unreadCount: 0,
                isArchived: entity.isArchived,
                isGroup: entity.isGroup,
                groupName: entity.groupName,
                groupStatus: entity.groupStatus
            )
        }

        // Sync chat names to App Group so the NSE can use them in notification titles.
        // Do this off the main actor — it's file I/O and not time-critical for UI.
        var chatNameMap: [String: String] = [:]
        for chat in chats where !chat.displayName.isEmpty {
            chatNameMap[chat.peerHash] = chat.displayName
        }
        let snapshot = chatNameMap
        Task.detached(priority: .utility) {
            PendingNotification.writeChatNames(snapshot)
        }
    }

    // MARK: - Helpers

    /// Debounced refresh: coalesces rapid back-to-back calls (e.g. announce bursts,
    /// delivery proofs) into a single SwiftData query + SwiftUI publish after 50 ms.
    /// User-action paths (sendMessage, createChat, etc.) call refreshChats() directly
    /// for immediate feedback.
    private var pendingRefresh = false

    private func scheduleRefreshChats() {
        guard !pendingRefresh else { return }
        pendingRefresh = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50 ms window
            self?.pendingRefresh = false
            self?.refreshChats()
        }
    }

    private func ensureChat(id: String, peerHash: String, isGroup: Bool = false, groupName: String? = nil) {
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<ChatEntity>(
            predicate: #Predicate { $0.id == id }
        )
        if let existing = try? ctx.fetch(descriptor), existing.isEmpty {
            let nowMs = Date().timeIntervalSince1970 * 1000
            let chat = ChatEntity(
                id: id, peerHash: peerHash, lastMessageTime: nowMs,
                isGroup: isGroup, groupName: groupName
            )
            ctx.insert(chat)
            try? ctx.save()
        }
    }

    private func ensureContact(destHash: String) {
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<ContactEntity>(
            predicate: #Predicate { $0.destHash == destHash }
        )
        if let existing = try? ctx.fetch(descriptor), existing.isEmpty {
            let contact = ContactEntity(destHash: destHash)
            ctx.insert(contact)
            try? ctx.save()
        }
    }

    /// Mark an existing contact as allowlisted, or create an allowlisted one if absent.
    private func ensureAllowlistedContact(destHash: String) {
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<ContactEntity>(
            predicate: #Predicate { $0.destHash == destHash }
        )
        if let contact = try? ctx.fetch(descriptor).first {
            if contact.isAllowlisted != true {
                contact.isAllowlisted = true
                try? ctx.save()
            }
        } else {
            let contact = ContactEntity(destHash: destHash, isAllowlisted: true)
            ctx.insert(contact)
            try? ctx.save()
        }
    }

    /// Returns true if the given hash is in the contact allowlist.
    private func isAllowlisted(destHash: String) -> Bool {
        guard prefs.filterStrangers else { return true }  // filter off → allow all
        guard let ctx = modelContext else { return false }
        let descriptor = FetchDescriptor<ContactEntity>(
            predicate: #Predicate { $0.destHash == destHash }
        )
        return (try? ctx.fetch(descriptor).first?.isAllowlisted) == true
    }

    func contactDisplayName(for destHash: String) -> String {
        if destHash == ownHashHex { return "You" }
        guard let ctx = modelContext else { return shortHash(destHash) }
        let descriptor = FetchDescriptor<ContactEntity>(
            predicate: #Predicate { $0.destHash == destHash }
        )
        if let contact = try? ctx.fetch(descriptor).first, !contact.displayName.isEmpty {
            return contact.displayName
        }
        return shortHash(destHash)
    }

    /// Batch-fetch display names for a set of hashes in one SwiftData query.
    private func batchContactDisplayNames(hashes: Set<String>) -> [String: String] {
        var result: [String: String] = [:]
        for h in hashes where h == ownHashHex { result[h] = "You" }
        guard let ctx = modelContext else {
            for h in hashes where result[h] == nil { result[h] = shortHash(h) }
            return result
        }
        // Fetch all contacts (typically <100) and filter in-memory
        let descriptor = FetchDescriptor<ContactEntity>()
        if let contacts = try? ctx.fetch(descriptor) {
            for c in contacts where hashes.contains(c.destHash) && !c.displayName.isEmpty {
                result[c.destHash] = c.displayName
            }
        }
        for h in hashes where result[h] == nil { result[h] = shortHash(h) }
        return result
    }

    func renameContact(destHash: String, newName: String) {
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<ContactEntity>(
            predicate: #Predicate { $0.destHash == destHash }
        )
        if let contact = try? ctx.fetch(descriptor).first {
            contact.displayName = newName
            try? ctx.save()
            refreshChats()
        }
    }

    func renameGroup(chatId: String, newName: String) {
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<ChatEntity>(
            predicate: #Predicate { $0.id == chatId }
        )
        if let chat = try? ctx.fetch(descriptor).first {
            chat.groupName = newName
            try? ctx.save()
            refreshChats()
        }
    }

    /// Set the contact's display name only when it is currently empty.
    /// Preserves any name the user has entered manually.
    private func updateContactNameIfEmpty(destHash: String, name: String) {
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<ContactEntity>(
            predicate: #Predicate { $0.destHash == destHash }
        )
        if let contact = try? ctx.fetch(descriptor).first, contact.displayName.isEmpty {
            contact.displayName = name
            try? ctx.save()
        }
    }

    private func shortHash(_ hex: String) -> String {
        String(hex.prefix(8)) + "…"
    }

    private func updateChatTimestamp(chatId: String, timestamp: Double) {
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<ChatEntity>(
            predicate: #Predicate { $0.id == chatId }
        )
        if let chat = try? ctx.fetch(descriptor).first {
            chat.lastMessageTime = max(chat.lastMessageTime, timestamp)
        }
    }

    private func lastMessage(forChatId chatId: String) -> MessageEntity? {
        guard let ctx = modelContext else { return nil }
        var descriptor = FetchDescriptor<MessageEntity>(
            predicate: #Predicate { $0.chatId == chatId },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? ctx.fetch(descriptor).first
    }

    private func unreadCount(forChatId chatId: String) -> Int {
        guard modelContext != nil else { return 0 }
        // Simple heuristic: count recent inbound messages
        // TODO: Track read state properly
        return 0
    }

    private func fetchAttachments(messageId: String) -> [Attachment] {
        guard let ctx = modelContext else { return [] }
        let descriptor = FetchDescriptor<AttachmentEntity>(
            predicate: #Predicate { $0.messageId == messageId }
        )
        guard let entities = try? ctx.fetch(descriptor) else { return [] }
        return entities.map {
            Attachment(id: $0.id, filename: $0.filename, data: $0.data, mimeType: $0.mimeType)
        }
    }

    func groupMembers(groupId: String) -> [String]? {
        guard let ctx = modelContext else { return nil }
        let descriptor = FetchDescriptor<GroupMemberEntity>(
            predicate: #Predicate { $0.groupId == groupId }
        )
        guard let members = try? ctx.fetch(descriptor) else { return nil }
        return members.map { $0.memberHash }
    }

    /// Returns full `GroupMemberEntity` objects so callers can inspect status.
    func groupMembersWithStatus(groupId: String) -> [GroupMemberEntity]? {
        guard let ctx = modelContext else { return nil }
        let descriptor = FetchDescriptor<GroupMemberEntity>(
            predicate: #Predicate { $0.groupId == groupId }
        )
        return try? ctx.fetch(descriptor)
    }

    // MARK: - Interface management

    func interfaces() -> [InterfaceConfigEntity] {
        guard let ctx = modelContext else { return [] }
        let descriptor = FetchDescriptor<InterfaceConfigEntity>()
        return (try? ctx.fetch(descriptor)) ?? []
    }

    func addInterface(_ iface: InterfaceConfigEntity) {
        guard let ctx = modelContext else { return }
        ctx.insert(iface)
        try? ctx.save()
    }

    func deleteInterface(id: String) {
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<InterfaceConfigEntity>(
            predicate: #Predicate { $0.id == id }
        )
        if let iface = try? ctx.fetch(descriptor).first {
            // If this was a running RNode interface, drop the BLE link and
            // deregister the Rust handle before removing the row \u2014 otherwise
            // the coordinator would keep retrying a deleted row, and the Rust
            // side would hold a callback context for a peripheral we no
            // longer track.
            if iface.type == InterfaceKind.rnode.rawValue {
                RNodeInterfaceCoordinator.shared.stopSlot(id: id)
            }
            ctx.delete(iface)
            try? ctx.save()
        }
    }

    // MARK: - Announce

    func announce() {
        guard let client = lxmfClient else { return }
        ffiQueue.async {
            client.announce()
        }
    }
}
