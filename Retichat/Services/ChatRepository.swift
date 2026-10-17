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
import UIKit

/// This device's own identity, for the Identity screen.
struct DeviceIdentityInfo: Equatable {
    let deliveryHashHex: String
    let identityHashHex: String
    /// 128 hex; empty if the Rust side could not return the key.
    let publicKeyHex: String
    var contactUri: String? {
        IdentityShareFormat.encode(destinationHashHex: deliveryHashHex,
                                   publicKey: Data(hexString: publicKeyHex))
    }
}

@MainActor
final class ChatRepository: ObservableObject, MessageCallback, AnnounceCallback, MessageStateCallback {
    // MARK: - Published state

    @Published var chats: [Chat] = []
    @Published var serviceRunning = false
    @Published var ownHashHex: String = ""
    @Published var statusMessage: String = "Idle"
    /// True only after the last start attempt failed (finishStartService's
    /// .failure branch); reset by startService(). Lets the chat-list status
    /// line show "Error" as Android does (ChatListScreen.kt:116-135).
    @Published private(set) var serviceStartFailed = false
    /// Bumped whenever a contact's name slots change (DISPLAY_NAMES.md §5):
    /// open conversations reload their bubbles and header on it, so a name
    /// that arrives while a chat is on screen shows at once.
    @Published private(set) var namesVersion = 0

    // MARK: - Handles

    private(set) var lxmfClient: LxmfClient?
    private(set) var ownHash: Data = Data()

    // MARK: - Dependencies

    private let bridge = RetichatBridge.shared
    private let prefs = UserPreferences.shared
    private let propManager = PropagationNodeManager.shared
    private let notifManager = NotificationManager.shared

    private var modelContext: ModelContext?
    /// RfedDistroClient.$distro, for GROUPS-DISTRO-DESIGN.md §8.7 (configure).
    private var distroHeldWatch: AnyCancellable?
    /// RfedDistroClient.$distroSettled and $storedKeyUnreadable, for §8.7 (configure).
    private var distroSettledWatch: AnyCancellable?
    /// $serviceRunning: what a group offers follows the start (§8.7, configure).
    private var startWatch: AnyCancellable?
    /// The privacy filter's switch (UserPreferences.filterStrangersChanged): the NSE's group file
    /// is written again when it changes (GROUPS-DISTRO-DESIGN.md §6.7).
    private var filterWatch: AnyCancellable?
    private var pollTimer: Timer?
    private var serviceStarting = false

    /// Member statuses and keys (RFed-spec Group.md, 2026-10-06): what an accept or leave is
    /// worth by its signature, what it changes, the creator's copies and its `status` answer,
    /// and the entries held for a key. See GroupStatuses.swift: the decisions are the engine's,
    /// the storage SwiftData's (GroupStatusStore.swift), the checks the glue crate's.
    private lazy var groupStatuses = GroupStatusEngine(
        store: SwiftDataGroupStatusStore(
            context: { [weak self] in self?.modelContext },
            allowMember: { [weak self] in self?.ensureAllowlistedContact(destHash: $0) },
            watchMember: { member, watch in
                guard let hashData = Data(hexString: member) else { return }
                if watch { RetichatBridge.shared.watchAnnounce(destHash: hashData) }
                else { RetichatBridge.shared.unwatchAnnounce(destHash: hashData) }
            },
            line: { [weak self] chatId, member, joined, id, timestamp in
                self?.insertGroupMemberLine(chatId: chatId, memberHex: member, joined: joined,
                                            id: id, timestamp: timestamp)
            }),
        native: FFIGroupNative(bridge: RetichatBridge.shared),
        // Who "me" is in each group (GROUPS-DISTRO-DESIGN.md §9.1): the device, and in a group
        // listing the user's distro D, D and its known siblings.
        isSelf: { [weak self] chatId, hex in self?.isGroupSelf(chatId: chatId, hex: hex) ?? false },
        answer: { [weak self] chat, member, statuses in
            // The creator's answer: one status to that member, fire and forget (FFI off the main
            // thread), once per accept: nothing sends it again. As the group's own address
            // (groupSigner): a creator that is D answers as D, from every device of D (§12.1);
            // with no signer for it here (D not held, §8.7) nothing is sent.
            guard let self, let client = self.lxmfClient else {
                print("[GroupChat] status for \(chat.id.prefix(8)) to \(member.prefix(8)) not sent: stack offline")
                return
            }
            // A self address is never a send target, a status included (§9.2).
            guard !self.isGroupSelf(chatId: chat.id, hex: member) else {
                print("[GroupChat] status for \(chat.id.prefix(8)) to \(member.prefix(8)) not sent: it is one of the user's own addresses (§9.2)")
                return
            }
            guard let signer = self.groupSigner(chatId: chat.id) else {
                print("[GroupChat] status for \(chat.id.prefix(8)) to \(member.prefix(8)) not sent: no signer for the group's own address here (§8.7)")
                return
            }
            let groupId = chat.id
            self.ffiQueue.async {
                GroupChatManager.shared.sendStatus(groupId: groupId, to: member, statuses: statuses,
                                                   as: signer, via: client)
            }
        },
        log: { print("[GroupChat] \($0)") })

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
    // no attempt is left to hear from (delivered, sent-to-prop, or failed).
    // The message_state_callback from Rust drives all state transitions.
    // One entry per message: the propagated copy is a clone with the same
    // hash, so it reports under the entry of the DIRECT attempt it follows.

    private struct PendingOutbound {
        let messageId: String      // DB record primary key (= msg hash hex)
        let chatId: String
        let peerHash: Data
        /// The first attempt's handle. The propagated copy is cloned from
        /// it, so it is released only when the message completes.
        let msgHandle: UInt64
        /// Attempts in flight and whether the copy has started.
        var attempts: OutboundAttempts
    }

    private var pendingOutbound: [String: PendingOutbound] = [:]

    /// Message-state callbacks can arrive before the send-registration hop
    /// stores `pendingOutbound[hash]`, especially when Timer P collapses to
    /// zero for an already-disconnected AppLink. Buffer and replay them once
    /// registration completes so fallback ordering stays deterministic.
    private var earlyMessageStates: [String: [UInt8]] = [:]

    /// Hashes of messages that completed, newest last, bounded. The other
    /// attempt of a message that completed (the copy's SENT or FAILED after
    /// the DIRECT attempt's DELIVERED) still reports under its hash; that is
    /// not an early state, and buffering it would keep it until stop.
    private var completedHashes: [String] = []
    private var completedHashSet: Set<String> = []
    private static let completedHashCapacity = 256

    /// A send made before the stack could carry it: everything the send path
    /// needs, plus the id of the bubble already in the chat so the release
    /// reuses it rather than inserting a second one.
    private enum HeldSend {
        case direct(chatId: String, destHashHex: String, destData: Data, content: String,
                    attachments: [(String, Data)], tempId: String, optimisticTimestamp: TimeInterval)
        case group(chatId: String, content: String, attachments: [(String, Data)], messageId: String)
    }

    /// Sends made while the stack is starting or stopped. Released in order
    /// by releaseHeldSends(), the last step of finishStartService; stopService
    /// closes the gate but keeps what is held. In memory only: a process
    /// death leaves the held bubbles pending.
    private var heldSends = HeldSends<HeldSend>()

    /// Chat-list preview per chat id: the id, content and sender of the
    /// chat's newest message as refreshChats() last saw it, content "" when
    /// the chat has none. The id and sender are kept so a system message's
    /// subject is named when the list is built (DisplayNames.systemText),
    /// not when the memo was filled.
    ///
    /// refreshChats() takes previews from a window of the newest messages
    /// across ALL chats; a chat outside it needs a `chatId == X` fetch, and
    /// MessageEntity has no index on chatId, so without this every refresh
    /// (each send/receive/announce burst) ran one full-table scan per quiet
    /// chat on the main actor.
    ///
    /// Invariant: a chat's newest message changes only when a message is
    /// inserted into that chat or one of its messages is deleted (a stored
    /// message's content, timestamp and chatId are never rewritten). An
    /// insert need NOT land in the window: inbound, NSE-imported, distro
    /// sent copies (§17.11) and group relays carry the sender's timestamp,
    /// which can be older than the whole window yet newer than the chat's
    /// last message. So every MessageEntity insert goes through
    /// insertMessage(_:into:) and every delete path drops the chat's entry.
    private var chatPreviewMemo: [String: (id: String, content: String, senderHash: String)] = [:]

    /// Announces handled per destination hash (handleAnnounce), so a
    /// lookup in the announce cache that an announce overtook is dropped
    /// (refreshAnnounceNameFromCache). In memory only: lookups do not
    /// outlive the process.
    private var announceGeneration: [String: Int] = [:]

    /// Destination tracked for the live rfed.propagation.stream APP_LINK.
    private var propagationStreamDest: Data?

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
        chatPreviewMemo.removeAll()  // describes the previous store, if any
        normalizeMillisecondChatTimes()
        remigrateContactNamesIfNeeded()
        GroupChatManager.shared.onTracked = { [weak self] hashHex in
            Task { @MainActor [weak self] in
                self?.replayBufferedMessageStatesIfNeeded(for: hashHex)
            }
        }
        // Distro fan-out lands here as a decoded message (Android
        // RfedDistroClient.handleBlob → ChatRepository.onDistroMessageReceived).
        RfedDistroClient.shared.onMessage = { [weak self] message in
            self?.handleDistroMessage(message)
        }
        // A sibling's sent copy (SPEC §17.11) lands here as an outgoing
        // message; RfedDistroClient has already dropped our own echo.
        RfedDistroClient.shared.onSentCopy = { [weak self] copy in
            self?.handleDistroSentCopy(copy)
        }
        // Groups for distro holders (GROUPS-DISTRO-DESIGN.md): a group message to the distro and
        // the group sync land here, never on the DM path (§6.4); the siblings that sign as the
        // distro are learned from every sync it signs (§9.1).
        RfedDistroClient.shared.onGroup = { [weak self] arrival in
            self?.handleDistroGroupArrival(arrival) ?? false
        }
        RfedDistroClient.shared.onGroupSync = { [weak self] arrival in
            self?.handleDistroGroupSync(arrival) ?? false
        }
        RfedDistroClient.shared.onSiblingSeen = { [weak self] by, distro in
            self?.learnSibling(by, of: distro)
        }
        // The distro held changed (loaded, forgotten, generated, imported): the arrivals held for
        // a distro given up are forgotten, its known siblings pruned (§6.5, §8.7), and the
        // groups' §8.7 state shown again.
        distroHeldWatch = RfedDistroClient.shared.$distro
            .map { $0?.deliveryHashHex }
            .removeDuplicates()
            .sink { [weak self] held in
                Task { @MainActor [weak self] in self?.onDistroHeldChanged(held) }
            }
        // The Keychain has said what this device holds, or a stored key will not load (§8.7):
        // a group whose distro was still being read is shown again, as one it acts in or as a
        // former distro, without waiting for the distro held to change (it does not, for a
        // device that holds none). As for a change of the distro held.
        distroSettledWatch = RfedDistroClient.shared.$distroSettled
            .combineLatest(RfedDistroClient.shared.$storedKeyUnreadable)
            .map { $0 || $1 }
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.onDistroHeldChanged(self.heldDistroHex)
                }
            }
        // The start finished or stopped (§8.7, James, 2026-10-11): until it finishes every
        // group's Accept, Decline, Leave and Delete are greyed; then each group shows what it
        // offers.
        startWatch = $serviceRunning
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleRefreshChats() }
            }
        // §6.7: nse_groups.json says whether the filter is on, and is written whenever the filter
        // changes (Settings is a sheet: no refresh follows its toggle), so a suspended app's NSE
        // never shows an invite the user has just chosen to filter.
        filterWatch = NotificationCenter.default.publisher(for: UserPreferences.filterStrangersChanged)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleNSEGroupsWrite() }
            }
        // Identity-transfer sends are tracked like group fan-out: replay any
        // state that arrived before the hash was tracked.
        DistroTransferTracker.shared.onTracked = { [weak self] hashHex in
            Task { @MainActor [weak self] in
                self?.replayBufferedMessageStatesIfNeeded(for: hashHex)
            }
        }
    }

    /// Chats created by ensureChat/createGroupChat before 2026-09-24 hold a
    /// millisecond lastMessageTime. Anything above 1e11 cannot be a
    /// seconds-epoch value (year 5138+), so it is milliseconds — the same
    /// rule RfedChannelClient applies to channel times.
    private func normalizeMillisecondChatTimes() {
        guard let ctx = modelContext,
              let chats = try? ctx.fetch(FetchDescriptor<ChatEntity>()) else { return }
        var fixed = 0
        for chat in chats where chat.lastMessageTime > 1e11 {
            chat.lastMessageTime /= 1000.0
            fixed += 1
        }
        if fixed > 0 {
            try? ctx.save()
            print("[Retichat] normalized \(fixed) chat time(s) from milliseconds to seconds")
        }
    }

    // MARK: - Service lifecycle

    func startService() {
        guard !serviceRunning, !serviceStarting else { return }
        serviceStarting = true
        serviceStartFailed = false

        print("[Retichat] v1.0 build 2 starting")

        statusMessage = "Starting…"

        let configDir = reticulumConfigDir()
        let needsFallbackEndpoints = enabledTCPClientInterfaces().isEmpty && prefs.defaultTcpEnabled

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
            messageDisplayName: prefs.messageDisplayName,
            logLevel: 4,
            stampCost: -1,
            // The NSE decrypts with the app's ratchets, from this directory.
            // The stack mirrors every write of the ratchet file there from
            // before the delivery destination can announce, so the rotation
            // of this run's first announce reaches the NSE as it happens
            // (Reticulum-rust PARITY-AUDIT-1.5.2.md A29).
            ratchetsMirrorDir: PendingNotification.nseRatchetsDir()
        )
        if config.ratchetsMirrorDir == nil {
            print("[Retichat] NSE ratchet directory unavailable: ratchets are not mirrored for the NSE")
        }

        // Heavy FFI call (TCP connect, transport init, ratchet load) runs off
        // the main thread so the UI stays responsive during startup.
        //
        // It runs on ffiQueue, behind any shutdown stopService() queued there.
        // The Rust stack is a process singleton: a start that overtakes the
        // previous shutdown fails with "Reticulum is already initialised",
        // which is what Settings → Apply hit once shutdown began tearing
        // links down (B31) and so took longer than the start's head start.
        let ffiQueueRef = ffiQueue
        let announceName = prefs.announceDisplayName
        Task.detached(priority: .userInitiated) { [weak self, config, idPath, configDir, storagePath, announceName] in
            let result: Result<LxmfClient, Error> = await withCheckedContinuation { cont in
                ffiQueueRef.async {
                    // The one copy of the ratchet files into the NSE's
                    // directory, before the stack starts: no stack runs, so
                    // nothing writes them meanwhile, and the NSE has every
                    // ratchet from before this run. From the start on the
                    // stack's mirror keeps the NSE's file current; a copy
                    // after the start could race it and put an older file
                    // over a newer mirror.
                    PendingNotification.syncRatchetsToAppGroup(from: storagePath)
                    let result = Result { try LxmfClient.start(config: config) }
                    // The Announce Display Name in the same ffiQueue turn as
                    // the start: Transport answers path requests for the
                    // delivery destination from its registration on, with
                    // the router's app_data (DISPLAY_NAMES.md §2.2). Step 7
                    // of finishStartService sets it again, with any change
                    // saved meanwhile.
                    if case .success(let client) = result, !client.setAnnounceDisplayName(announceName) {
                        print("[Retichat] Announce Display Name not set at start: \(LxmfClient.lastError ?? "unknown error")")
                    }
                    cont.resume(returning: result)
                }
            }

            // Persist the live path table before copying storage into the App
            // Group. (Ratchets are not copied here: see the copy before the
            // start, and the stack's mirror.)
            if case .success(let client) = result {
                client.persist()
            }

            // App Group file copies are pure I/O — keep them off main thread too
            PendingNotification.copyIdentityToAppGroup(from: idPath)
            PendingNotification.copyConfigToAppGroup(from: configDir + "/config")
            PendingNotification.syncStorageToAppGroup(from: configDir + "/storage")

            await self?.finishStartService(result: result, configDir: configDir)
        }
    }

    /// Second half of startup — runs on @MainActor after the FFI call completes.
    ///
    /// Startup ordering (deterministic; do not rearrange casually):
    ///   0. Load the distro key (Keychain, on a detached task) before anything
    ///      can send or receive — sendingIdentity and the distro fan-out
    ///      routing read it (Android StackRuntime 245-249). `serviceStarting`
    ///      stays true across this await so a second start cannot begin.
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
    ///   7. Set the display names (DISPLAY_NAMES.md §6), then hand the
    ///      delivery destination to the publish daemon (auto-re-announce):
    ///      the Announce Display Name must be in place before the first
    ///      announce. Both on ffiQueue, in that order.
    ///   8. Side-tasks: periodic poll (seeds the router's
    ///      propagation node at once), rfed notify register.
    ///   8b. What the device owes its distro (DistroOutboxRuntime): after the
    ///      propagation node is on the router, before any send can go out.
    ///   9. Distro registration with RFed (after ConnectionStateManager is
    ///      registered; Android StackRuntime 310-313).
    ///  10. Release the sends held while the stack was starting — last, so
    ///      each goes out with everything above in place: the message-state
    ///      callback (2), or its 0x10/FAILED is lost and its propagated
    ///      fallback never starts, and the propagation node seeded in (8),
    ///      or that fallback fails at once.
    ///
    /// Each step that touches the FFI is hopped to `ffiQueue` (serial) or to
    /// a detached Task; all on-main-actor work above runs synchronously in
    /// the order written, so component callbacks observe a consistent state.
    private func finishStartService(result: Result<LxmfClient, Error>, configDir: String) async {
        let client: LxmfClient
        switch result {
        case .success(let c):
            client = c
        case .failure(let error):
            serviceStarting = false
            print("[Retichat] Failed to start: \(error.localizedDescription)")
            statusMessage = "Failed to start"
            serviceStartFailed = true
            return
        }

        await RfedDistroClient.shared.prepareForStackStart()
        serviceStarting = false

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
        configurePropagationStream()

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

        // The names as saved now (DISPLAY_NAMES.md §6), on ffiQueue ahead of
        // the publish below: the Announce Display Name is in place before
        // the first announce, and a name changed in Settings while the
        // stack was starting is not lost.
        applyDisplayNames(announceChanged: false)

        // Hand the delivery destination off to Transport's auto-announce
        // daemon: it will announce immediately, on every interface up-edge,
        // and every 30 minutes thereafter, each held per interface to one
        // announce per 30 minutes.  Replaces the previous Timer +
        // onConnect re-announce + foreground re-announce pattern.
        let publishClient = lxmfClient
        ffiQueue.async {
            guard let publishClient else { return }
            _ = publishClient.publish(refreshSecs: 30 * 60)
        }

        // Bluetooth to any RTNode in range, queued behind the publish above:
        // an RTNode's interface comes up the moment its link settles, and
        // that up-edge is when Transport announces the published destination
        // on it (DESIGN_PRINCIPLES §5). Only when the user turned the Nearby
        // RTNode switch on (off by default): start() creates the
        // CBCentralManager, and that is what asks for Bluetooth permission.
        // iOS asks only once: when Bluetooth is not allowed the coordinator
        // saves the switch off, so later starts do not get here.
        if UserPreferences.shared.rtnodeBluetoothEnabled {
            let bluetoothHost = Self.bluetoothEndpointHost
            ffiQueue.async {
                RTNodeBluetoothCoordinator.shared.start(storageDir: configDir, endpointHost: bluetoothHost)
            }
        }

        // Start propagation polling
        startPropagationPolling()

        // What this device owes its distro (RFed SPEC §17.12, §17.11): load what a previous
        // run left owed and listen for the propagation link, whose coming-up uploads it. The
        // link is the router's, opened by the node the line above gave it and by the polls:
        // this never starts it.
        DistroOutboxRuntime.shared.start(client: client)

        // Register with rfed notify service so the relay can wake this device.
        registerRfedNotify()

        // Enrol this device under the distro (if one is held): register, hand
        // RFed the pre-signed announce, pull deferred blobs.
        RfedDistroClient.shared.onStackStarted(client: client)

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

        // Contacts' names from before the three slots (DISPLAY_NAMES.md
        // §5.4): needs the stack for the recalled announce names.
        migrateLegacyContactNamesIfNeeded(client: client)

        // Import any messages the NSE delivered while we were dead
        importNSEMessages()

        // Last: everything a send depends on is in place (see step 10).
        releaseHeldSends()

        print("[Retichat] Service started. Hash: \(ownHashHex)")
    }

    func stopService() {
        pollTimer?.invalidate()
        pollTimer = nil

        // Tear down RNode interfaces before shutting down the LXMF client so
        // the Rust side stops before the callback transports are dropped.
        RNodeInterfaceCoordinator.shared.stop()

        // Destroy any message handles still in flight.
        for (_, pending) in pendingOutbound {
            LxmfClient.messageDestroy(pending.msgHandle)
        }
        pendingOutbound.removeAll()

        // Clear stale per-session state so the next start is clean.
        earlyMessageStates.removeAll()
        completedHashes.removeAll()
        completedHashSet.removeAll()
        propagationStreamDest = nil
        lastPollTime = .distantPast
        psyncNeededOnForeground = false

        // Sequence shutdown through the serial FFI queue so unpublish →
        // shutdown are ordered and cannot race with other FFI work.
        let client = lxmfClient
        lxmfClient = nil
        // Sends made from here on are held; any already held stay held and
        // go after the next start (releaseHeldSends).
        heldSends.close()
        serviceRunning = false
        statusMessage = "Stopped"
        // Before deregister (Android shutdownNow:324): drops in-flight distro
        // results and the armed ACTIVE handler while CSM still owns it.
        RfedDistroClient.shared.onStackStopped()
        // No proof can come for an upload still open: each is decided not proved, and
        // nothing is sent. The stack's shutdown drops the link callbacks; the next
        // start registers them again.
        DistroOutboxRuntime.shared.stop()
        ConnectionStateManager.shared.deregister()
        NetworkMonitor.shared.onConnect = nil

        ffiQueue.async {
            // Bluetooth first: its RTNode interfaces leave Transport before
            // the stack shuts down (a no-op if it never started).
            RTNodeBluetoothCoordinator.shared.stop()
            _ = client?.unpublish()
            client?.shutdown()
        }
    }

    /// The Prns endpoint host byte this device sends in its Bluetooth Hello:
    /// iOS 1, iPadOS 2; macOS 0 when running under Mac Catalyst.
    private static var bluetoothEndpointHost: UInt8 {
        #if targetEnvironment(macCatalyst)
        return 0
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? 2 : 1
        #endif
    }

    // MARK: - Own display names (DISPLAY_NAMES.md §4, §6)

    /// Settings saved the names: hand them to the router at once, with no
    /// stack restart (the router's setters). The Channel Display Name is
    /// read when a channel post is packed, so it needs nothing here. With
    /// the stack down, the next start reads them from the preferences.
    /// The Announce Display Name is also mirrored to the App Group, stack
    /// or not, for the NSE's copy of the delivery destination
    /// (PendingNotification.writeAnnounceDisplayName); on ffiQueue, so two
    /// saves land in order.
    func applyDisplayNames(announceChanged: Bool) {
        let message = prefs.messageDisplayName
        let announce = prefs.announceDisplayName
        let running = lxmfClient
        ffiQueue.async {
            PendingNotification.writeAnnounceDisplayName(announce)
            guard let client = running else { return }
            if !client.setMessageDisplayName(message) {
                print("[Retichat] Message Display Name not set: \(LxmfClient.lastError ?? "unknown error")")
            }
            if !client.setAnnounceDisplayName(announce) {
                print("[Retichat] Announce Display Name not set: \(LxmfClient.lastError ?? "unknown error")")
            }
        }
        // The distro's announce is pre-signed and handed to RFed (§2.2:
        // every delivery destination carries the change).
        if announceChanged && running != nil {
            RfedDistroClient.shared.republishAnnounce()
        }
    }

    // MARK: - RFed APNs token registration

    /// Registers this device for push notifications:
    /// 1. Sends APNs token to the apns_bridge via `apns.register` AppLinks DATA.
    /// 2. Registers the relay hash with rfed via `rfed.notify` AppLinks DATA.
    private func registerRfedNotify() {
        guard !ownHash.isEmpty, let client = lxmfClient else { return }
        // 1. Register APNs token with the apns_bridge (AppLinks DATA → apns.register)
        ApnsTokenRegistrar.shared.registerIfNeeded(subscriberHash: ownHash)
        // 2. Register relay hash with rfed (AppLinks DATA → rfed.notify)
        RfedNotifyRegistrar.shared.registerIfNeeded(identityHandle: client.identityHandle)
    }

    // MARK: - Own identity

    /// This device's own address and keys, for the Identity screen's
    /// "This device" section (Android IdentityScreen.kt:162-173). nil while
    /// the stack is down.
    func deviceIdentityInfo() -> DeviceIdentityInfo? {
        guard let client = lxmfClient else { return nil }
        return DeviceIdentityInfo(
            deliveryHashHex: client.destHashHex,
            identityHashHex: client.identityHashHex,
            publicKeyHex: bridge.identityPublicKey(handle: client.identityHandle)?.hexString ?? "")
    }

    /// True for this device's address or the held distro's address — the
    /// self-chat checks (QR scan, deep links, new chat) use this. Not the
    /// distro's known siblings: those are the user only in a group whose list
    /// names that distro (GROUPS-DISTRO-DESIGN.md §9.1, `groupSelf`); elsewhere
    /// another device of the user is a peer like any other.
    func isOwnAddress(_ hex: String) -> Bool {
        GroupSelf.shownAsYou(hex, groupSelf: nil, device: ownHashHex, heldDistro: ownDistroHex)
    }

    /// The `lxmf.delivery` hash of the distro the distro client holds now (lowercased).
    private var ownDistroHex: String? { RfedDistroClient.shared.distro?.deliveryHashHex.lowercased() }

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

        // No AutoInterface on any build for now (James, 2026-10-12). Its peer
        // discovery is IPv6 multicast, which iOS allows only with Apple's
        // com.apple.developer.networking.multicast entitlement; the app does
        // not carry it, so on iOS the interface could only fail. Mac Catalyst
        // had it until then, and there it also took utun2, a VPN tunnel that
        // carries no multicast, and logged "No multicast echoes received" as
        // an error. TCP to a local address needs just the Local Network
        // permission, which Info.plist declares. The NSE copies this config,
        // so it follows.

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

        // Fallback backbones only when the user left "Default TCP" on and
        // configured no interface (FallbackBackbones.select, tested in
        // tests/FallbackBackbonesTests.swift). With it off, the stack starts
        // with none: before 2885b5e a first launch with the setting off still
        // dialled three public backbones.
        let endpoints = FallbackBackbones.select(
            defaultTcpEnabled: prefs.defaultTcpEnabled,
            hasConfiguredInterfaces: addedInterfaces,
            probed: fallbackEndpoints,
            pool: { Array(DefaultEndpointManager.shuffled().prefix(DefaultEndpointManager.fallbackEndpointCount)) })
        if !endpoints.isEmpty {
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

        // Give the router its outbound propagation node now, not at the
        // first poll a second from now: until it has one, every propagated
        // send (a distro recipient, a direct send's fallback, a send held
        // through startup) fails at once (lxm_router.rs). On ffiQueue, so it
        // lands ahead of every send submitted after startup.
        if let client = lxmfClient, let nodeHash = propManager.currentNode() {
            ffiQueue.async {
                _ = client.setPropagationNode(nodeHash: nodeHash)
            }
        }

        // Share propagation node list with NSE so it can sync on its own.
        syncPropagationNodesToAppGroup()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollPropagationNode()
            }
        }
        // Initial poll after 1 second
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
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
            queue.async {
                client?.persist()
                if let target = PendingNotification.nseKnownDestinationsPath() {
                    RetichatBridge.shared.snapshotKnownDestinations(to: target)
                }
            }
            PendingNotification.syncStorageToAppGroup(from: configDir + "/storage")
        }
    }

    private func configurePropagationStream() {
        guard let client = lxmfClient else { return }
        let identityHex = prefs.effectiveRfedNodeIdentityHash
        guard !identityHex.isEmpty else {
            propagationStreamDest = nil
            return
        }

        let streamHex = RfedChannelClient.rfedDestHash(
            identityHashHex: identityHex,
            app: "rfed",
            aspects: ["propagation", "stream"])
        guard let streamDest = Data(hexString: streamHex) else {
            propagationStreamDest = nil
            return
        }

        propagationStreamDest = streamDest

        _ = ConnectionStateManager.shared.registerAppLinkPacketCallback(destHash: streamDest) { [weak self] data in
            // Distro fan-out. iOS never starts rfed.delivery, so RFed's
            // distro_fanout (RFed-rust/rfed/src/distro.rs) reaches us on tier 2,
            // this propagation stream: the bare LXMF blob, whose first 16 bytes
            // are the distro's lxmf.delivery address. ingestPropagated would
            // drop it silently (we hold no inbound destination for it), so
            // route it to the distro client first.
            // Known RFed gap, not fixed here: PropagationStreamRegistry::dispatch
            // (stream_registry.rs:135-166) counts send_packet Ok as delivered, so
            // a blob sent while iOS is suspended and before RFed marks this link
            // stale is neither deferred nor stored.
            if data.count > 16, let distroHash = DistroManager.shared.deliveryHash,
               data.prefix(16) == distroHash {
                RfedDistroClient.ingestBlob(Data(data))
                return
            }
            guard let self else { return }
            self.ffiQueue.async { [weak self] in
                guard let self, let client = self.lxmfClient else { return }
                let accepted = client.ingestPropagated(data)
                if !accepted {
                    print("[Retichat] propagation.stream packet ignored len=\(data.count)")
                }
            }
        }

        ConnectionStateManager.shared.setAppLinkStatusHandler(destHash: streamDest) { [weak self] status in
            guard status == 3 else { return }
            self?.sendPropagationStreamOpen()
        }

        if ConnectionStateManager.shared.appLinkStatus(destHash: streamDest) == 3 {
            sendPropagationStreamOpen()
        } else {
            _ = ConnectionStateManager.shared.appLinkPrime(
                destHash: streamDest,
                app: "rfed",
                aspects: ["propagation", "stream"])
        }
    }

    private func sendPropagationStreamOpen() {
        guard let client = lxmfClient,
              let streamDest = propagationStreamDest,
              let pubkey = bridge.identityPublicKey(handle: client.identityHandle),
              let sig = bridge.identitySign(handle: client.identityHandle, data: ownHash)
        else { return }

        let payload = RfedChannelClient.msgpackSigned(value: ownHash, pubkey: pubkey, sig: sig)
        Task {
            let response = await ConnectionStateManager.shared.appLinkSend(
                destHash: streamDest,
                app: "rfed",
                aspects: ["propagation", "stream"],
                path: "/rfed/propagation/stream/open",
                payload: payload)
            guard Self.streamOpenResponseOk(response) else {
                print("[Retichat] propagation.stream open rejected resp=\(response?.hexString ?? "nil")")
                return
            }
            // What rfed pushed down this device's previous link while it was
            // dead went unproven and waits in its queue for /rfed/pull, and
            // without a wake nothing fetches it. Pull once per fresh link, as
            // the web does after its binding (Retichat-js
            // _bindRfedLinkForDistroPush, then /distro/pull) and Android does
            // (PropagationStream.sendOpen): an event, not a timer. Found on
            // staging 2026-10-06, where a sibling's channel leave pushed in
            // the seconds before Android's re-open never arrived.
            if RfedDistroClient.shared.distro != nil {
                let pulled = await RfedDistroClient.shared.pull()
                print("[Retichat] propagation.stream open: pulled \(pulled) blob(s) after the open")
            }
        }
    }

    private static func streamOpenResponseOk(_ response: Data?) -> Bool {
        guard let response, response.count >= 2 else { return false }
        return response[response.startIndex] == 0x92 &&
            response[response.index(after: response.startIndex)] == 0xc3
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
        // Distro blobs the NSE pulled go through the distro client.
        RfedDistroClient.importNSEBlobs()
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

            // A transfer the NSE fetched: its key was moved to the Keychain
            // and its fields were not persisted (PendingNotification
            // .stashDistroTransferKey). Take the key off the main actor
            // (DistroManager's Keychain rule), which also clears it, then
            // offer it as handleIncomingMessage does: only when the privacy
            // filter lets its sender through, decided now, before the await.
            if let stash = msg.distroTransfer {
                let filterAllows = isAllowlisted(destHash: srcHex)
                switch stash {
                case .keychain:
                    let msgHash = msg.messageHash
                    Task {
                        let key = await Task.detached(priority: .userInitiated) {
                            PendingNotification.takeDistroTransferKey(messageHash: msgHash)
                        }.value
                        guard filterAllows else {
                            print("[Retichat] importNSEMessages: DROPPED distro identity transfer from \(srcHex.prefix(8)): the privacy filter does not let it through")
                            return
                        }
                        if let key {
                            print("[Retichat] importNSEMessages: distro identity transfer from \(srcHex.prefix(8))")
                            RfedDistroClient.shared.offerTransfer(fromHashHex: srcHex, privateKeyHex: key)
                        } else {
                            RfedDistroClient.shared.post(notice: "A distro identity transfer arrived but could not be read. Send it again from the other device.")
                        }
                    }
                case .lost:
                    print("[Retichat] importNSEMessages: NSE could not keep a distro transfer from \(srcHex.prefix(8))")
                    if filterAllows {
                        RfedDistroClient.shared.post(notice: "A distro identity transfer arrived but could not be kept. Send it again from the other device.")
                    }
                }
                continue
            }

            // Decode LXMF fields
            let fieldsData = Data(base64Encoded: msg.fieldsRawBase64) ?? Data()
            let fields = LxmfFieldsDecoder.decode(fieldsData)

            // RFed SPEC §17.14, as handleIncomingMessage: a GROUP_ID that is not 32 hex is
            // refused, never a DM or a group. The NSE no longer hands one over; this covers files
            // an older NSE build wrote.
            if fields.groupIdRefused {
                print("[Retichat] importNSEMessages: REFUSED \(msg.messageHash.prefix(8)) from \(srcHex.prefix(8)): its GROUP_ID is not 32 hex characters (never a direct message, never a group)")
                continue
            }

            // A distro transfer the NSE fetched is still an offer, not a chat
            // message, under the same filter as handleIncomingMessage.
            if let key = fields.distroTransferKey {
                offerDistroTransfer(fromHashHex: srcHex, privateKeyHex: key, via: "importNSEMessages")
                continue
            }

            // Same rule as handleIncomingMessage: a sent copy (SPEC §17.11)
            // is filed only from distro fan-out. The NSE no longer stores
            // one; this covers files an older NSE build wrote.
            if fields.isDistroSentCopy {
                print("[Retichat] importNSEMessages: DROPPED distro sent-copy marker outside fan-out src=\(srcHex.prefix(8))")
                continue
            }

            // DISPLAY_NAMES.md §5.2 on the NSE path, as on the router's: the
            // NSE keeps the delivery's reason. A file from an older NSE build
            // has none; an unvalidated message without one counts as invalid,
            // as the router reports it, which never lets a name through.
            let reason = msg.unverifiedReason ?? (msg.signatureValid ? 0 : 2)
            // Never a name from a reaction (REACTIONS-DESIGN.md §3), which makes no contact.
            let nameField = fields.reaction == nil ? LxmfClient.decodeDisplayName(fieldsRaw: fieldsData) : .absent

            if let groupId = fields.groupId {
                // The group rule as on the router's path (admitGroupMessage).
                let signature = DeliveryPolicy.Signature.reason(valid: msg.signatureValid,
                                                                unverifiedReason: reason)
                if case .kept(let standing, let ownAct) = admitGroupMessage(groupId: groupId, sourceHex: srcHex,
                                                                             fields: fields, signature: signature) {
                    // A known sibling acting as the user (§9.2) is never kept as a contact.
                    if !ownAct {
                        applyMessageName(nameField, unverifiedReason: reason, sourceHex: srcHex,
                                         messageTime: msg.timestamp)
                    }
                    handleGroupMessage(
                        hash: Data(hexString: msg.messageHash) ?? Data(),
                        srcHash: Data(hexString: srcHex) ?? Data(),
                        content: msg.content,
                        timestamp: msg.timestamp,
                        fields: fields,
                        groupId: groupId,
                        standing: standing,
                        signature: signature,
                        senderKey: msg.senderKeyHex.flatMap { Data(hexString: $0) },
                        packed: msg.packedBase64.flatMap { Data(base64Encoded: $0) },
                        ownAct: ownAct
                    )
                }
                continue
            }

            // Filter: drop messages from senders not in the contact allowlist
            let allowlist = allowlistDecision(destHash: srcHex)
            guard allowlist.isAllowed else {
                print("[Retichat] importNSEMessages: DROPPED reason=\(allowlist.debugLabel) src=\(srcHex.prefix(8))")
                continue
            }

            // REACTIONS-DESIGN.md §3, as on the router's path: never a bubble, chat or contact.
            if tookReaction(fields, chatId: srcHex, reactor: srcHex, timestamp: msg.timestamp, path: "importNSEMessages") {
                continue
            }

            let chatId = srcHex
            ensureChat(id: chatId, peerHash: srcHex)
            ensureContact(destHash: srcHex)
            applyMessageName(nameField, unverifiedReason: reason, sourceHex: srcHex,
                             messageTime: msg.timestamp)
            // As for a message the app received itself: watch the sender's
            // announces (their announce name) and fill it from the cache.
            if let srcData = Data(hexString: srcHex) {
                RetichatBridge.shared.watchAnnounce(destHash: srcData)
                lxmfClient?.watch(destHash: srcData)
                refreshAnnounceNameFromCache(destHash: srcHex)
            }

            let entity = MessageEntity(
                id: hashHex,
                chatId: chatId,
                senderHash: srcHex,
                content: msg.content,
                title: msg.title,
                timestamp: msg.timestamp,
                isOutgoing: false,
                deliveryState: DeliveryState.delivered,
                signatureValid: msg.signatureValid,
                lxmfHash: hashHex
            )
            insertMessage(entity, into: ctx)

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
            _ = client.setPropagationNode(nodeHash: nodeHash)

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

    /// Send a post. False when it was not taken (nothing shown, stored or sent): the composer keeps
    /// the draft as typed. A group post to a group that uses a distro address no longer on this
    /// device is refused so, with no notice (GROUPS-DISTRO-DESIGN.md §8.7; James, 2026-10-11).
    @discardableResult
    func sendMessage(chatId: String, content: String, attachments: [(String, Data)] = []) -> Bool {
        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[Retichat] sendMessage called chatId=\(chatId.prefix(8)) content=\(content.prefix(20))")
        guard let ctx = modelContext else {
            print("[Retichat] sendMessage: ABORT - modelContext is nil")
            return false
        }

        // Look up the chat
        let chatDescriptor = FetchDescriptor<ChatEntity>(
            predicate: #Predicate { $0.id == chatId }
        )
        guard let chat = try? ctx.fetch(chatDescriptor).first else {
            print("[Retichat] sendMessage: ABORT - chat not found for id=\(chatId)")
            return false
        }

        // Branch: group vs. direct
        if chat.isGroup {
            return sendGroupMessage(chat: chat, chatId: chatId, content: content, attachments: attachments)
        }

        let destHashHex = chat.peerHash
        print("[Retichat] sendMessage: destHashHex=\(destHashHex.prefix(8)) lxmfClientNil=\(lxmfClient == nil)")
        guard let destData = Data(hexString: destHashHex) else {
            print("[Retichat] sendMessage: ABORT - invalid destHashHex=\(destHashHex)")
            return false
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
        insertMessage(msgEntity, into: ctx)
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

        // Stack still starting (or stopped): the bubble stays pending and the
        // send waits for the end of startup, behind any sends held before it.
        guard heldSends.isOpen, let client = lxmfClient else {
            heldSends.hold(.direct(chatId: chatId, destHashHex: destHashHex, destData: destData,
                                   content: content, attachments: attachments, tempId: tempId,
                                   optimisticTimestamp: optimisticTimestamp))
            print("[Retichat] sendMessage: stack not started — held until it is (\(heldSends.count) held)")
            return true
        }

        submitDirectMessage(client: client, chatId: chatId, destHashHex: destHashHex, destData: destData,
                            content: content, attachments: attachments, tempId: tempId,
                            optimisticTimestamp: optimisticTimestamp)
        return true
    }

    /// Hand a 1:1 message to the router. Its pending bubble (`tempId`) is
    /// already in the chat; this renames it to the message hash and
    /// registers the pending entry that handleMessageState drives. Called
    /// once per message: straight from sendMessage, or from
    /// releaseHeldSends for a send held through startup.
    private func submitDirectMessage(
        client: LxmfClient, chatId: String, destHashHex: String, destData: Data,
        content: String, attachments: [(String, Data)], tempId: String,
        optimisticTimestamp: TimeInterval
    ) {
        // Capture values for the background closure
        let ownHex = ownHashHex
        let attachmentsCopy = attachments

        // Resolve delivery method synchronously — Rust (process_outbound)
        // owns the DIRECT→PROPAGATED stagger and backstop, so there is no
        // reason to wait here.  We always pass DIRECT if a path or active
        // link exists; Rust falls back to PROPAGATED after its 3-second
        // stagger if the link doesn't materialise in time.
        let linkMethod = ConnectionStateManager.shared.deliveryMethod(for: destData)

        // Sending TO a distro (RFed SPEC §17.10): no device answers a direct
        // link to the distro address, so it goes PROPAGATED at once (Android
        // ChatRepository.kt:400-411). The stored flag covers a distro whose
        // announce we heard earlier; the live announce lookup reads the Rust
        // destination table, so it runs on ffiQueue, not the main actor.
        let knownDistro = prefs.isDistroContact(destHashHex)
        let directMethod = LxmfMethod.direct
        let propagatedMethod = LxmfMethod.propagated
        // Captured here: sendingIdentity needs the device pair off-main.
        let deviceHash = client.destHash
        let deviceHandle = client.identityHandle
        let bridgeRef = bridge

        // Enqueued on the serial ffiQueue straight from the main actor, so
        // messages reach the router in the order they were sent. A detached
        // Task per message (as before) could reorder them — sends released
        // together by releaseHeldSends would not keep their order.
        ffiQueue.async { [weak self] in
            let toDistro = knownDistro || bridgeRef.peerIsDistro(destHash: destData)
            if toDistro {
                print("[Retichat] sendMessage: dest is a distro address — sending PROPAGATED")
            }
            let method = toDistro ? propagatedMethod : linkMethod
            let methodName = method == directMethod ? "DIRECT" : "PROPAGATED"
            print("[Retichat] sendMessage: method=\(methodName) dest=\(destHashHex.prefix(8))")

            let (msgHandle, sentAsDistro) = Self.createOutboundMessage(
                bridge: bridgeRef,
                deviceHash: deviceHash,
                deviceHandle: deviceHandle,
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

            // pack() + AppLinks::send() run here, off the main thread.
            guard client.sendMessageViaAppLinks(msgHandle) else {
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
                    temp.lxmfHash = msgHashHex
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
                    self.insertMessage(MessageEntity(
                        id: msgHashHex,
                        chatId: chatId,
                        senderHash: ownHex,
                        content: content,
                        timestamp: optimisticTimestamp,
                        isOutgoing: true,
                        deliveryState: DeliveryState.pending,
                        nativeHandle: msgHandle,
                        lxmfHash: msgHashHex
                    ), into: ctx)
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
                    msgHandle: msgHandle,
                    attempts: OutboundAttempts(direct: method == directMethod)
                )
                self.replayBufferedMessageStatesIfNeeded(for: msgHashHex)

                // The propagation fallback delay is owned by Rust AppLinks
                // Timer P: the 5-second liveness budget, counted only while
                // the send is undelivered AND its transfer is not moving (a
                // Resource serving more of the message restarts it; app-links
                // 07bea51, 2026-09-29). It collapses to zero when the current
                // readiness is already DISCONNECTED (red). Swift only reacts
                // to the resulting PROP_FALLBACK_REQUESTED callback.
                // No iOS-side timer needed.

                self.refreshChats()
            }

            // RFed SPEC §17.11: M went out as the distro, so tell the
            // distro's other devices. Here, once per sendMessage call (a held
            // send reaches this function once, on release) and only after M
            // was submitted: retrySendViaPropNode, the only other sender of
            // this message, never reaches this point, so a DIRECT attempt
            // plus its propagated fallback is still one copy.
            // Group sends never call this function, and transfers and
            // channel messages use their own send paths.
            if DistroCodec.needsSentCopy(sentAsDistro: sentAsDistro, destHex: destHashHex,
                                         distroHex: DistroManager.shared.deliveryHashHex) {
                Self.oweDistroSentCopy(recipient: destData, title: "", content: content, sentHash: msgHashHex)
            }
        }  // ffiQueue.async
    }

    /// RFed SPEC §17.11 "Sent-message sync": after the user's message to
    /// `recipient` went out as the distro, owe the distro one copy so every
    /// sibling device can file it as sent. To the distro, as the distro, signed
    /// with its key; text only (attachments are not copied); 0xFB/0xFC/0xFD carry
    /// the marker, the recipient and this device's own address, so this device
    /// recognises and drops its own echo of the fan-out. PROPAGATED, because only
    /// RFed answers for the distro address (the outbox uploads it to the
    /// propagation node as a propagation upload).
    ///
    /// The copy is packed and signed once, here, and kept in the distro outbox
    /// until the propagation node proves it (DistroOutboxRuntime.oweSentCopy,
    /// "The phones' outbox"): uploaded at once when the propagation link is up,
    /// otherwise when it comes up, and again when it next comes up after an
    /// upload that was not proved (James's decided exception, 2026-10-03). Until
    /// then it handed the copy to the LXMF router once and kept nothing, so one
    /// whose upload was not proved, or that was made while no propagation link
    /// could be had, was lost. No bubble, and the copy never touches the user's
    /// message state.
    ///
    /// REACTIONS-DESIGN.md §5.2: the copy also carries M's own hash (`sentHash`, SENT_HASH),
    /// so a sibling files M under it and a reaction to M finds it there; and M's 0x40 when M is
    /// a reaction (`reaction`), which the sibling applies instead of storing a bubble.
    ///
    /// nonisolated: runs on ffiQueue.
    nonisolated private static func oweDistroSentCopy(recipient: Data, title: String, content: String,
                                                      sentHash: String,
                                                      reaction: (to: Data, content: String)? = nil) {
        Task { @MainActor in
            await DistroOutboxRuntime.shared.oweSentCopy(recipient: recipient, title: title, content: content,
                                                         sentHash: sentHash, reaction: reaction)
        }
    }

    /// Create an outbound DM whose source is the distro when one is held, so
    /// replies fan out to every device (Android DistroManager.sendingIdentity
    /// at ChatRepository.kt:426-435 and 666-673; web RnsClient.sendingIdentity).
    /// The optimistic bubble keeps senderHash = ownHashHex either way (Android
    /// quirk 6). Never for a group send: those go through groupSigner, from the
    /// group's own address (GROUPS-DISTRO-DESIGN.md §8.1).
    ///
    /// nonisolated: runs on ffiQueue. Returns handle 0 on failure.
    nonisolated private static func createOutboundMessage(
        bridge: RetichatBridge, deviceHash: Data, deviceHandle: UInt64, to dest: Data,
        content: String, title: String, method: UInt8
    ) -> (handle: UInt64, asDistro: Bool) {
        let (src, identity) = DistroManager.shared.sendingIdentity(
            deviceHash: deviceHash, deviceHandle: deviceHandle)
        let handle = bridge.messageCreate(
            destHash: dest, sourceHash: src, content: content, title: title,
            method: method, identityHandle: identity)
        return (handle, src != deviceHash)
    }

    // MARK: - Group message send (fanout to all accepted members)

    /// A group post: shown at once, then fanned out, or held while the start has not finished
    /// and fanned out when it does (releaseHeldSends), exactly as a DM is. False, with nothing
    /// stored, sent or held, for a group that uses a distro address no longer on this device.
    private func sendGroupMessage(
        chat: ChatEntity, chatId: String, content: String, attachments: [(String, Data)]
    ) -> Bool {
        guard let ctx = modelContext else { return false }
        // GROUPS-DISTRO-DESIGN.md §8.7 (James, 2026-10-11): a group that uses a distro address no
        // longer on this device takes no post, and says nothing: the draft stays in the composer
        // and the chat is shown again, with the former-distro bar.
        if case .formerDistro = ability(chat) {
            print("[GroupChat] post to \(chatId.prefix(8)) not taken: the group's distro is no longer on this device (§8.7)")
            scheduleRefreshChats()
            return false
        }
        // At start-up a post waits exactly as a DM does (§8.7; ordering, not a retry): nil while
        // the stack is starting or stopped, and the send is held. Who signs is asked when it is
        // fanned out; with nobody to sign then, it shows failed.
        let client = heldSends.isOpen ? lxmfClient : nil

        // Generate a stable local ID for this outbound group message
        let msgId = "grp_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(8))"
        // REACTIONS-DESIGN.md §4: every Group post gets an id, the same on every member's copy,
        // which is what a reaction to it names.
        let postId = Reactions.newPostId()
        if postId == nil {
            print("[GroupChat] post to \(chatId.prefix(8)): no random bytes for its post id; it goes without one and offers no reactions")
        }

        // Insert optimistically. A held send is pending until it is fanned
        // out, so it never shows sent before it has left the device.
        let msgEntity = MessageEntity(
            id: msgId,
            chatId: chatId,
            senderHash: ownAddress(chat),
            content: content,
            timestamp: Date().timeIntervalSince1970,
            isOutgoing: true,
            deliveryState: client == nil
                ? DeliveryState.pending
                : DeliveryState.sent,   // fanout is fire-and-forget
            postId: postId
        )
        insertMessage(msgEntity, into: ctx)

        for (filename, data) in attachments {
            ctx.insert(AttachmentEntity(
                id: UUID().uuidString, messageId: msgId, filename: filename, data: data
            ))
        }

        chat.lastMessageTime = msgEntity.timestamp
        try? ctx.save()

        guard let client else {
            heldSends.hold(.group(chatId: chatId, content: content, attachments: attachments,
                                  messageId: msgId))
            print("[GroupChat] send held until the stack has started (\(heldSends.count) held)")
            refreshChats()
            return true
        }

        let sent = fanOutGroupMessage(chatId: chatId, groupName: chat.groupName ?? "Group",
                                      content: content, attachments: attachments, timestamp: msgEntity.timestamp,
                                      postId: postId, via: client)
        if !sent {
            // Nobody to sign for the group now (its distro still being read): the DM failed state.
            msgEntity.deliveryState = DeliveryState.failed
            try? ctx.save()
        }
        refreshChats()
        return true
    }

    /// Fan a group message out to the accepted members, as the group's own
    /// address (groupSigner, resolved now). Members are read here rather than
    /// when the message was typed: a send held through a cold start had no own
    /// address yet to leave out of the list. False, with nothing sent, when
    /// this device cannot sign for the group (§8.7).
    ///
    /// GROUPS-DISTRO-DESIGN.md §10.6: in a D-group the post owes one `post`
    /// group sync, once, after its fan-out was submitted (the router or its
    /// outbox accepted the first member envelope), never for a send that
    /// failed, and at once when there is no member to send to.
    private func fanOutGroupMessage(
        chatId: String, groupName: String, content: String, attachments: [(String, Data)],
        timestamp: Double, postId: String?, via client: LxmfClient
    ) -> Bool {
        guard let ctx = modelContext else { return false }
        guard let chat = try? ctx.fetch(FetchDescriptor<ChatEntity>(predicate: #Predicate { $0.id == chatId })).first,
              let signer = groupSigner(chat) else {
            print("[GroupChat] post to \(chatId.prefix(8)) not sent: no signer for the group's own address here (§8.7)")
            return false
        }

        // The accepted members, no self address (§9.2).
        let rows = groupRows(chatId)
        let targets = GroupMemberStatuses.acceptedMembers(rows, selfAddresses: groupSelf(chat, rows: rows))
        let owesSync = signer.isDistro
        let atMs = DistroGroupSync.atMs(timestamp)
        if owesSync && targets.isEmpty {
            owePostSync(groupId: chatId, text: content, atMs: atMs, signer: signer, postId: postId)
        }

        // Fan out to accepted members — FFI calls run off the main thread.
        ffiQueue.async { [weak self] in
            let submitted = GroupChatManager.shared.fanoutMessage(
                groupId: chatId,
                groupName: groupName,
                content: content,
                attachments: attachments,
                to: targets,
                as: signer,
                via: client,
                postId: postId
            )
            guard owesSync, !targets.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard submitted > 0 else {
                    print("[GroupChat] post to \(chatId.prefix(8)) left for no member: no group sync owed (§10.6)")
                    return
                }
                self?.owePostSync(groupId: chatId, text: content, atMs: atMs, signer: signer, postId: postId)
            }
        }
        return true
    }

    // MARK: - Sends held through startup

    /// Open the send gate and hand every held send to the normal send path,
    /// oldest first: finishStartService's last step (§5). Each goes through
    /// submitDirectMessage or fanOutGroupMessage exactly once and keeps the
    /// bubble inserted when it was typed.
    private func releaseHeldSends() {
        guard let client = lxmfClient else { return }
        let sends = heldSends.open()
        guard !sends.isEmpty, let ctx = modelContext else { return }
        print("[Retichat] releasing \(sends.count) send(s) held while the stack started")

        for send in sends {
            switch send {
            case let .direct(chatId, destHashHex, destData, content, attachments, tempId, optimisticTimestamp):
                let desc = FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.id == tempId })
                guard let bubble = try? ctx.fetch(desc).first else {
                    // Deleting the chat deleted the bubble: not wanted any more.
                    print("[Retichat] held send to \(destHashHex.prefix(8)) dropped: its chat was deleted")
                    continue
                }
                // Typed before the first start, it has no own address yet.
                bubble.senderHash = ownHashHex
                submitDirectMessage(client: client, chatId: chatId, destHashHex: destHashHex,
                                    destData: destData, content: content, attachments: attachments,
                                    tempId: tempId, optimisticTimestamp: optimisticTimestamp)

            case let .group(chatId, content, attachments, messageId):
                let desc = FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.id == messageId })
                let chatDesc = FetchDescriptor<ChatEntity>(predicate: #Predicate { $0.id == chatId })
                guard let bubble = try? ctx.fetch(desc).first,
                      let chat = try? ctx.fetch(chatDesc).first else {
                    print("[GroupChat] held send to \(chatId.prefix(8)) dropped: its chat was deleted")
                    continue
                }
                bubble.senderHash = ownAddress(chat)
                // fanout is fire-and-forget; one this device cannot sign for any more (§8.7) failed.
                let sent = fanOutGroupMessage(chatId: chatId, groupName: chat.groupName ?? "Group",
                                              content: content, attachments: attachments,
                                              timestamp: bubble.timestamp, postId: bubble.postId, via: client)
                bubble.deliveryState = sent ? DeliveryState.sent : DeliveryState.failed
            }
        }

        try? ctx.save()
        refreshChats()
    }

    // MARK: - Reactions (REACTIONS-DESIGN.md, approved by James 2026-10-17)

    /// §3, on every receive path: true when `fields` make the message a reaction, which the
    /// caller then stops on: no bubble, no notification, no unread, the chat list order unchanged,
    /// and never a new chat or contact. A reaction is applied to its target in `chatId` (the chat
    /// it came in on) as `reactor`'s at `timestamp`; one this client refuses, or whose target is
    /// not in that chat, is dropped with one log line.
    private func tookReaction(_ fields: LxmfFields, chatId: String, inGroup: Bool = false, reactor: String,
                              timestamp: Double, path: String) -> Bool {
        switch fields.reaction {
        case nil:
            return false
        case .refused(let why)?:
            print("[Reactions] \(path): reaction from \(reactor.prefix(8)) in \(chatId.prefix(8)) dropped: \(why)")
        case .react(let to, let content)?:
            applyReaction(to: to, content: content, chatId: chatId, inGroup: inGroup, reactor: reactor,
                          timestamp: timestamp, path: path)
        }
        return true
    }

    /// apply_reaction (§3) to the message `to` names in `chatId`: a newer reaction from `reactor`
    /// replaces theirs, an older or repeated one changes nothing, and "" is kept as a removal.
    private func applyReaction(to: Data, content: String, chatId: String, inGroup: Bool, reactor: String,
                               timestamp: Double, path: String) {
        guard let ctx = modelContext else {
            print("[Reactions] \(path): reaction from \(reactor.prefix(8)) dropped: modelContext is nil")
            return
        }
        let toHex = Reactions.hex(to)
        guard let target = reactionTarget(chatId: chatId, inGroup: inGroup, toHex: toHex) else {
            print("[Reactions] \(path): reaction dropped: target \(toHex.prefix(16)) not in \(chatId.prefix(8))")
            return
        }
        guard let json = Reactions.apply(target.reactionsJson, reactor: reactor, emoji: content,
                                         atMs: Reactions.ms(timestamp)) else {
            print("[Reactions] \(path): reaction from \(reactor.prefix(8)) on \(toHex.prefix(8)) not applied: one as new or newer is held")
            return
        }
        target.reactionsJson = json
        try? ctx.save()
    }

    /// find_target (§3): the message `toHex` names, looked for in `chatId` only, so a reactor
    /// reaches only a conversation it is part of. In a Group the 16-byte post id (§4); in a direct
    /// chat the 32-byte LXMF hash, which is the message's id or its stored `lxmfHash`. Any other
    /// length names nothing.
    private func reactionTarget(chatId: String, inGroup: Bool, toHex: String) -> MessageEntity? {
        guard let ctx = modelContext else { return nil }
        let wanted: String? = toHex
        if inGroup {
            guard toHex.utf8.count == 32 else { return nil }
            let desc = FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.chatId == chatId && $0.postId == wanted })
            return try? ctx.fetch(desc).first
        }
        guard toHex.utf8.count == 64 else { return nil }
        let byId = FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.id == toHex && $0.chatId == chatId })
        if let found = try? ctx.fetch(byId).first { return found }
        let byHash = FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.chatId == chatId && $0.lxmfHash == wanted })
        return try? ctx.fetch(byHash).first
    }

    /// The addresses the user sends `chat` as (§3 "Display": a chip is the user's when one of its
    /// reactors is one of them): a Group's self addresses (§9.1); in a direct chat this device and
    /// the distro it holds, which a DM goes out as.
    private func reactionSelf(_ chat: ChatEntity) -> Set<String> {
        if chat.isGroup { return groupSelf(chat, rows: groupRows(chat.id)) }
        var me: Set<String> = [ownHashHex]
        if let d = heldDistroHex { me.insert(d) }
        return me
    }

    /// The user picked `emoji` on the message `messageId` of `chatId` (§2, §4; James,
    /// 2026-10-17): one reaction per person per message, so another one replaces the user's and
    /// the same one again removes it. Applied here at once, then sent the way a message of that
    /// chat goes; nothing here waits. Nothing is offered on a message that names no target
    /// (Reactions.target), a system message, or a channel post (never in this store).
    func react(messageId: String, chatId: String, emoji: String) {
        guard let ctx = modelContext,
              let chat = try? ctx.fetch(FetchDescriptor<ChatEntity>(predicate: #Predicate { $0.id == chatId })).first,
              let target = try? ctx.fetch(FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.id == messageId })).first,
              target.chatId == chatId else {
            print("[Reactions] reaction on \(messageId.prefix(8)) not taken: the message or its chat is gone")
            return
        }
        guard !DisplayNames.isSystemMessageId(target.id),
              let to = Reactions.target(isGroup: chat.isGroup, id: target.id, lxmfHash: target.lxmfHash,
                                        postId: target.postId) else {
            print("[Reactions] reaction on \(messageId.prefix(8)) not taken: it names no target")
            return
        }
        guard emoji.utf8.count <= ReactionField.maxContentBytes else {
            print("[Reactions] reaction on \(messageId.prefix(8)) not taken: more than \(ReactionField.maxContentBytes) bytes")
            return
        }
        // Who-signs is asked now, as for a post; at start-up nothing is sent (no reaction is held).
        guard heldSends.isOpen, let client = lxmfClient else {
            print("[Reactions] reaction on \(messageId.prefix(8)) not sent: the stack has not finished starting")
            return
        }
        let content = Reactions.toggled(current: Reactions.current(target.reactionsJson, me: reactionSelf(chat)),
                                        picked: emoji)
        if chat.isGroup {
            reactInGroup(chat, target: target, to: to, content: content, via: client)
        } else {
            reactInDirectChat(chat, target: target, to: to, content: content, via: client)
        }
    }

    /// §2: an otherwise-empty message to the peer with the 0x40 field, sent the way a text
    /// message goes (createOutboundMessage, sendMessageViaAppLinks, the same DIRECT/propagated
    /// attempts through `pendingOutbound`), with no bubble; the user's reaction applied at once
    /// as the address it goes out as; and, sent as the distro, the Distro Sync of this send
    /// (§5.2), which carries M's 0x40.
    private func reactInDirectChat(_ chat: ChatEntity, target: MessageEntity, to: Data, content: String,
                                   via client: LxmfClient) {
        let chatId = chat.id
        let destHashHex = chat.peerHash
        guard let destData = Data(hexString: destHashHex) else {
            print("[Reactions] reaction in \(chatId.prefix(8)) not sent: the peer \(destHashHex.prefix(8)) is not an address")
            return
        }
        let deviceHash = client.destHash
        let deviceHandle = client.identityHandle
        // The address the reaction goes out as: what createOutboundMessage will read.
        let reactor = DistroManager.shared.sendingIdentity(deviceHash: deviceHash, deviceHandle: deviceHandle).hash.hexString
        if let json = Reactions.apply(target.reactionsJson, reactor: reactor, emoji: content,
                                      atMs: Reactions.ms(Date().timeIntervalSince1970)) {
            target.reactionsJson = json
            try? modelContext?.save()
        }

        let linkMethod = ConnectionStateManager.shared.deliveryMethod(for: destData)
        let knownDistro = prefs.isDistroContact(destHashHex)
        let directMethod = LxmfMethod.direct
        let propagatedMethod = LxmfMethod.propagated
        let bridgeRef = bridge
        let distroHex = DistroManager.shared.deliveryHashHex
        ffiQueue.async { [weak self] in
            let toDistro = knownDistro || bridgeRef.peerIsDistro(destHash: destData)
            let method = toDistro ? propagatedMethod : linkMethod
            let (handle, sentAsDistro) = Self.createOutboundMessage(
                bridge: bridgeRef, deviceHash: deviceHash, deviceHandle: deviceHandle,
                to: destData, content: "", title: "", method: method)
            guard handle != 0 else {
                print("[Reactions] reaction to \(destHashHex.prefix(8)) not made: \(LxmfClient.lastError ?? "unknown")")
                return
            }
            guard LxmfClient.messageSetReaction(handle, to: to, content: content) else {
                print("[Reactions] reaction to \(destHashHex.prefix(8)) not sent: \(LxmfClient.lastError ?? "unknown")")
                LxmfClient.messageDestroy(handle)
                return
            }
            guard client.sendMessageViaAppLinks(handle) else {
                print("[Reactions] reaction to \(destHashHex.prefix(8)) not sent: \(LxmfClient.lastError ?? "unknown")")
                LxmfClient.messageDestroy(handle)
                return
            }
            guard let hash = LxmfClient.messageHash(handle), !hash.isEmpty else {
                print("[Reactions] reaction to \(destHashHex.prefix(8)) sent, but its hash is not readable: its states are not followed")
                LxmfClient.messageDestroy(handle)
                return
            }
            let hashHex = hash.hexString
            Task { @MainActor [weak self] in
                guard let self else { return }
                // The text message's attempts (OutboundAttempts): no row has this id, so no
                // bubble's state changes; the propagated copy and the handle's release are the same.
                self.pendingOutbound[hashHex] = PendingOutbound(
                    messageId: hashHex, chatId: chatId, peerHash: destData, msgHandle: handle,
                    attempts: OutboundAttempts(direct: method == directMethod))
                self.replayBufferedMessageStatesIfNeeded(for: hashHex)
            }
            if DistroCodec.needsSentCopy(sentAsDistro: sentAsDistro, destHex: destHashHex, distroHex: distroHex) {
                Self.oweDistroSentCopy(recipient: destData, title: "", content: "", sentHash: hashHex,
                                       reaction: (to, content))
            }
        }
    }

    /// §4: a Group reaction goes as a post goes (the Group Fanout to the accepted members, as the
    /// group's own address), with no text and `REACTION_TO` the 16 bytes of the post id; applied
    /// at once as the group's own address; and, taking part as a Distro Address, owing one `react`
    /// Distro Sync of Group actions (§5.3) once its fan-out was submitted, or at once when there
    /// is no member to send to, as a post's (§10.6).
    private func reactInGroup(_ chat: ChatEntity, target: MessageEntity, to: Data, content: String,
                              via client: LxmfClient) {
        let chatId = chat.id
        guard let postId = target.postId, let signer = groupSigner(chat) else {
            print("[Reactions] reaction in group \(chatId.prefix(8)) not sent: no signer for the group's own address here (§8.7)")
            return
        }
        let now = Date().timeIntervalSince1970
        if let json = Reactions.apply(target.reactionsJson, reactor: signer.hex, emoji: content, atMs: Reactions.ms(now)) {
            target.reactionsJson = json
            try? modelContext?.save()
        }
        let rows = groupRows(chatId)
        let targets = GroupMemberStatuses.acceptedMembers(rows, selfAddresses: groupSelf(chat, rows: rows))
        let owesSync = signer.isDistro
        let atMs = DistroGroupSync.atMs(now)
        if owesSync && targets.isEmpty {
            oweGroupSync(.react, groupId: chatId, signer: signer, atMs: atMs, text: content, postId: postId)
        }
        let groupName = chat.groupName ?? "Group"
        ffiQueue.async { [weak self] in
            let submitted = GroupChatManager.shared.fanoutMessage(
                groupId: chatId, groupName: groupName, content: "", attachments: [],
                to: targets, as: signer, via: client, reaction: (to, content))
            guard owesSync, !targets.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard submitted > 0 else {
                    print("[Reactions] reaction in group \(chatId.prefix(8)) left for no member: no group sync owed (§10.6)")
                    return
                }
                self?.oweGroupSync(.react, groupId: chatId, signer: signer, atMs: atMs, text: content, postId: postId)
            }
        }
    }

    // MARK: - Group invite / accept / leave

    /// Accept a pending group invite: mark all members as allowlisted,
    /// record the user's own entry as accepted, and broadcast acceptance to
    /// the others, as the group's own address (groupSigner). In a D-group the
    /// accept goes as D and owes one `accept` group sync, in the same step
    /// (GROUPS-DISTRO-DESIGN.md §10.6). Only in a group this device acts in
    /// (§8.7): at start-up Accept is greyed, and for a former distro it is not
    /// offered; otherwise nothing changes and nothing is sent.
    func acceptGroupInvite(groupId: String) {
        guard let ctx = modelContext, let client = lxmfClient else { return }

        let chatDesc = FetchDescriptor<ChatEntity>(predicate: #Predicate { $0.id == groupId })
        guard let chat = try? ctx.fetch(chatDesc).first else { return }
        guard ability(chat) == .acts, let signer = groupSigner(chat) else {
            print("[GroupChat] accept of \(groupId.prefix(8)) not done: \(ability(chat)), no signer for the group here (§8.7)")
            return
        }

        // Gather the full member list stored from the invite
        let memberDesc = FetchDescriptor<GroupMemberEntity>(
            predicate: #Predicate { $0.groupId == groupId }
        )
        let existingMembers = (try? ctx.fetch(memberDesc)) ?? []
        let rows = existingMembers.map { (hash: $0.memberHash, status: $0.inviteStatus) }
        let selfAddresses = groupSelf(chat, rows: rows)
        let allHashes = existingMembers.map { $0.memberHash }
        // Every member's key but the user's own (no self address: D's key is the distro's, §9.4).
        let missingKeys = allHashes.filter { hash in
            guard !selfAddresses.contains(hash), let hashData = Data(hexString: hash) else { return false }
            return !bridge.transportIdentityKnown(destHash: hashData)
        }
        guard missingKeys.isEmpty else {
            print("[GroupChat] accept deferred: still receiving \(missingKeys.count) member key(s)")
            return
        }

        // Every member's key is here now, so an accept or leave held for its key (from the
        // switch) is decided before the group is joined.
        groupStatuses.decideHeld()

        // Promote from pending to active, only now that the accept goes out:
        // until 2026-10-05 a deferred accept already made the group active
        // (autosaved), so the group counted as joined with nothing sent.
        chat.groupStatus = "active"

        // Mark the group's own address as accepted (add its entry if absent): pending or joined
        // is read from that row alone (§9.2).
        let own = signer.hex
        if let selfEntry = existingMembers.first(where: { $0.memberHash == own }) {
            selfEntry.inviteStatus = MemberStatus.accepted
        } else {
            ctx.insert(GroupMemberEntity(groupId: groupId, memberHash: own,
                                         inviteStatus: MemberStatus.accepted))
        }

        // Add all group members to allowlist (key spec requirement): from the user's accept, not
        // from the invite's arrival (RFed-spec Group.md, "The privacy filter"); no self address,
        // and not the group id (phantom contacts, audit L4).
        for hash in allHashes where !selfAddresses.contains(hash) {
            ensureAllowlistedContact(destHash: hash)
            if let hashData = Data(hexString: hash) {
                RetichatBridge.shared.watchAnnounce(destHash: hashData)
            }
        }

        try? ctx.save()

        // Broadcast acceptance to everyone else — FFI off main thread
        let targets = allHashes.filter { !selfAddresses.contains($0) }
        ffiQueue.async {
            GroupChatManager.shared.sendAccept(
                groupId: groupId, to: targets, as: signer, via: client
            )
        }
        if signer.isDistro, let creator = chat.creatorHash {
            oweGroupSync(.accept, groupId: groupId, signer: signer, atMs: DistroGroupSync.atMs(Date().timeIntervalSince1970),
                         name: chat.groupName ?? "Group",
                         membersCsv: chat.membersCsv ?? allHashes.joined(separator: ","),
                         keys: memberKeyEntries(allHashes, signer: signer), creator: creator)
        }
        // Joined here: what was held for the group is judged again (§6.5).
        replayHeldArrivals(groupId: groupId)

        refreshChats()
    }

    /// Decline a pending group invite: the user's leave (James, 2026-10-02:
    /// "Make the decline message the same as the leave message"), through
    /// the one path leaving takes (quitGroup), so every member records the
    /// user as a member who left, for good. Until 2026-10-05 a decline sent
    /// nothing and only this device knew.
    func declineGroupInvite(groupId: String) {
        quitGroup(chatId: groupId, how: "declined")
    }

    /// Leave a group: the user's leave to its members, and for good (quitGroup).
    func leaveGroup(chatId: String) {
        quitGroup(chatId: chatId, how: "left")
    }

    /// A decline, a leave or a delete of group `chatId` (`how`, for the
    /// log), one path for all three: the user's leave (GroupChatManager
    /// .sendLeave: GROUP_ID, GROUP_ACTION leave, GROUP_SENDER the group's own
    /// address, no content, DIRECT with the propagated fallback) goes to every
    /// listed member that has not left and is not the user, still-invited
    /// members too (GroupMemberStatuses.leaveTargets); the group is recorded as
    /// closed (James, 2026-10-01: "Once the group is rejected/left, that person
    /// cannot rejoin": a later invite to it is ignored, so nothing offers it
    /// again); then its chat goes. The sends neither wait for nor undo the
    /// close. Until 2026-10-05 a leave went to the accepted members only and
    /// nothing was recorded.
    ///
    /// GROUPS-DISTRO-DESIGN.md: in a D-group the leave goes as D, the id goes
    /// in this device's `left` list for D, and one `leave` group sync is owed,
    /// in the same step (§10.6), so every device of D closes it (§13). Only in a
    /// group this device acts in (§8.7; James, 2026-10-11): at start-up Decline,
    /// Leave and Delete are greyed, and a former distro's group offers only
    /// "Delete from this device" (deleteGroupFromThisDevice); otherwise nothing
    /// is recorded, sent or deleted.
    private func quitGroup(chatId: String, how: String) {
        guard let ctx = modelContext else { return }
        let chatDesc = FetchDescriptor<ChatEntity>(predicate: #Predicate { $0.id == chatId })
        guard let chat = try? ctx.fetch(chatDesc).first, chat.isGroup else { return }
        guard ability(chat) == .acts else {
            print("[GroupChat] \(how) of \(chatId.prefix(8)) not done: \(ability(chat)) (§8.7)")
            return
        }
        guard let client = lxmfClient, let signer = groupSigner(chat) else {
            print("[GroupChat] \(how) of \(chatId.prefix(8)) not done: no signer for the group here (§8.7)")
            return
        }
        let rows = groupRows(chatId)
        let targets = GroupMemberStatuses.leaveTargets(rows, selfAddresses: groupSelf(chat, rows: rows))
        prefs.closedGroupIds = ClosedGroups.record(prefs.closedGroupIds, chatId)
        ffiQueue.async {
            GroupChatManager.shared.sendLeave(groupId: chatId, to: targets, as: signer, via: client)
        }
        if signer.isDistro {
            recordLeft([chatId], distro: signer.hex)
            oweGroupSync(.leave, groupId: chatId, signer: signer, atMs: DistroGroupSync.atMs(Date().timeIntervalSince1970))
        }
        deleteChatLocal(chatId: chatId)
        print("[GroupChat] group \(chatId.prefix(8)) \(how) (leave to \(targets.count) member(s))")
    }

    /// GROUPS-DISTRO-DESIGN.md §8.7, "Delete from this device": a group whose own address is a
    /// distro this device does not hold is removed here only. No leave is sent and no group sync
    /// is owed: the user stays in the group on the other devices and for the other members. The
    /// id is recorded closed on this device (decided 2026-10-11, the same on every client), so a
    /// later invite or group sync for it does not bring it back here; nothing goes in a `left`
    /// list, so no other device closes it. Only for such a group, never at start-up (James,
    /// 2026-10-11): it would close for good a group this device can use once started.
    func deleteGroupFromThisDevice(chatId: String) {
        guard let ctx = modelContext,
              let chat = try? ctx.fetch(FetchDescriptor<ChatEntity>(predicate: #Predicate { $0.id == chatId })).first,
              chat.isGroup else { return }
        guard case .formerDistro = ability(chat) else {
            print("[GroupChat] group \(chatId.prefix(8)) not deleted from this device: \(ability(chat)), not a former distro's (§8.7)")
            return
        }
        prefs.closedGroupIds = ClosedGroups.record(prefs.closedGroupIds, chatId)
        print("[GroupChat] group \(chatId.prefix(8)) deleted from this device only and closed here: no leave, no group sync (§8.7)")
        deleteChatLocal(chatId: chatId)
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
            let rows = ((try? ctx.fetch(memberDesc)) ?? []).map { (hash: $0.memberHash, status: $0.inviteStatus) }
            // Nobody in a group the user has not accepted (§7: opening a
            // pending group's chat asks nothing of its members). The peers
            // opened are remembered, so the close matches the open even when
            // the user accepts meanwhile.
            let held = GroupMemberStatuses.held(groupExists: true, groupStatus: chat.groupStatus)
            let peers = GroupMemberStatuses.conversationPeers(rows, selfAddresses: groupSelf(chat, rows: rows), held: held)
            openedGroupPeers[chatId] = peers
            for member in peers {
                if let peerHash = Data(hexString: member) {
                    ConnectionStateManager.shared.openConversation(peerHash: peerHash)
                }
            }
        } else {
            guard let peerHash = Data(hexString: chat.peerHash) else { return }
            ConnectionStateManager.shared.openConversation(peerHash: peerHash)
        }
    }

    /// The members whose links openConversation opened, per group chat id.
    private var openedGroupPeers: [String: [String]] = [:]

    /// Call when a conversation screen disappears.  Closes app links for
    /// all peers that were opened by openConversation.
    func closeConversation(chatId: String) {
        // A group's: the peers its open opened, even when the group has gone
        // since (left or declined while its chat was open).
        if let peers = openedGroupPeers.removeValue(forKey: chatId) {
            for member in peers {
                if let peerHash = Data(hexString: member) {
                    ConnectionStateManager.shared.closeConversation(peerHash: peerHash)
                }
            }
            return
        }
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<ChatEntity>(predicate: #Predicate { $0.id == chatId })
        guard let chat = try? ctx.fetch(desc).first else { return }

        if !chat.isGroup {
            guard let peerHash = Data(hexString: chat.peerHash) else { return }
            ConnectionStateManager.shared.closeConversation(peerHash: peerHash)
        }
    }

    // MARK: - MessageStateCallback

    @MainActor func onMessageState(hash: Data, state: UInt8) {
        handleMessageState(hash: hash, state: state)
    }

    private func handleMessageState(hash: Data, state: UInt8) {
        handleMessageState(hashHex: hash.hexString, state: state)
    }

    private func handleMessageState(hashHex: String, state: UInt8) {
        if let client = lxmfClient,
           GroupChatManager.shared.handleMessageState(hashHex: hashHex, state: state, client: client) {
            return
        }
        if let client = lxmfClient,
           DistroTransferTracker.shared.handleMessageState(hashHex: hashHex, state: state, client: client) {
            return
        }
        guard var pending = pendingOutbound[hashHex] else {
            // DELIVERED can arrive after the pending was already completed:
            // SENT completed it (the node holds the copy), or it is the late
            // proof of a DIRECT attempt that failed (LXMF-rust 9ef5174). The
            // row id is the hash, so update the DB directly and the
            // double-checkmark is not lost.
            if state == 0x08 {
                updateDeliveryState(messageId: hashHex, state: DeliveryState.delivered)
            } else if !completedHashSet.contains(hashHex) {
                earlyMessageStates[hashHex, default: []].append(state)
            }
            return
        }

        // The DIRECT attempt and its propagated copy report under this one
        // hash, so a state cannot be traced to either; OutboundAttempts
        // counts the attempts in flight and says what to do.
        let step: OutboundAttempts.Step
        switch state {

        case 0x04:  // SENT — the propagation node accepted the copy (or the only, PROPAGATED, attempt).
            // That attempt is over. As the device, DELIVERED may follow and
            // finds the row by hash (above). As the distro it never reaches
            // the router: the recipient's notification goes to the distro and
            // comes back only through RFed fan-out.
            step = pending.attempts.sent()

        case 0x08:  // DELIVERED — recipient downloaded and decrypted the message.
            step = pending.attempts.delivered()

        case 0x10:  // PROP_FALLBACK_REQUESTED — Rust Timer P fired after its current delay.
            // The direct send is still running but has gone 5 s undelivered
            // with its transfer not moving (or the AppLink was DISCONNECTED
            // at send); until app-links 07bea51 (2026-09-29) it fired 5 s
            // after the send whatever the transfer was doing, so every photo
            // got a second, propagated upload. The copy runs beside the
            // direct send and the recipient drops whichever arrives second
            // (same hash). The DIRECT attempt stays SENDING, so its bar
            // stays up (UploadProgress) and moves again if it resumes.
            // Until 2026-09-24 a message with attachments got no copy.
            step = pending.attempts.propagationRequested()

        case 0xFD, 0xFE, 0xFF:  // REJECTED, CANCELLED, FAILED.
            // Before any copy, the DIRECT attempt failed and the copy goes
            // now, the bubble showing propagating (until 2026-09-24 it stayed
            // pending). After, one attempt ended; the message fails when none
            // is left and none succeeded.
            step = pending.attempts.failed()
            if step.startCopy {
                ConnectionStateManager.shared.markPeerDegraded(
                    destHex: pending.peerHash.hexString
                )
            }

        default:
            return  // Intermediate states (e.g. SENDING=0x02) — no DB update.
        }
        pendingOutbound[hashHex] = pending
        apply(step, hashHex: hashHex, pending: pending)
    }

    /// Do what OutboundAttempts decided for `pending`, whose updated
    /// attempts are already stored.
    private func apply(_ step: OutboundAttempts.Step, hashHex: String, pending: PendingOutbound) {
        if let shown = step.show {
            updateDeliveryState(messageId: pending.messageId, state: Self.deliveryState(shown))
        }
        if step.startCopy {
            retrySendViaPropNode(hashHex: hashHex, directHandle: pending.msgHandle)
        }
        if step.complete {
            completePending(hashHex: hashHex, pending: pending)
        }
    }

    private static func deliveryState(_ shown: OutboundAttempts.Shown) -> Int {
        switch shown {
        case .propagating: return DeliveryState.propagating
        case .sent: return DeliveryState.sent
        case .delivered: return DeliveryState.delivered
        case .failed: return DeliveryState.failed
        }
    }

    private func replayBufferedMessageStatesIfNeeded(for hashHex: String) {
        guard let bufferedStates = earlyMessageStates.removeValue(forKey: hashHex) else { return }
        for state in bufferedStates {
            handleMessageState(hashHex: hashHex, state: state)
        }
    }

    /// No attempt is left to hear from. The DIRECT handle goes last: the
    /// copy is cloned from it.
    private func completePending(hashHex: String, pending: PendingOutbound) {
        pendingOutbound.removeValue(forKey: hashHex)
        earlyMessageStates.removeValue(forKey: hashHex)
        if completedHashSet.insert(hashHex).inserted {
            completedHashes.append(hashHex)
            if completedHashes.count > Self.completedHashCapacity {
                completedHashSet.remove(completedHashes.removeFirst())
            }
        }
        LxmfClient.messageDestroy(pending.msgHandle)
    }

    /// Send the propagated copy of the message whose DIRECT attempt is
    /// `directHandle`: a clone (message_clone_propagated) with its source,
    /// content, fields, attachments and packed timestamp, and so its message
    /// hash. The copy's states reach the same pending entry and the
    /// recipient keeps only one of the two. Until 2026-09-24 this built a new
    /// message without the attachments: a new hash, a second pending entry,
    /// and a recipient that got both attempts showed the message twice.
    ///
    /// The clone is made on ffiQueue, off the main actor (§6): it takes the
    /// message's lock, which the router holds while it reports 0x10 and
    /// FAILED. The DIRECT handle is released only when the message
    /// completes, so it is still registered unless the message completed
    /// (delivered, or the stack stopped) before the clone ran — and then no
    /// copy is needed.
    private func retrySendViaPropNode(hashHex: String, directHandle: UInt64) {
        guard lxmfClient != nil else {
            propagatedCopyNotStarted(hashHex: hashHex)
            return
        }
        ffiQueue.async { [weak self] in
            if Self.submitPropagatedCopy(of: directHandle, hashHex: hashHex) { return }
            Task { @MainActor [weak self] in
                self?.propagatedCopyNotStarted(hashHex: hashHex)
            }
        }
    }

    /// Clone, submit and release the copy. The router keeps its own
    /// reference to a submitted message and every state arrives by hash, so
    /// nothing needs the copy's registry handle: it is released at once, as
    /// GroupChatManager does. Returns false (logged) when no copy we can
    /// follow went out.
    ///
    /// nonisolated: runs on ffiQueue, so it uses DistroMessageFFI's
    /// nonisolated wrappers (LxmfClient's statics are main-actor isolated).
    nonisolated private static func submitPropagatedCopy(of directHandle: UInt64, hashHex: String) -> Bool {
        let copy = DistroMessageFFI.clonePropagated(directHandle)
        guard copy != 0 else {
            print("[Retichat] propagated copy of \(hashHex.prefix(8)) not cloned: \(DistroMessageFFI.lastError())")
            return false
        }
        defer { DistroMessageFFI.destroy(copy) }
        guard DistroMessageFFI.sendViaAppLinks(copy) else {
            print("[Retichat] propagated copy of \(hashHex.prefix(8)) not sent: \(DistroMessageFFI.lastError())")
            return false
        }
        // The clone keeps the hash (LXMF-rust propagated_copy); a copy under
        // another would report where no pending entry hears it.
        if let copyHash = DistroMessageFFI.hash(copy), copyHash.hexString != hashHex {
            print("[Retichat] propagated copy of \(hashHex.prefix(8)) went out as \(copyHash.hexString.prefix(8)): its states cannot reach the bubble")
            return false
        }
        print("[Retichat] propagated copy of \(hashHex.prefix(8)) submitted")
        return true
    }

    /// The copy of `hashHex` did not go out (logged on ffiQueue), so no
    /// report will come for it: an attempt that ended failed. With no
    /// pending entry the message completed, or the stack stopped, before
    /// the clone ran.
    private func propagatedCopyNotStarted(hashHex: String) {
        guard var pending = pendingOutbound[hashHex] else {
            print("[Retichat] propagated copy of \(hashHex.prefix(8)) not needed: the message completed (or the stack stopped) first")
            return
        }
        let step = pending.attempts.copyNotStarted()
        pendingOutbound[hashHex] = pending
        apply(step, hashHex: hashHex, pending: pending)
    }

    /// Update delivery state with sticky-success priority matching Android's
    /// ChatRepository.kt: DELIVERED upgrades SENT; success states (SENT,
    /// DELIVERED) are never downgraded by non-success states (pending, failed,
    /// propagating).
    private func updateDeliveryState(messageId: String, state: Int) {
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<MessageEntity>(
            predicate: #Predicate { $0.id == messageId }
        )
        guard let msg = try? ctx.fetch(descriptor).first else { return }

        let currentState = msg.deliveryState
        let isCurrentSuccess = currentState == DeliveryState.sent ||
                               currentState == DeliveryState.delivered
        let isNewSuccess = state == DeliveryState.sent ||
                           state == DeliveryState.delivered

        if isCurrentSuccess && !isNewSuccess {
            // Never downgrade a success state with a non-success state.
            return
        }
        if currentState == DeliveryState.delivered && state == DeliveryState.sent {
            // DELIVERED beats SENT — don't downgrade.
            return
        }

        msg.deliveryState = state
        try? ctx.save()
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
                               signatureValid: Bool, unverifiedReason: Int, fieldsRaw: Data,
                               senderKey: Data?, packed: Data?) {
        handleIncomingMessage(
            hash: hash, srcHash: srcHash, destHash: destHash,
            title: title, content: content, timestamp: timestamp,
            signatureValid: signatureValid, unverifiedReason: unverifiedReason, fieldsRaw: fieldsRaw,
            senderKey: senderKey, packed: packed
        )
    }

    private func handleIncomingMessage(hash: Data, srcHash: Data, destHash: Data,
                                        title: String, content: String, timestamp: Double,
                                        signatureValid: Bool, unverifiedReason: Int, fieldsRaw: Data,
                                        senderKey: Data?, packed: Data?) {
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

        // RFed SPEC §17.14, on this path as on the distro's: a GROUP_ID that is not a str of 32
        // hex characters (a bin, an int, nil, "xyz") is refused with a log line, never a direct
        // message and never a group, whatever else the message carries. Until 2026-10-11 a bin
        // or int id went on as a DM and "xyz" made a group of that name.
        if fields.groupIdRefused {
            print("[Retichat] handleIncomingMessage: REFUSED \(msgHashHex.prefix(8)) from \(srcHex.prefix(8)): its GROUP_ID is not 32 hex characters (never a direct message, never a group)")
            return
        }

        // Distro identity transfer from another of our devices (SPEC §17.9):
        // never a chat message, and offered only when the privacy filter lets
        // its sender through (filter off: anyone; on: an allowlisted row), as
        // the web and Android offer it (James, 2026-10-05). Until then it was
        // offered from anyone, so any stranger could put the import prompt in
        // front of the user.
        if let key = fields.distroTransferKey {
            offerDistroTransfer(fromHashHex: srcHex, privateKeyHex: key, via: "handleIncomingMessage")
            return
        }

        // A distro sent copy (SPEC §17.11) is addressed to the distro and
        // reaches us only as fan-out, via RfedDistroClient. One delivered to
        // this device's own address is forged or misrouted: it must never
        // become an incoming bubble.
        if fields.isDistroSentCopy {
            print("[Retichat] handleIncomingMessage: DROPPED distro sent-copy marker outside fan-out src=\(srcHex.prefix(8))")
            return
        }

        // The sender's name, field 0xD1 (DISPLAY_NAMES.md §5.2). It names
        // the LXMF source (for a relayed group message, the relayer) and is
        // taken only from a message this device accepts: a group message
        // the group policy lets through, or a DM past the allowlist. Never
        // from a reaction (REACTIONS-DESIGN.md §3), which makes no contact.
        let nameField = fields.reaction == nil ? LxmfClient.decodeDisplayName(fieldsRaw: fieldsRaw) : .absent

        // Handle group message: the privacy filter and James's group model
        // (admitGroupMessage, DeliveryPolicy), before any write, so a dropped
        // message leaves nothing behind. The source is the packet's own,
        // never GROUP_SENDER.
        if let groupId = fields.groupId {
            let signature = DeliveryPolicy.Signature.reason(valid: signatureValid,
                                                            unverifiedReason: unverifiedReason)
            guard case .kept(let standing, let ownAct) = admitGroupMessage(groupId: groupId, sourceHex: srcHex,
                                                                            fields: fields, signature: signature)
            else { return }
            // A known sibling acting as the user (§9.2) is never kept as a contact.
            if !ownAct {
                applyMessageName(nameField, unverifiedReason: unverifiedReason, sourceHex: srcHex,
                                 messageTime: timestamp)
            }
            handleGroupMessage(
                hash: hash, srcHash: srcHash, content: content, timestamp: timestamp,
                fields: fields, groupId: groupId, standing: standing, signature: signature,
                senderKey: senderKey, packed: packed, ownAct: ownAct
            )
            return
        }

        // Filter: drop direct messages from senders not in the contact allowlist.
        // Do this before any DB writes so strangers consume no resources.
        let allowlist = allowlistDecision(destHash: srcHex)
        guard allowlist.isAllowed else {
            print("[Retichat] handleIncomingMessage: DROPPED reason=\(allowlist.debugLabel) src=\(srcHex.prefix(8))")
            return
        }
        print("[Retichat] handleIncomingMessage: ACCEPTED reason=\(allowlist.debugLabel) src=\(srcHex.prefix(8))")

        // REACTIONS-DESIGN.md §3: a reaction is applied to its target in this chat, or dropped
        // with its log line; never a bubble, a notification, unread, or a new chat or contact.
        if tookReaction(fields, chatId: srcHex, reactor: srcHex, timestamp: timestamp, path: "handleIncomingMessage") {
            return
        }

        applyMessageName(nameField, unverifiedReason: unverifiedReason, sourceHex: srcHex,
                         messageTime: timestamp)
        storeIncomingDirect(
            messageId: msgHashHex, srcHash: srcHash, title: title, content: content,
            timestamp: timestamp, signatureValid: signatureValid,
            attachments: fields.attachments, lxmfHash: msgHashHex)
    }

    /// Store an accepted direct message and notify — the tail shared by the
    /// router delivery path and distro fan-out. The caller has already
    /// deduplicated and applied (or deliberately skipped) the allowlist.
    private func storeIncomingDirect(messageId msgHashHex: String, srcHash: Data,
                                     title: String, content: String, timestamp: Double,
                                     signatureValid: Bool,
                                     attachments: [(filename: String, data: Data)],
                                     lxmfHash: String? = nil, notify: Bool = true) {
        guard let ctx = modelContext else { return }
        let srcHex = srcHash.hexString

        // Direct message — find or create chat
        let chatId = srcHex
        ensureChat(id: chatId, peerHash: srcHex)
        ensureContact(destHash: srcHex)

        // Watch for announces from this sender so their announce name
        // (DISPLAY_NAMES.md §5.1 announceName) is received, and take the
        // one already cached. The message name was applied by the caller.
        RetichatBridge.shared.watchAnnounce(destHash: srcHash)
        lxmfClient?.watch(destHash: srcHash)
        refreshAnnounceNameFromCache(destHash: srcHex)

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
            signatureValid: signatureValid,
            lxmfHash: lxmfHash
        )
        insertMessage(msgEntity, into: ctx)

        // Handle attachments from fields
        for (filename, data) in attachments {
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

        // Get sender name for notification (none for a message the NSE
        // already showed).
        if notify {
            let notifyName = contactDisplayName(for: srcHex)
            notifManager.postMessageNotification(
                chatId: chatId, senderName: notifyName, content: content
            )
        }

        refreshChats()
    }

    /// A message fanned out to our distro address by RFed (Android
    /// ChatRepository.onDistroMessageReceived, kt:894-910).
    ///
    /// No allowlist check: mail to the distro is mail to this person, and the
    /// contact is always created, as on Android. The unwrap reports the
    /// signature and the sender's 0xD1 (DISPLAY_NAMES.md §5.2), and the
    /// message's fields: its attachments are stored as a direct message's
    /// are (DistroMessageStore), and only a message with neither text nor
    /// an attachment to store gets the placeholder.
    private func handleDistroMessage(_ m: DistroMessage) {
        guard let ctx = modelContext else {
            print("[Retichat] handleDistroMessage: DROPPED - modelContext is nil")
            return
        }
        let srcHex = m.sourceHash.hexString
        // REACTIONS-DESIGN.md §3: a reaction to the distro names a message of the chat with its
        // source; it is never stored, and makes no contact.
        let fields = LxmfFieldsDecoder.decode(m.fields ?? Data())
        if tookReaction(fields, chatId: srcHex, reactor: srcHex, timestamp: m.timestamp, path: "handleDistroMessage") {
            return
        }
        let (content, attachments) = DistroMessageStore.stored(m)
        // Deterministic id: the same message can arrive via the stream AND a
        // pull before the seen store records it.
        let msgId = DistroCodec.messageId(sourceHex: srcHex, timestamp: m.timestamp, content: content)
        let dup = FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.id == msgId })
        if let existing = try? ctx.fetch(dup), !existing.isEmpty {
            print("[Retichat] handleDistroMessage: DROPPED duplicate \(msgId.prefix(8))")
            return
        }
        print("[Retichat] handleDistroMessage: src=\(srcHex.prefix(8)) len=\(content.count) attachments=\(attachments.count)")
        ensureContact(destHash: srcHex)
        applyMessageName(m.displayName, unverifiedReason: m.unverifiedReason, sourceHex: srcHex,
                         messageTime: m.timestamp)
        storeIncomingDirect(
            messageId: msgId, srcHash: m.sourceHash, title: m.title, content: content,
            timestamp: m.timestamp, signatureValid: m.unverifiedReason == 0,
            attachments: attachments, lxmfHash: DistroGroupSync.messageHash(m.hash), notify: !m.shownByNSE)
    }

    /// A message another of our devices sent as the distro, reported by its
    /// sent copy (RFed SPEC §17.11; the sender is sendDistroSentCopy on each
    /// client). RfedDistroClient has checked provenance, dropped our own
    /// echo and validated the recipient.
    ///
    /// Stored as OUTGOING in the chat with the recipient: sender = the
    /// distro ("me"), state SENT — never DELIVERED, since this device cannot
    /// know. No allowlist check and no notification: the user wrote it.
    private func handleDistroSentCopy(_ c: DistroSentCopy) {
        guard let ctx = modelContext else {
            print("[Retichat] handleDistroSentCopy: DROPPED - modelContext is nil")
            return
        }
        let distroHex = c.distroHash.hexString
        // REACTIONS-DESIGN.md §5.2: the copy of a reaction the user sent as the distro applies it
        // (reactor the distro) to its target in the chat with the recipient; no bubble.
        let fields = LxmfFieldsDecoder.decode(c.fields ?? Data())
        if tookReaction(fields, chatId: c.recipientHex, reactor: distroHex, timestamp: c.timestamp,
                        path: "handleDistroSentCopy") {
            return
        }
        var content = c.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty {
            // M carried only attachments, which the copy never does.
            content = "[Attachment not available via the distro address]"
        }
        // Same id rule as handleDistroMessage: the copy can arrive via the
        // stream AND a pull before the seen store records it.
        let msgId = DistroCodec.messageId(sourceHex: distroHex, timestamp: c.timestamp, content: content)
        let dup = FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.id == msgId })
        if let existing = try? ctx.fetch(dup), !existing.isEmpty {
            print("[Retichat] handleDistroSentCopy: DROPPED duplicate \(msgId.prefix(8))")
            return
        }
        let chatId = c.recipientHex
        print("[Retichat] handleDistroSentCopy: to=\(chatId.prefix(8)) len=\(content.count)")
        ensureChat(id: chatId, peerHash: chatId)
        // A plain contact row (not allowlisted), as for an incoming message,
        // so the chat can pick up the recipient's name from announces.
        ensureContact(destHash: chatId)
        if let peer = Data(hexString: chatId) {
            RetichatBridge.shared.watchAnnounce(destHash: peer)
            lxmfClient?.watch(destHash: peer)
        }

        insertMessage(MessageEntity(
            id: msgId,
            chatId: chatId,
            senderHash: distroHex,
            content: content,
            title: c.title,
            timestamp: c.timestamp,
            isOutgoing: true,
            deliveryState: DeliveryState.sent,
            // §5.2: M's own hash (SENT_HASH, key 12), so a reaction to M finds it here.
            lxmfHash: fields.sentHash
        ), into: ctx)
        updateChatTimestamp(chatId: chatId, timestamp: c.timestamp)
        try? ctx.save()
        refreshChats()
    }

    /// A group message the rule kept (admitGroupMessage, DeliveryPolicy),
    /// with the group as it stood when it was admitted. James's group model:
    /// the members are the creator's list, fixed; an accept or a leave is
    /// the packet source's own; a leave (a decline's included) is final; a
    /// pending group relays for nobody.
    private func handleGroupMessage(hash: Data, srcHash: Data, content: String, timestamp: Double,
                                    fields: LxmfFields, groupId: String, standing: GroupStanding,
                                    signature: Int, senderKey: Data? = nil, packed: Data? = nil,
                                    ownAct: Bool = false) {
        let srcHex = srcHash.hexString
        let action = fields.groupAction  // nil = regular message

        // What any group message the rule kept brings: the key an accept or leave carries is
        // remembered (after the rule, never for a message it dropped), and a message its source
        // signed shows that source's key is here, so what was held for it is decided now, before
        // this message.
        groupStatuses.onKept(src: srcHex, action: action, signature: signature, senderKey: senderKey,
                             chatId: groupId)

        switch action {
        case GroupAction.invite:
            handleGroupInvite(srcHex: srcHex, timestamp: timestamp, fields: fields,
                              groupId: groupId, standing: standing, hashHex: hash.hexString)
        case GroupAction.accept, GroupAction.leave:
            // The source's own, never GROUP_SENDER's (the rule took it only from a current member
            // naming nobody else, not forged). Verified (under a key held, or the one it
            // carries), it counts; one no key can verify counts until the switch and is held
            // from it. What it changes (a member that left stays left; a decline arrives as a
            // leave from a member still invited), the creator's copy and its answer are the
            // engine's.
            guard let chat = standing.chat else { return }
            groupStatuses.takeDirect(GroupArrival(
                msgId: hash.hexString, src: srcHex, chat: Self.groupInfo(chat), action: action ?? "",
                timestamp: timestamp, signature: signature, senderKey: senderKey, packed: packed))
        case GroupAction.status:
            // The creator's answer to the user's accept (the rule took it only from the group's
            // creator, for a group the user joined, signed by it): each element is a member's own
            // accept or leave, checked on its own.
            guard let chat = standing.chat else { return }
            groupStatuses.takeStatuses(chat: Self.groupInfo(chat), elements: fields.groupStatuses)
        case GroupAction.relayRequest:
            // A relay request keeps today's behaviour only in a group whose own address is the
            // device; a D-group relays for nobody (GROUPS-DISTRO-DESIGN.md §12.3: no designated
            // relayer among the devices of D).
            if let chat = standing.chat, GroupSelf.isDistroGroup(ownMember: chat.ownMember, device: ownHashHex) {
                print("[GroupChat] relay_req for D-group \(groupId.prefix(8)) from \(srcHex.prefix(8)): not acted on (§12.3)")
                return
            }
            handleGroupRelayRequest(srcHex: srcHex, content: content, fields: fields,
                                    groupId: groupId, standing: standing, signature: signature)
        case GroupAction.relayDone:
            print("[GroupChat] relay-done from \(srcHex.prefix(8)) for group \(groupId.prefix(8))")
        case nil:
            // A plain post, kept for a group held here whoever sent it, and
            // shown as its GROUP_SENDER's only when a current member of a
            // joined group relays a listed member's post (groupAuthor).
            guard let chat = standing.chat else { return }
            let author = groupAuthor(fields: fields, sourceHex: srcHex, standing: standing, signature: signature)
            // REACTIONS-DESIGN.md §4: a Group reaction is attributed as a post is (GROUP_SENDER
            // when relayed, the same member rules) and names its target by post id, in this group.
            if tookReaction(fields, chatId: chat.id, inGroup: true, reactor: author, timestamp: timestamp, path: "group") {
                return
            }
            handleGroupChatMessage(hash: hash, content: content, timestamp: timestamp, fields: fields,
                                   chat: chat,
                                   author: author,
                                   selfAddresses: groupSelf(chat, rows: standing.members), ownAct: ownAct)
        default:
            // Until 2026-10-05 an action this client does not know was
            // stored as a plain post.
            print("[GroupChat] unrecognised action \(action ?? "") from \(srcHex.prefix(8)) for group \(groupId.prefix(8))")
        }
    }

    /// DeliveryPolicy.author for a message of the group in `standing`.
    private func groupAuthor(fields: LxmfFields, sourceHex: String, standing: GroupStanding,
                             signature: Int) -> String {
        let named = DeliveryPolicy.hash(fields.groupSender)
        let listed = named.map { GroupMemberStatuses.statusOf(standing.members, $0) != nil } ?? false
        return DeliveryPolicy.author(groupSender: named, source: sourceHex, held: standing.held,
                                     sourceStatus: standing.sourceStatus, senderListed: listed,
                                     signature: signature)
    }

    /// An invite from `srcHex` the rule kept (a source the privacy filter
    /// allows, for a group the user never declined or left, not forged).
    ///
    /// Each listed member whose key checks out is kept (the user's accept
    /// needs every key). Nobody passes the privacy filter by it: the members
    /// pass from the user's accept (James, 2026-10-01: "If the invite is
    /// accepted, the other group members are considered allowed"; RFed-spec
    /// Group.md, "The privacy filter", 2026-10-06), and the creator's answer
    /// to that accept (`status`) brings back the accepts the filter dropped
    /// before. Between 2026-10-05 and that change the members and the
    /// inviter were let through as the invite was processed, as v0.1.8 does.
    /// A group held here keeps the list its creation or first invite gave it
    /// (James, 2026-10-01: "There are no membership changes for a group"):
    /// another invite brings keys only, for members on that list. Until
    /// 2026-10-05 a later invite marked its sender accepted, adding it. The
    /// invite's source is recorded as the group's creator, once, with the
    /// group: a `status` counts only from it.
    private func handleGroupInvite(srcHex: String, timestamp: Double, fields: LxmfFields,
                                   groupId: String, standing: GroupStanding, hashHex: String = "") {
        guard let ctx = modelContext else { return }
        let held = standing.chat != nil
        if !held {
            guard fields.groupMembers != nil else {
                print("[GroupChat] invite for \(groupId.prefix(8)) from \(srcHex.prefix(8)) lists no members: ignored")
                return
            }
            // A group id that is another chat's id (a DM's) names no group of
            // ours: an invite never replaces that chat.
            let clash = FetchDescriptor<ChatEntity>(predicate: #Predicate { $0.id == groupId })
            if (try? ctx.fetch(clash).first) != nil {
                print("[GroupChat] invite for \(groupId.prefix(8)) from \(srcHex.prefix(8)) names another chat: ignored")
                return
            }
        }

        func distinct(_ hashes: [String]) -> [String] {
            var seen = Set<String>()
            return hashes.filter { seen.insert($0).inserted }
        }
        let listed = DeliveryPolicy.members(fields.groupMembers)
        // Whose keys this invite may bring: the held list, or for a new group
        // the list it gives, with its inviter.
        let members = held ? distinct(standing.members.map(\.hash)) : distinct(listed + [srcHex])
        // The group's own address (GROUPS-DISTRO-DESIGN.md §8.1): D when the list names the
        // distro this device holds now, else the device when listed; an invite listing neither
        // is not for this user (§9.3). Never the user's own key, for any self address (§9.2).
        let ownMember = standing.chat.map { $0.ownMember ?? ownHashHex }
            ?? GroupSelf.ownMemberForInvite(listed: listed, device: ownHashHex, heldDistro: heldDistroHex)
        let selfAddresses = GroupSelf.addresses(ownMember: ownMember, device: ownHashHex, listed: members,
                                                heldDistro: heldDistroHex, siblings: knownSiblings(of:))

        for (memberHash, keyBase64) in fields.groupMemberKeys ?? [:] {
            guard let hash = DeliveryPolicy.hash(memberHash), members.contains(hash), !selfAddresses.contains(hash),
                  let hashData = Data(hexString: hash),
                  let publicKey = Data(base64Encoded: keyBase64), publicKey.count == 64 else { continue }
            guard bridge.rememberLxmfDelivery(destHash: hashData, publicKey: publicKey) else {
                print("[GroupChat] ignored a member key that does not hash to \(hash.prefix(8))")
                continue
            }
            // The key is kept (the user's accept waits for every one). Nobody passes the privacy
            // filter by an invite: the members pass from the user's accept.
        }
        // A key this invite brought may be one an accept or leave is held for (from the switch):
        // each such one is decided now.
        groupStatuses.decideHeld()

        if let chat = standing.chat {
            print("[GroupChat] invite for held group \(chat.id.prefix(8)) from \(srcHex.prefix(8)): member keys only")
            try? ctx.save()
            return
        }

        // A new group, pending until the user accepts or declines it. The
        // inviter started it, so it is accepted; everyone else is invited.
        // The user is on it only as listed: no self-add (§9.3).
        guard let ownMember else {
            print("[GroupChat] invite for \(groupId.prefix(8)) from \(srcHex.prefix(8)) lists neither this device nor its distro: not for this user, dropped (§9.3)")
            try? ctx.save()
            return
        }
        let groupName = fields.groupName ?? "Group"
        ctx.insert(ChatEntity(id: groupId, peerHash: srcHex, isGroup: true,
                              groupName: groupName, groupStatus: "pending", creatorHash: srcHex,
                              ownMember: ownMember == ownHashHex ? nil : ownMember,
                              membersCsv: fields.groupMembersRaw))
        for memberHash in distinct(listed + [srcHex]) {
            ctx.insert(GroupMemberEntity(groupId: groupId, memberHash: memberHash,
                                         inviteStatus: memberHash == srcHex ? MemberStatus.accepted
                                                                            : MemberStatus.invited))
        }
        print("[GroupChat] pending group \(groupId.prefix(8)) from an invite by \(srcHex.prefix(8))")
        // §6.5: the filter has now admitted this group here. An id it recorded from an earlier
        // inviter it dropped (a co-member's own invite, §11.2) leaves the filtered-invite set, so
        // the pending group's traffic is held as for any pending group.
        if prefs.filteredInviteIds.contains(groupId) {
            prefs.filteredInviteIds = FilteredInvites.remove(prefs.filteredInviteIds, groupId)
            print("[GroupChat] \(groupId.prefix(8)) leaves the filtered-invite set: an invite for it was admitted (§6.5)")
        }

        // Insert a system message representing the invite notification. The
        // inviter's name is resolved when shown (DisplayNames.subjectToken).
        let inviteMsgId = "inv_\(groupId.prefix(16))"
        let dupDesc = FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.id == inviteMsgId })
        if (try? ctx.fetch(dupDesc).first) == nil {
            let msg = MessageEntity(
                id: inviteMsgId, chatId: groupId, senderHash: srcHex,
                content: "Group invite from \(DisplayNames.subjectToken): \"\(groupName)\"",
                timestamp: timestamp, isOutgoing: false, deliveryState: DeliveryState.delivered
            )
            insertMessage(msg, into: ctx)
        }

        updateChatTimestamp(chatId: groupId, timestamp: timestamp)
        try? ctx.save()

        // The NSE already alerted for an invite it counted (GROUPS-DISTRO-DESIGN.md §6.7).
        if PendingNotification.takeNSECountedGroupHash(hashHex) {
            print("[GroupChat] invite \(hashHex.prefix(8)) was shown by the notification service: not notified again")
        } else {
            notifManager.postMessageNotification(
                chatId: groupId,
                senderName: contactDisplayName(for: srcHex),
                content: "Group invite: \"\(groupName)\" — tap to accept or decline"
            )
        }
        refreshChats()
    }

    /// The group a stored chat is, as the group engine reads it.
    private static func groupInfo(_ chat: ChatEntity) -> GroupChatInfo {
        GroupChatInfo(id: chat.id, creatorHex: chat.creatorHash, groupStatus: chat.groupStatus)
    }

    /// The system line about a member who joined or left, written by the group store after
    /// the engine moved the member (GroupStatusEngine.applyChange decides what changes, and when
    /// nothing does, no line: a member that left stays left, an accept from one already accepted
    /// is nothing new, a decline arrives as a leave from a member still invited). The name is
    /// resolved when shown, DisplayNames.subjectToken. A leave's id is "left_" + the message hash
    /// (a system message, DisplayNames.isSystemMessageId); a join's is the engine's `acc_...`.
    private func insertGroupMemberLine(chatId groupId: String, memberHex: String, joined accepted: Bool,
                                       id: String, timestamp: Double) {
        guard let ctx = modelContext else { return }
        let sysId = accepted ? id : "left_" + id
        let dupDesc = FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.id == sysId })
        if (try? ctx.fetch(dupDesc).first) == nil {
            let msg = MessageEntity(
                id: sysId, chatId: groupId, senderHash: memberHex,
                content: accepted ? "\(DisplayNames.subjectToken) joined the group"
                                  : "\(DisplayNames.subjectToken) left the group",
                timestamp: accepted ? Date().timeIntervalSince1970 : timestamp,
                isOutgoing: false, deliveryState: DeliveryState.delivered
            )
            insertMessage(msg, into: ctx)
        }
        if !accepted { updateChatTimestamp(chatId: groupId, timestamp: timestamp) }
        try? ctx.save()
        refreshChats()
    }

    /// Another member is asking us to relay their message. The rule took it
    /// only from a member that accepted a group the user joined, signed by
    /// it; until 2026-10-05 this relayed for anyone, and for a pending group.
    private func handleGroupRelayRequest(
        srcHex: String, content: String, fields: LxmfFields, groupId: String,
        standing: GroupStanding, signature: Int
    ) {
        guard let client = lxmfClient else {
            print("[GroupChat] relay_req: stack offline, cannot relay")
            return
        }
        let originalSender = groupAuthor(fields: fields, sourceHex: srcHex, standing: standing,
                                         signature: signature)
        let alreadySeen = (fields.groupRelaySeen ?? []).compactMap { DeliveryPolicy.hash($0) }
        let accepted = GroupMemberStatuses.acceptedMembers(
            standing.members, selfAddresses: standing.chat.map { groupSelf($0, rows: standing.members) } ?? [ownHashHex])
        let groupName = standing.chat?.groupName ?? "Group"
        // REACTIONS-DESIGN.md §4: a relay request carries what is relayed, so the post id and a
        // reaction go on every relayed copy. A 0x40 this client refuses is not relayed: relayed
        // without it, it would reach the members as an empty post.
        let reaction: (to: Data, content: String)?
        switch fields.reaction {
        case nil:
            reaction = nil
        case .react(let to, let content)?:
            reaction = (to, content)
        case .refused(let why)?:
            print("[GroupChat] relay_req from \(srcHex.prefix(8)) for group \(groupId.prefix(8)) not relayed: reaction dropped: \(why)")
            return
        }
        let postId = fields.groupPostId

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
                postId: postId,
                reaction: reaction,
                via: client
            )
        }
    }

    /// Regular group content message, stored as `author`'s (groupAuthor).
    ///
    /// GROUPS-DISTRO-DESIGN.md §9.2: what counts as the user's own is decided by
    /// the packet source (admitGroupMessage dropped a self author from another
    /// source). A post from a self address (`selfAddresses`: the device, or a
    /// known sibling acting as its listed entry, `ownAct`) is stored as the
    /// user's own outgoing post, SENT, with no notification.
    private func handleGroupChatMessage(
        hash: Data, content: String, timestamp: Double, fields: LxmfFields,
        chat: ChatEntity, author: String, selfAddresses: Set<String> = [], ownAct: Bool = false
    ) {
        guard let ctx = modelContext else { return }
        let groupId = chat.id
        let msgHashHex = hash.hexString

        // Dedup
        let dupDesc = FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.id == msgHashHex })
        if let _ = try? ctx.fetch(dupDesc).first { return }

        // The group's name, when the chat has none yet.
        if let groupName = fields.groupName, chat.groupName == nil { chat.groupName = groupName }

        let own = ownAct || author == ownHashHex || selfAddresses.contains(author)
        let msg = MessageEntity(
            id: msgHashHex, chatId: groupId, senderHash: author,
            content: content, timestamp: timestamp,
            isOutgoing: own,
            deliveryState: own && author != ownHashHex ? DeliveryState.sent : DeliveryState.delivered,
            lxmfHash: msgHashHex,
            // REACTIONS-DESIGN.md §4: the post's id, what a Group reaction names.
            postId: fields.groupPostId
        )
        insertMessage(msg, into: ctx)

        for (filename, data) in fields.attachments {
            ctx.insert(AttachmentEntity(
                id: UUID().uuidString, messageId: msgHashHex, filename: filename, data: data
            ))
        }

        updateChatTimestamp(chatId: groupId, timestamp: timestamp)
        try? ctx.save()

        if own {
            // The user's own post: no notification.
        } else if PendingNotification.takeNSECountedGroupHash(msgHashHex) {
            // The NSE already alerted for it (GROUPS-DISTRO-DESIGN.md §6.7).
            print("[GroupChat] post \(msgHashHex.prefix(8)) was shown by the notification service: not notified again")
        } else {
            let senderName = contactDisplayName(for: author)
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

        let hex = destHash.hexString
        // The key an announce brings may be one an accept or leave is held for (from the switch).
        groupStatuses.decideHeld(source: hex)
        // Remember that this address is a distro (announce app_data carried
        // SF_RFED_DISTRO, SPEC §17.10) — the ONLY source of that fact; links
        // never set it. Before any early return: a distro announce carries no
        // name. Only ever set, never cleared (Android kt:1367-1400). The lookup
        // reads the Rust destination table, so it runs on ffiQueue.
        let bridgeRef = bridge
        ffiQueue.async { [weak self] in
            guard bridgeRef.peerIsDistro(destHash: destHash) else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.prefs.isDistroContact(hex) else { return }
                self.prefs.setDistroContact(hex, true)
                print("[Retichat] \(hex.prefix(8)) announced as a distro address")
            }
        }

        // Counted before anything can return early: a cache lookup begun
        // before this announce must not overwrite what it carries
        // (refreshAnnounceNameFromCache).
        announceGeneration[hex, default: 0] &+= 1

        guard let ctx = modelContext else { return }

        let descriptor = FetchDescriptor<ContactEntity>(
            predicate: #Predicate { $0.destHash == hex }
        )
        // The announce name (DISPLAY_NAMES.md §5.1 announceName), cleaned
        // by the Rust side: replaced on every announce, none when the
        // announce carries none. The other two slots are never touched. An
        // old web build can still announce "<name> (<first 12 hex>)": the
        // suffix goes (§5.4).
        let announceName = (displayName?.isEmpty ?? true)
            ? nil : displayName.map { DisplayNames.stripOwnHashSuffix($0, ownHash: hex) }
        if let contact = try? ctx.fetch(descriptor).first {
            if contact.announceName != announceName {
                contact.announceName = announceName
                namesChanged()
            }
            contact.lastSeen = Date().timeIntervalSince1970
            try? ctx.save()
            scheduleRefreshChats()  // debounced: coalesces announce bursts
        } else if let name = announceName, !prefs.filterStrangers {
            // Only auto-create a contact stub from announces when the stranger
            // filter is off — otherwise we'd be storing data for unknown senders.
            let contact = ContactEntity(
                destHash: hex,
                announceName: name,
                lastSeen: Date().timeIntervalSince1970
            )
            ctx.insert(contact)
            try? ctx.save()
            namesChanged()
        }
    }

    // MARK: - Chat management

    func createDirectChat(destHash: String, publicKey: Data? = nil) -> String {
        let normalizedHash = destHash.lowercased()

        // Unarchive if the chat already exists but was archived
        if let ctx = modelContext {
            let descriptor = FetchDescriptor<ChatEntity>(
                predicate: #Predicate { $0.id == normalizedHash }
            )
            if let existing = try? ctx.fetch(descriptor).first, existing.isArchived {
                existing.isArchived = false
                try? ctx.save()
            }
        }

        ensureChat(id: normalizedHash, peerHash: normalizedHash)
        // Every caller is the user adding this peer (Add Contact, New
        // Conversation, a QR code, an lxma:// link): a contact.
        addContact(destHash: normalizedHash)

        // Seed the scanned public key when present, then request a path and
        // keep watching announces so backbone-routed peers become reachable.
        if let hashData = Data(hexString: normalizedHash) {
            if let publicKey, publicKey.count == 64 {
                // Hash-checked: the key must hash to this lxmf.delivery address
                // (Android DistroContacts.adopt → identityRememberLxmfDelivery).
                if bridge.rememberLxmfDelivery(destHash: hashData, publicKey: publicKey) {
                    print("[Retichat] createDirectChat: seeded identity for \(normalizedHash.prefix(8))")
                } else if let error = bridge.rnsLastError() {
                    print("[Retichat] createDirectChat: failed to seed identity \(normalizedHash.prefix(8)): \(error)")
                }
            }

            RetichatBridge.shared.watchAnnounce(destHash: hashData)
            lxmfClient?.watch(destHash: hashData)
            _ = bridge.transportRequestPath(destHash: hashData)
            // A name already cached from an earlier announce (audit M10).
            refreshAnnounceNameFromCache(destHash: normalizedHash)
        }

        refreshChats()
        return normalizedHash
    }

    /// Create a group with `memberHashes` and invite them. The creator's own entry is the
    /// group's own address (GROUPS-DISTRO-DESIGN.md §8.1, §8.5): the distro D when this device
    /// holds it (recorded creator D, invite chunks signed by D, D's chunk carrying D's key from
    /// DistroManager, one `create` group sync owed once the chunks are built), otherwise the
    /// device. Nil, with nothing written, queued or retried, unless a group can be created now
    /// (`canCreateGroup`; the forms grey Create until then, with no text, §8.7).
    func createGroupChat(name: String, memberHashes: [String]) -> String? {
        // Running means what it means for a send: the start finished (releaseHeldSends opened
        // the gate) and the stack is held. nil while it is starting or stopped.
        guard canCreateGroup, let ctx = modelContext, let client = heldSends.isOpen ? lxmfClient : nil else {
            print("[GroupChat] group not created: the start has not finished, or the distro is still being read (§8.7)")
            return nil
        }
        guard let signer = creationSigner() else {
            // canCreateGroup let it through, so D is loaded or settled: only an identity the
            // stack cannot give now leaves no signer.
            print("[GroupChat] group not created: no identity to sign its invites with")
            return nil
        }
        let own = signer.hex

        // Generate a 16-byte random group ID → 32-char hex string (Android-compatible)
        var randomBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &randomBytes)
        let groupId = randomBytes.map { String(format: "%02x", $0) }.joined()

        // Every member but the user, then the group's own address: never the device in a group
        // created as D, never a sibling (§9.2).
        let userAddresses = signer.isDistro
            ? Set([ownHashHex, own] + knownSiblings(of: own)) : Set([ownHashHex])
        var allMembers = memberHashes.filter { !userAddresses.contains($0) }
        allMembers.append(own)
        let membersCsv = allMembers.joined(separator: ",")

        // Seconds, like every other chat time (ChatListView formats seconds).
        let now = Date().timeIntervalSince1970
        let chat = ChatEntity(
            id: groupId, peerHash: "", lastMessageTime: now,
            isGroup: true, groupName: name, groupStatus: "active", creatorHash: own,
            ownMember: signer.isDistro ? own : nil, membersCsv: membersCsv
        )
        ctx.insert(chat)

        for memberHash in allMembers {
            let status = memberHash == own ? MemberStatus.accepted : MemberStatus.invited
            let member = GroupMemberEntity(groupId: groupId, memberHash: memberHash,
                                           inviteStatus: status)
            ctx.insert(member)
            // Not the user: no contact of its own (audit L4).
            guard memberHash != own else { continue }
            ensureAllowlistedContact(destHash: memberHash)
            if let hashData = Data(hexString: memberHash) {
                RetichatBridge.shared.watchAnnounce(destHash: hashData)
            }
        }
        // No contact row for the group id: group messages pass on the group
        // policy (groupMessagePolicy), never on the allowlist, and the row
        // showed up as a phantom contact in the pickers (audit L4).

        try? ctx.save()

        // Send invites to everyone except the user (fire-and-forget). The stack is running
        // (canCreateGroup), so every invite is signed and goes.
        var memberPublicKeys: [String: String] = [:]
        for memberHash in allMembers {
            guard let hashData = Data(hexString: memberHash) else { continue }
            let publicKey = memberHash == own
                ? signer.publicKey
                : bridge.recalledPublicKey(destHash: hashData)
            if let publicKey, publicKey.count == 64 {
                memberPublicKeys[memberHash] = publicKey.hexString
            }
        }
        let targets = allMembers.filter { $0 != own }
        let atMs = DistroGroupSync.atMs(now)
        ffiQueue.async { [weak self] in
            let keys = GroupChatManager.shared.sendInvites(
                groupId: groupId,
                groupName: name,
                allMembers: allMembers,
                memberPublicKeys: memberPublicKeys,
                targets: targets,
                as: signer,
                via: client
            )
            // §10.6: the `create` group sync, once the invite chunks are built.
            guard signer.isDistro, let keys else { return }
            Task { @MainActor [weak self] in
                self?.oweGroupSync(.create, groupId: groupId, signer: signer, atMs: atMs, name: name,
                                   membersCsv: membersCsv, keys: keys)
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

    /// Delete a conversation. A group's is left (quitGroup): the members
    /// are told, and the group is closed for good (James, 2026-10-05). Until
    /// then a group's delete dropped the chat here only: its members went on
    /// counting the user, and a later invite brought it back.
    func deleteChat(chatId: String) {
        if let ctx = modelContext,
           let chat = try? ctx.fetch(FetchDescriptor<ChatEntity>(predicate: #Predicate { $0.id == chatId })).first,
           chat.isGroup {
            quitGroup(chatId: chatId, how: "deleted")
            return
        }
        deleteChatLocal(chatId: chatId)
    }

    /// Permanently delete a chat and all its messages and attachments, here
    /// only. `forgetHeld` false keeps what was held for a group until it is
    /// joined (a pending invite discarded for the user's own group sync,
    /// GROUPS-DISTRO-DESIGN.md §11.2).
    private func deleteChatLocal(chatId: String, forgetHeld: Bool = true) {
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
        chatPreviewMemo[chatId] = nil  // its messages are gone (see chatPreviewMemo)

        // Delete group members if applicable
        let memberDescriptor = FetchDescriptor<GroupMemberEntity>(
            predicate: #Predicate { $0.groupId == chatId }
        )
        if let members = try? ctx.fetch(memberDescriptor) {
            for member in members { ctx.delete(member) }
        }
        // The creator's copies and the entries held for a key go with the group, and so does
        // what was held for it until it was joined here (GROUPS-DISTRO-DESIGN.md §6.5).
        SwiftDataGroupStatusStore.deleteRows(groupId: chatId, in: ctx)
        if forgetHeld { forgetHeldArrivals(groupId: chatId, why: "its group is gone from this device") }

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

        let names = contactNameIndex()
        let selves = groupSelves(entities)

        return entities.compactMap { entity -> Chat? in
            let displayName: String
            if entity.isGroup {
                displayName = entity.groupName ?? "Group"
            } else {
                displayName = label(for: entity.peerHash, in: names)
            }
            guard displayName.localizedCaseInsensitiveContains(lower) ||
                  entity.peerHash.localizedCaseInsensitiveContains(lower) else { return nil }

            let lastMsg = try? lastMessage(forChatId: entity.id)
            // §8.7: a found group's swipe offers what the list's does.
            let ability: GroupSelf.Ability = entity.isGroup ? self.ability(entity) : .acts
            return Chat(
                id: entity.id,
                peerHash: entity.peerHash,
                displayName: displayName,
                lastMessage: lastMsg.map { shownText($0.content, id: $0.id, senderHash: $0.senderHash, names: names,
                                                     groupSelf: selves[entity.id]) } ?? "",
                lastMessageTime: entity.lastMessageTime,
                unreadCount: 0,
                isArchived: entity.isArchived,
                isGroup: entity.isGroup,
                groupName: entity.groupName,
                groupStatus: entity.groupStatus,
                isDistroGroup: entity.isGroup && GroupSelf.isDistroGroup(ownMember: entity.ownMember, device: ownHashHex),
                groupActionsWait: ability.waits,
                formerDistroText: ability.formerDistroText
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

        // Every sender's name, resolved now (DISPLAY_NAMES.md §5.3); in a group, "You" for
        // exactly that group's self addresses (GROUPS-DISTRO-DESIGN.md §9.1).
        let names = contactNameIndex()
        let me = groupSelf(forChatId: chatId)
        let siblings = knownSiblingAddresses()
        // REACTIONS-DESIGN.md §3, §7: whose chips are the user's, and whether the chat is a group.
        let chat = try? ctx.fetch(FetchDescriptor<ChatEntity>(predicate: #Predicate { $0.id == chatId })).first
        let isGroup = chat?.isGroup ?? false
        let reactors = chat.map(reactionSelf) ?? [ownHashHex]

        // Reverse back to chronological order for display
        return entities.reversed().map { entity in
            let attachments = attachmentsByMsg[entity.id] ?? []
            let senderName = label(for: entity.senderHash, in: names, groupSelf: me)
            // A known sibling's own join or leave is "Your other device", not "You".
            let subject = GroupSelf.memberLineSubject(entity.senderHash, messageId: entity.id, groupSelf: me,
                                                      device: ownHashHex, siblings: siblings) ?? senderName
            return ChatMessage(
                id: entity.id,
                senderHash: entity.senderHash,
                senderName: senderName,
                content: DisplayNames.systemText(entity.content, messageId: entity.id, subject: subject),
                timestamp: entity.timestamp,
                isOutgoing: entity.isOutgoing,
                deliveryState: entity.deliveryState,
                attachments: attachments,
                // No bar from here: it is the DIRECT attempt's progress,
                // read off the main actor by ConversationViewModel on every
                // tick (liveUploads, uploadBars; UploadProgress.swift).
                uploadProgress: nil,
                nativeHandle: entity.nativeHandle,
                reactions: Reactions.chips(entity.reactionsJson, me: reactors)
                    .map { ReactionChip(emoji: $0.emoji, count: $0.count, mine: $0.mine) },
                reactionsJson: entity.reactionsJson,
                reactable: !DisplayNames.isSystemMessageId(entity.id)
                    && Reactions.target(isGroup: isGroup, id: entity.id, lxmfHash: entity.lxmfHash,
                                        postId: entity.postId) != nil
            )
        }
    }

    // MARK: - Upload progress (read off the main actor)

    /// The rows whose DIRECT attempt is read for a bar (UploadProgress.isLive),
    /// with its handle: those whose pending entry holds the row's handle.
    /// Main actor, no FFI.
    func liveUploads(in rows: [ChatMessage]) -> [(id: String, handle: UInt64)] {
        rows.compactMap { row in
            UploadProgress.isLive(isOutgoing: row.isOutgoing,
                                  withAttachments: !row.attachments.isEmpty,
                                  nativeHandle: row.nativeHandle,
                                  pendingHandle: pendingOutbound[row.id]?.msgHandle)
                ? (id: row.id, handle: row.nativeHandle) : nil
        }
    }

    /// Each live row's bar (UploadProgress.bar; nil for none), read on
    /// ffiQueue: lxmf_message_state and lxmf_message_progress take the
    /// message's lock, which the router holds for its pass over the message
    /// and the Resource takes after each request it serves, so never on the
    /// main actor (§6). A handle released meanwhile reads as unknown: no bar.
    func uploadBars(for live: [(id: String, handle: UInt64)]) async -> [String: Float?] {
        await withCheckedContinuation { continuation in
            ffiQueue.async {
                continuation.resume(returning: Self.readUploadBars(live))
            }
        }
    }

    /// nonisolated: runs on ffiQueue, so it uses DistroMessageFFI's
    /// nonisolated wrappers (LxmfClient's statics are main-actor isolated).
    nonisolated private static func readUploadBars(_ live: [(id: String, handle: UInt64)]) -> [String: Float?] {
        var bars: [String: Float?] = [:]
        for upload in live {
            bars[upload.id] = UploadProgress.bar(state: DistroMessageFFI.state(upload.handle),
                                                 progress: DistroMessageFFI.progress(upload.handle))
        }
        return bars
    }

    /// Lightweight query returning only (id, deliveryState, reactionsJson) —
    /// no attachment blobs, no FFI calls.  Used by the refresh timer to decide
    /// whether a full reload is needed; a reaction changes only the JSON.
    func messagesSummary(forChatId chatId: String, limit: Int = 50) -> [(String, Int, String?)] {
        guard let ctx = modelContext else { return [] }
        var descriptor = FetchDescriptor<MessageEntity>(
            predicate: #Predicate { $0.chatId == chatId },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        guard let entities = try? ctx.fetch(descriptor) else { return [] }
        return entities.reversed().map { ($0.id, $0.deliveryState, $0.reactionsJson) }
    }

    /// The contacts the user added (ContactRows.isListed: Contacts, New
    /// Chat and the New Group picker), named by the resolver and sorted by
    /// that name. Group members, channel posters and strangers have hidden
    /// rows and are not listed (James, 2026-10-02); until 2026-10-05 every
    /// allowlisted row was, so each member of a group became a contact.
    /// Never this device's own address or the distro's, nor a group id:
    /// older builds made allowlisted rows for both, which the pickers showed
    /// as contacts (audit L4).
    func contacts() -> [Contact] {
        guard let ctx = modelContext,
              let entities = try? ctx.fetch(FetchDescriptor<ContactEntity>()) else { return [] }
        let groupIds = Set(((try? ctx.fetch(FetchDescriptor<ChatEntity>(
            predicate: #Predicate { $0.isGroup == true }))) ?? []).map(\.id))
        return entities
            .filter { ContactRows.isListed(isContact: $0.isContact, isAllowlisted: $0.isAllowlisted)
                && !groupIds.contains($0.destHash) && !isOwnAddress($0.destHash) }
            .map { Contact(id: $0.destHash,
                           displayName: resolvedName($0) ?? DisplayNames.shortHash($0.destHash),
                           lastSeen: $0.lastSeen) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
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
            // §6.7: the NSE's inviters are the allowlist.
            scheduleNSEGroupsWrite()
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
        var previewByChat: [String: (id: String, content: String, senderHash: String)] = [:]
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
                    if previewByChat[m.chatId] == nil {
                        // Sorted newest first, so a chat's first hit here is
                        // its newest message: remember it for when it drops out.
                        previewByChat[m.chatId] = (m.id, m.content, m.senderHash)
                        chatPreviewMemo[m.chatId] = (m.id, m.content, m.senderHash)
                    }
                }
            }
            // The window above holds the newest messages across ALL chats, so
            // one busy chat pushes a quieter chat's last message out of it and
            // that row showed an empty preview. Those chats take the memo;
            // only a chat never seen, or changed since (see chatPreviewMemo),
            // is looked up, and "no messages" is remembered as "" too.
            for id in chatIds where previewByChat[id] == nil {
                if let memo = chatPreviewMemo[id] {
                    previewByChat[id] = memo
                } else {
                    do {
                        let last = try lastMessage(forChatId: id)
                        let preview = (last?.id ?? "", last?.content ?? "", last?.senderHash ?? "")
                        chatPreviewMemo[id] = preview
                        previewByChat[id] = preview
                    } catch {
                        // Not memoized, so a failed read is never remembered
                        // as an empty chat.
                        print("[Retichat] refreshChats: last-message fetch for \(id.prefix(8)) failed: \(error)")
                    }
                }
            }
        }

        // Every contact's name slots in one fetch (DISPLAY_NAMES.md §5.3)
        let entries = contactNameEntries()
        let names = entries.mapValues { Optional($0.name) }
        // In a group, "You" for exactly that group's self addresses (GROUPS-DISTRO-DESIGN.md §9.1).
        let selves = groupSelves(chatEntities)

        chats = chatEntities.map { entity in
            let displayName: String
            if entity.isGroup {
                displayName = entity.groupName ?? "Group"
            } else {
                displayName = label(for: entity.peerHash, in: names)
            }
            let preview = previewByChat[entity.id].map {
                shownText($0.content, id: $0.id, senderHash: $0.senderHash, names: names, groupSelf: selves[entity.id])
            } ?? ""
            // §8.7: what the group offers now (a direct chat acts).
            let ability: GroupSelf.Ability = entity.isGroup ? self.ability(entity) : .acts

            return Chat(
                id: entity.id,
                peerHash: entity.peerHash,
                displayName: displayName,
                lastMessage: preview,
                lastMessageTime: entity.lastMessageTime,
                unreadCount: 0,
                isArchived: entity.isArchived,
                isGroup: entity.isGroup,
                groupName: entity.groupName,
                groupStatus: entity.groupStatus,
                isDistroGroup: entity.isGroup && GroupSelf.isDistroGroup(ownMember: entity.ownMember, device: ownHashHex),
                groupActionsWait: ability.waits,
                formerDistroText: ability.formerDistroText
            )
        }

        // Every contact's resolved name (never a placeholder; a contact
        // without a name is left out) for the NSE's notification titles,
        // keyed by the hash messages come from, so a group invite no longer
        // overwrites its inviter's name (audit M3). Each entry records its
        // slot and messageNameAt, so the NSE lets a newer 0xD1 in the
        // message beat any name but the user's own. File I/O, off the main
        // actor.
        let snapshot = entries
        Task.detached(priority: .utility) {
            PendingNotification.writeChatNames(snapshot)
        }
        // GROUPS-DISTRO-DESIGN.md §6.7: the groups, the filter, the inviters it lets through and
        // the closed ids, for the NSE's group notifications, on every change.
        writeNSEGroupsNow()
    }

    /// §6.7: nse_groups.json, written now (file I/O off the main actor). Every refresh writes it,
    /// and so do the filter's switch and every allowlist change (scheduleNSEGroupsWrite).
    private func writeNSEGroupsNow() {
        let groupsSnapshot = nseGroupsSnapshot()
        Task.detached(priority: .utility) {
            PendingNotification.writeNSEGroups(groupsSnapshot)
        }
    }

    /// writeNSEGroupsNow, coalescing back-to-back changes (the members a create or an accept
    /// allowlists) into one write after 50 ms, as scheduleRefreshChats does.
    private var pendingNSEGroupsWrite = false

    private func scheduleNSEGroupsWrite() {
        guard !pendingNSEGroupsWrite else { return }
        pendingNSEGroupsWrite = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            self?.pendingNSEGroupsWrite = false
            self?.writeNSEGroupsNow()
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
            // Seconds. This was milliseconds until 2026-09-24, and because
            // updateChatTimestamp keeps the max, a chat opened by a new
            // sender kept a far-future time for ever ("Jun 24" in the list).
            let now = Date().timeIntervalSince1970
            let chat = ChatEntity(
                id: id, peerHash: peerHash, lastMessageTime: now,
                isGroup: isGroup, groupName: groupName
            )
            ctx.insert(chat)
            try? ctx.save()
        }
    }

    /// A hidden row for a peer the app keeps something about (a sender's
    /// names, a distro sent copy's recipient): not allowlisted, no contact.
    private func ensureContact(destHash: String) {
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<ContactEntity>(
            predicate: #Predicate { $0.destHash == destHash }
        )
        if let existing = try? ctx.fetch(descriptor), existing.isEmpty {
            let contact = ContactEntity(destHash: destHash, isContact: false)
            ctx.insert(contact)
            try? ctx.save()
        }
    }

    /// Let a peer through the privacy filter without making it a contact:
    /// a group member (the creation, the user's accept, a member's own accept
    /// in a group the user joined: never an invite's arrival). A new row is hidden; a row from
    /// before the contact flag keeps the listing it had, so allowlisting a
    /// row that was not listed never lists it (ContactRows.isListed).
    private func ensureAllowlistedContact(destHash: String) {
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<ContactEntity>(
            predicate: #Predicate { $0.destHash == destHash }
        )
        if let contact = try? ctx.fetch(descriptor).first {
            if contact.isAllowlisted != true {
                contact.isContact = ContactRows.isListed(isContact: contact.isContact,
                                                         isAllowlisted: contact.isAllowlisted)
                contact.isAllowlisted = true
                try? ctx.save()
                scheduleNSEGroupsWrite()  // §6.7: the NSE's inviters are the allowlist
            }
        } else {
            let contact = ContactEntity(destHash: destHash, isAllowlisted: true, isContact: false)
            ctx.insert(contact)
            try? ctx.save()
            scheduleNSEGroupsWrite()  // §6.7: the NSE's inviters are the allowlist
        }
    }

    /// The user added this peer (Add Contact, New Conversation, a QR code
    /// or an lxma:// link, all through createDirectChat): a contact, listed,
    /// and allowlisted. The one place a row becomes a contact.
    private func addContact(destHash: String) {
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<ContactEntity>(
            predicate: #Predicate { $0.destHash == destHash }
        )
        if let contact = try? ctx.fetch(descriptor).first {
            guard contact.isContact != true || contact.isAllowlisted != true else { return }
            contact.isContact = true
            contact.isAllowlisted = true
        } else {
            ctx.insert(ContactEntity(destHash: destHash, isAllowlisted: true, isContact: true))
        }
        try? ctx.save()
        scheduleNSEGroupsWrite()  // §6.7: the NSE's inviters are the allowlist
    }

    private enum AllowlistDecision {
        case allowedFilterDisabled
        case allowedContact
        case blockedMissingContact
        case blockedContactNotAllowlisted

        var isAllowed: Bool {
            switch self {
            case .allowedFilterDisabled, .allowedContact:
                return true
            case .blockedMissingContact, .blockedContactNotAllowlisted:
                return false
            }
        }

        var debugLabel: String {
            switch self {
            case .allowedFilterDisabled:
                return "filter-disabled"
            case .allowedContact:
                return "allowlisted-contact"
            case .blockedMissingContact:
                return "missing-contact"
            case .blockedContactNotAllowlisted:
                return "contact-not-allowlisted"
            }
        }
    }

    private func allowlistDecision(destHash: String) -> AllowlistDecision {
        guard prefs.filterStrangers else { return .allowedFilterDisabled }
        guard let ctx = modelContext else { return .blockedMissingContact }
        let descriptor = FetchDescriptor<ContactEntity>(
            predicate: #Predicate { $0.destHash == destHash }
        )
        guard let contact = try? ctx.fetch(descriptor).first else {
            return .blockedMissingContact
        }
        return contact.isAllowlisted == true ? .allowedContact : .blockedContactNotAllowlisted
    }

    /// Returns true if the given hash is in the contact allowlist.
    private func isAllowlisted(destHash: String) -> Bool {
        allowlistDecision(destHash: destHash).isAllowed
    }

    /// What the group rule asks about a message naming group `groupId` from
    /// a packet source: the group as held here (`chat`, its member rows),
    /// where the user stands in it, the source's status on its list (nil
    /// when not listed), whether the user declined or left it, and whether
    /// the source is the group's creator (a `status` counts only from it;
    /// false for a group whose creator is not recorded, one held before it
    /// was).
    private struct GroupStanding {
        let chat: ChatEntity?
        let members: [GroupMemberStatuses.Row]
        let held: DeliveryPolicy.Held
        let sourceStatus: String?
        let closed: Bool
        let sourceIsCreator: Bool
    }

    private func groupStanding(groupId: String, sourceHex: String) -> GroupStanding {
        var chat: ChatEntity?
        var rows: [GroupMemberStatuses.Row] = []
        if let ctx = modelContext {
            let chatDesc = FetchDescriptor<ChatEntity>(
                predicate: #Predicate { $0.id == groupId && $0.isGroup == true }
            )
            chat = try? ctx.fetch(chatDesc).first
            if chat != nil {
                let memberDesc = FetchDescriptor<GroupMemberEntity>(
                    predicate: #Predicate { $0.groupId == groupId }
                )
                rows = ((try? ctx.fetch(memberDesc)) ?? []).map { (hash: $0.memberHash, status: $0.inviteStatus) }
            }
        }
        return GroupStanding(
            chat: chat,
            members: rows,
            held: GroupMemberStatuses.held(groupExists: chat != nil, groupStatus: chat?.groupStatus),
            sourceStatus: GroupMemberStatuses.statusOf(rows, sourceHex),
            closed: ClosedGroups.contains(prefs.closedGroupIds, groupId),
            sourceIsCreator: chat?.creatorHash != nil && chat?.creatorHash == sourceHex
        )
    }

    /// What the group rule made of a group message (admitGroupMessage).
    private enum GroupAdmission {
        /// Kept, with the group as it stood. `ownAct`: its packet source is a known sibling of
        /// the user, an older device acting as its own listed entry (GROUPS-DISTRO-DESIGN.md §9.2).
        case kept(GroupStanding, ownAct: Bool)
        /// Dropped by §6.3's first rules (forged, the user's own echo, a self address named by
        /// someone else, a known sibling's message whose signature could not be checked): never
        /// held.
        case droppedFirst
        /// Dropped by the group rule, with the group as it stood: the distro path may hold it
        /// (§6.5).
        case dropped(GroupStanding)
    }

    /// James's group model (DeliveryPolicy.shouldProcess) for a group
    /// message from the packet source `sourceHex`: the group's standing
    /// when the message is kept, nil (logged) when it is dropped, before any
    /// write. Only an invite asks the privacy filter. Until 2026-10-05 every
    /// non-invite message for a group held here was processed, from any
    /// source, with GROUP_SENDER taken as its author.
    ///
    /// GROUPS-DISTRO-DESIGN.md §6.3: three rules come first, on both paths and
    /// in every group (GroupFirstRules): a forged message (unverified_reason 2)
    /// is dropped; one whose source is the user's distro D is the user's own
    /// echo, dropped; one naming a self address (§9.1) as its sender while its
    /// source is not one is dropped, never stored as the user's own.
    private func admitGroupMessage(groupId: String, sourceHex: String, fields: LxmfFields,
                                   signature: Int) -> GroupAdmission {
        let action = fields.groupAction
        let standing = groupStanding(groupId: groupId, sourceHex: sourceHex)
        let who = admissionSelf(standing: standing, fields: fields)
        switch GroupFirstRules.check(signature: signature, sourceHex: sourceHex, groupSender: fields.groupSender,
                                     selfAddresses: who.selfAddresses, distros: who.distros,
                                     siblings: who.siblings) {
        case .forged:
            print("[GroupChat] DROPPED forged \(action ?? "message") for \(groupId.prefix(8)) from \(sourceHex.prefix(8)): its signature does not verify (§6.3)")
            return .droppedFirst
        case .ownEcho:
            print("[GroupChat] DROPPED \(action ?? "message") for \(groupId.prefix(8)) from the user's own distro \(sourceHex.prefix(8)): the user's own echo (§6.3)")
            return .droppedFirst
        case .selfSenderFromOther:
            print("[GroupChat] DROPPED \(action ?? "message") for \(groupId.prefix(8)) from \(sourceHex.prefix(8)): it names the user as its sender, and its source is not the user's (§6.3)")
            return .droppedFirst
        case .selfSourceUnproven:
            print("[GroupChat] DROPPED \(action ?? "message") for \(groupId.prefix(8)) from \(sourceHex.prefix(8)), another device of the user's distro: its signature could not be checked, and only a validly signed one is the user's own (§9.2)")
            return .droppedFirst
        case .pass(let ownAct):
            let allowed = DeliveryPolicy.shouldProcess(
                action: action,
                sourceAllowed: action == GroupAction.invite && isAllowlisted(destHash: sourceHex),
                held: standing.held,
                sourceStatus: standing.sourceStatus,
                namesOther: DeliveryPolicy.namesOther(groupSender: fields.groupSender, source: sourceHex),
                closed: standing.closed,
                signature: signature,
                sourceIsCreator: standing.sourceIsCreator
            )
            guard allowed else {
                print("[GroupChat] DROPPED \(action ?? "message") for \(groupId.prefix(8)) from \(sourceHex.prefix(8)) (group \(standing.held), source \(standing.sourceStatus ?? "not listed"), closed=\(standing.closed), signature=\(signature), creator=\(standing.sourceIsCreator))")
                return .dropped(standing)
            }
            return .kept(standing, ownAct: ownAct)
        }
    }

    /// Who the user is for §6.3 in the group a message names: for a group held here its own
    /// self addresses (§9.1); for an invite to a group not held, those its list gives with the
    /// own address it would get (§8.1); for anything else about a group not held, every address
    /// of the user (the device, D and D's known siblings). `distros`: the D held now and the
    /// group's X, whose messages are the user's own echo.
    private func admissionSelf(standing: GroupStanding, fields: LxmfFields)
        -> (selfAddresses: Set<String>, distros: Set<String>, siblings: Set<String>) {
        let held = heldDistroHex
        let listed: [String]
        let ownMember: String?
        if let chat = standing.chat {
            listed = standing.members.map(\.hash)
            ownMember = chat.ownMember
        } else if fields.groupAction == GroupAction.invite {
            listed = DeliveryPolicy.members(fields.groupMembers)
            let own = GroupSelf.ownMemberForInvite(listed: listed, device: ownHashHex, heldDistro: held)
            ownMember = own == ownHashHex ? nil : own
        } else {
            var all: Set<String> = ownHashHex.isEmpty ? [] : [ownHashHex]
            var siblings: Set<String> = []
            if let held {
                all.insert(held)
                siblings = Set(knownSiblings(of: held))
                all.formUnion(siblings)
            }
            return (all, held.map { [$0] } ?? [], siblings)
        }
        let x = GroupSelf.distro(ownMember: ownMember, device: ownHashHex, listed: listed, heldDistro: held)
        let addresses = GroupSelf.addresses(ownMember: ownMember, device: ownHashHex, listed: listed,
                                            heldDistro: held, siblings: knownSiblings(of:))
        let siblings = x.map { Set(knownSiblings(of: $0)).intersection(addresses) } ?? []
        return (addresses, Set([held, x].compactMap { $0 }), siblings)
    }

    /// A distro identity transfer on the device address (RFed SPEC §17.9),
    /// offered only when the privacy filter lets its sender through (filter
    /// off: anyone; on: an allowlisted row), as the web and Android offer it
    /// (James, 2026-10-05). Offered or dropped, it is never a message.
    private func offerDistroTransfer(fromHashHex srcHex: String, privateKeyHex key: String, via path: String) {
        guard isAllowlisted(destHash: srcHex) else {
            print("[Retichat] \(path): DROPPED distro identity transfer from \(srcHex.prefix(8)): the privacy filter does not let it through")
            return
        }
        print("[Retichat] \(path): distro identity transfer from \(srcHex.prefix(8))")
        RfedDistroClient.shared.offerTransfer(fromHashHex: srcHex, privateKeyHex: key)
    }

    // MARK: - Groups for distro holders (GROUPS-DISTRO-DESIGN.md, James 2026-10-10)
    //
    // The user's distro D is a group member like any address. A group's own address
    // (ChatEntity.ownMember, §8.1) is the member the user acts as in it; every send in a
    // D-group is signed by D (groupSigner), never the device; what reaches D for a group is
    // routed here by RfedDistroClient (never the DM path, §6.4), and the group sync G tells the
    // user's other devices of D what the user did as D (§10, §11).

    /// The distro this device holds now, loaded; nil when none is.
    private var heldDistroHex: String? { DistroManager.shared.deliveryHashHex }

    /// Whether the Keychain has said what this device holds. A stored key that will not load is
    /// no distro; one not read yet (start-up, a background launch before the first unlock) may
    /// be D not loaded yet (§8.7).
    private var distroSettled: Bool {
        DistroManager.shared.isSettled || DistroManager.shared.storedKeyUnreadable
    }

    /// §9.1: the user's other devices of `distro`, learned, never queried.
    private func knownSiblings(of distro: String) -> [String] { prefs.distroSiblings[distro] ?? [] }

    /// §9.1: `by`, the 0xFD of a sync `distro` signed that this device accepted, is a sibling.
    private func learnSibling(_ by: String, of distro: String) {
        let known = prefs.distroSiblings
        let next = KnownSiblings.learn(known, by: by, distro: distro, device: ownHashHex)
        guard next != known else { return }
        prefs.distroSiblings = next
        print("[GroupChat] \(by.prefix(8)) is another device of the distro \(distro.prefix(8)): a known sibling (§9.1)")
        scheduleRefreshChats()
    }

    private func groupRows(_ groupId: String) -> [GroupMemberStatuses.Row] {
        guard let ctx = modelContext else { return [] }
        let desc = FetchDescriptor<GroupMemberEntity>(predicate: #Predicate { $0.groupId == groupId })
        return ((try? ctx.fetch(desc)) ?? []).map { (hash: $0.memberHash, status: $0.inviteStatus) }
    }

    /// The group's own address: the member the user acts as (§8.1); nil is the device.
    private func ownAddress(_ chat: ChatEntity) -> String { chat.ownMember ?? ownHashHex }

    /// The self addresses of a group held here (§9.1).
    private func groupSelf(_ chat: ChatEntity, rows: [GroupMemberStatuses.Row]) -> Set<String> {
        GroupSelf.addresses(ownMember: chat.ownMember, device: ownHashHex, listed: rows.map(\.hash),
                            heldDistro: heldDistroHex, siblings: knownSiblings(of:))
    }

    /// GroupStatusEngine's "me" (§9.2): the group's self addresses; for a group not held here,
    /// every address of the user.
    private func isGroupSelf(chatId: String, hex: String) -> Bool {
        if hex == ownHashHex { return true }
        if let ctx = modelContext,
           let chat = try? ctx.fetch(FetchDescriptor<ChatEntity>(predicate: #Predicate { $0.id == chatId })).first,
           chat.isGroup {
            return groupSelf(chat, rows: groupRows(chatId)).contains(hex)
        }
        guard let held = heldDistroHex else { return false }
        return hex == held || knownSiblings(of: held).contains(hex)
    }

    /// Who may sign for the group now (§8.1, §8.7).
    private func signerState(_ chat: ChatEntity) -> GroupSelf.Signer {
        GroupSelf.signer(ownMember: chat.ownMember, device: ownHashHex,
                         loadedDistro: DistroManager.shared.signing()?.info.deliveryHashHex,
                         distroSettled: distroSettled)
    }

    /// The start finished: the stack is held and the send gate open (releaseHeldSends), so a
    /// send goes now rather than waiting. What `serviceRunning` says to the views (both change in
    /// one main-actor step).
    private var startFinished: Bool { heldSends.isOpen && lxmfClient != nil }

    /// What this device offers in the group now (§8.7; James, 2026-10-11): it acts, it is in
    /// start-up (greyed, no text, posts wait), or the group uses a former distro (the bar).
    private func ability(_ chat: ChatEntity) -> GroupSelf.Ability {
        GroupSelf.ability(signerState(chat), started: startFinished)
    }

    /// Whether New group › Create is offered now (§8.1, §8.7): greyed, with no text, otherwise.
    var canCreateGroup: Bool {
        GroupSelf.canCreate(started: startFinished, distroLoaded: DistroManager.shared.signing() != nil,
                            distroSettled: distroSettled)
    }

    /// `groupSigner(ownMember)` (§8.1): resolved at send time from the group's own address and
    /// the distro this device holds then. The device for a group whose own address is the
    /// device; D only when `DistroManager.signing()` names exactly the group's own address;
    /// otherwise nil, and the action is refused with §8.7's text: never the device or another
    /// distro signing for a D-group.
    private func groupSigner(_ chat: ChatEntity) -> GroupSigner? {
        let signing = DistroManager.shared.signing()
        switch GroupSelf.signer(ownMember: chat.ownMember, device: ownHashHex,
                                loadedDistro: signing?.info.deliveryHashHex, distroSettled: distroSettled) {
        case .device:
            return deviceSigner()
        case .distro(let d):
            guard let signing, signing.info.deliveryHashHex == d, let hash = Data(hexString: d) else { return nil }
            return GroupSigner(hex: d, hash: hash, identityHandle: signing.handle,
                               publicKey: Data(hexString: signing.info.publicKeyHex), isDistro: true)
        case .distroNotLoaded, .formerDistro:
            return nil
        }
    }

    private func groupSigner(chatId: String) -> GroupSigner? {
        guard let ctx = modelContext,
              let chat = try? ctx.fetch(FetchDescriptor<ChatEntity>(predicate: #Predicate { $0.id == chatId })).first
        else { return nil }
        return groupSigner(chat)
    }

    /// The device as a group's signer: its own address and identity.
    private func deviceSigner() -> GroupSigner? {
        guard let client = lxmfClient, let hash = Data(hexString: ownHashHex), hash.count == 16 else { return nil }
        return GroupSigner(hex: ownHashHex, hash: hash, identityHandle: client.identityHandle,
                           publicKey: bridge.identityPublicKey(handle: client.identityHandle), isDistro: false)
    }

    /// Who a group created now is created as (§8.1, §8.5): D when this device holds it, the
    /// device when it holds none, nil while it may hold one not loaded yet (§8.7), or while the
    /// stack gives no device identity (never a signer without one: its invites would go unsigned).
    private func creationSigner() -> GroupSigner? {
        if let signing = DistroManager.shared.signing(), let hash = Data(hexString: signing.info.deliveryHashHex) {
            return GroupSigner(hex: signing.info.deliveryHashHex, hash: hash, identityHandle: signing.handle,
                               publicKey: Data(hexString: signing.info.publicKeyHex), isDistro: true)
        }
        guard distroSettled else { return nil }
        return deviceSigner()
    }

    /// GROUP_MEMBER_KEYS entries for the listed members whose key this device holds (the
    /// signer's own from its identity): what an `accept` group sync carries (§10.2).
    private func memberKeyEntries(_ members: [String], signer: GroupSigner) -> [String] {
        members.compactMap { hash in
            let key = hash == signer.hex ? signer.publicKey : Data(hexString: hash).flatMap { bridge.recalledPublicKey(destHash: $0) }
            guard let key, key.count == 64 else { return nil }
            return "\(hash):\(key.base64EncodedString())"
        }
    }

    /// §10.2: `ids` left by `distro` go first in this device's own `left` list for it.
    private func recordLeft(_ ids: [String], distro: String) {
        var all = prefs.distroLeftIds
        all[distro] = DistroGroupSync.recordLeft(ids, into: all[distro] ?? [])
        prefs.distroLeftIds = all
    }

    /// §10.5-§10.6: owe the group sync G of an action the user made as D in a D-group: packed
    /// and signed by D once, sealed, and owed on its own until the propagation node proves it
    /// (DistroOutboxRuntime.oweGroupSync). Only for a signer that is D: nothing else sends one.
    private func oweGroupSync(_ op: DistroGroupSync.Op, groupId: String, signer: GroupSigner, atMs: UInt64,
                              name: String? = nil, membersCsv: String? = nil, keys: [String]? = nil,
                              creator: String? = nil, text: String? = nil, postId: String? = nil) {
        guard signer.isDistro else { return }
        let d = signer.hex
        let json = DistroGroupSync.writerJSON(op: op, groupId: groupId, atMs: atMs, name: name,
                                              membersCsv: membersCsv, keys: keys, creator: creator,
                                              text: text, left: prefs.distroLeftIds[d] ?? [], postId: postId)
        let device = ownHashHex
        let label = "the \(op.rawValue) group sync of \(groupId.prefix(8)) (SPEC §17.14)"
        Task { @MainActor in
            await DistroOutboxRuntime.shared.oweGroupSync(groupD: d, syncJson: json, deviceHex: device, label: label)
        }
    }

    /// §10.6: the `post` group sync of a post the user sent as D: its text alone (attachments
    /// are not copied, §17.11), at the post's stored time, with its post id (REACTIONS-DESIGN.md
    /// §5.3) when it has one.
    private func owePostSync(groupId: String, text: String, atMs: UInt64, signer: GroupSigner, postId: String?) {
        oweGroupSync(.post, groupId: groupId, signer: signer, atMs: atMs, text: text, postId: postId)
    }

    // MARK: Inbound on the distro path (§6)

    /// A group message to the distro (§6.1 step 2): admitted as on the direct path, with §6.3's
    /// first rules, and handed to the same group handler, or held until its group is joined here
    /// (§6.5), or dropped. Never `ensureContact`/`storeIncomingDirect`: a group message is never
    /// a DM (§6.4). True when kept (applied or stored): only then is its `grp:` key recorded.
    private func handleDistroGroupArrival(_ a: DistroGroupArrival) -> Bool {
        var a = a
        guard modelContext != nil else {
            print("[GroupChat] distro group message \(a.hash.prefix(8)): modelContext is nil; not recorded")
            return false
        }
        guard let distro = heldDistroHex else {
            print("[GroupChat] distro group message \(a.hash.prefix(8)): no distro loaded; not recorded")
            return false
        }
        let groupId = a.groupId
        let srcHex = a.sourceHex
        let fields = LxmfFieldsDecoder.decode(a.fieldsRaw ?? Data())
        // Never a name from a reaction (REACTIONS-DESIGN.md §3), which makes no contact.
        if fields.reaction != nil { a.displayName = .absent }
        let action = fields.groupAction
        let signature = DeliveryPolicy.Signature.reason(valid: a.signatureValidated, unverifiedReason: a.unverifiedReason)

        // §12.3: no device of D acts on a relay request; none sends relay_done.
        if action == GroupAction.relayRequest {
            print("[GroupChat] relay_req for \(groupId.prefix(8)) from \(srcHex.prefix(8)) on the distro path: dropped, no device of the distro relays (§12.3)")
            return false
        }
        // §6.3, §9.3: an invite to D must list D.
        if action == GroupAction.invite, !DeliveryPolicy.members(fields.groupMembers).contains(distro) {
            print("[GroupChat] invite for \(groupId.prefix(8)) from \(srcHex.prefix(8)) to the distro does not list the distro: dropped (§9.3)")
            return false
        }

        switch admitGroupMessage(groupId: groupId, sourceHex: srcHex, fields: fields, signature: signature) {
        case .kept(let standing, let ownAct):
            // The name row the direct path makes for its sender, and nothing else (§6.4); none for
            // a known sibling acting as the user (§9.2), which is never kept as a contact.
            if !ownAct {
                applyMessageName(a.displayName, unverifiedReason: a.unverifiedReason, sourceHex: srcHex,
                                 messageTime: a.timestamp)
            }
            handleGroupMessage(
                hash: Data(hexString: a.hash) ?? Data(), srcHash: Data(hexString: srcHex) ?? Data(),
                content: a.content.trimmingCharacters(in: .whitespacesAndNewlines), timestamp: a.timestamp,
                fields: fields, groupId: groupId, standing: standing, signature: signature,
                senderKey: a.senderKey, packed: a.packed, ownAct: ownAct)
            return true
        case .droppedFirst:
            return false
        case .dropped(let standing):
            if action == GroupAction.invite {
                noteFilteredInvite(groupId: groupId, sourceHex: srcHex, standing: standing, signature: signature)
                return false
            }
            holdIfOnlyNotJoined(a, fields: fields, standing: standing, signature: signature, distro: distro)
            return false
        }
    }

    /// §6.5: an invite to D the privacy filter dropped puts its group id in the filtered-invite
    /// set: that group's traffic is never held. Only for a group this device does not hold: a
    /// filtered invite for a group held here (a co-member's own invite, §11.2) leaves the set alone.
    private func noteFilteredInvite(groupId: String, sourceHex: String, standing: GroupStanding, signature: Int) {
        guard FilteredInvites.records(sourceAllowlisted: isAllowlisted(destHash: sourceHex), closed: standing.closed,
                                      signature: signature, heldHere: standing.chat != nil) else {
            if standing.chat != nil {
                print("[GroupChat] invite to the distro for \(groupId.prefix(8)) from \(sourceHex.prefix(8)) filtered; the group is held here: the filtered-invite set is left alone (§6.5)")
            }
            return
        }
        prefs.filteredInviteIds = FilteredInvites.record(prefs.filteredInviteIds, groupId)
        print("[GroupChat] invite to the distro for \(groupId.prefix(8)) from \(sourceHex.prefix(8)) filtered: the group's traffic is not held (§6.5)")
        scheduleRefreshChats()
    }

    /// §6.5: a group message the rules dropped is held instead only when the group not being
    /// joined here is the sole reason.
    private func holdIfOnlyNotJoined(_ a: DistroGroupArrival, fields: LxmfFields, standing: GroupStanding,
                                     signature: Int, distro: String) {
        let action = fields.groupAction
        let filtered = prefs.filteredInviteIds.contains(a.groupId)
        let selfAddresses = admissionSelf(standing: standing, fields: fields).selfAddresses
        let keptIfJoined = standing.held == .pending && DeliveryPolicy.shouldProcess(
            action: action, sourceAllowed: false, held: .joined, sourceStatus: standing.sourceStatus,
            namesOther: DeliveryPolicy.namesOther(groupSender: fields.groupSender, source: a.sourceHex),
            closed: false, signature: signature, sourceIsCreator: standing.sourceIsCreator)
        guard HeldArrivals.holdable(isPostSync: false, action: action, held: standing.held, closed: standing.closed,
                                    filtered: filtered, signature: signature,
                                    sourceIsSelf: selfAddresses.contains(a.sourceHex), keptIfJoined: keptIfJoined)
        else {
            if filtered {
                print("[GroupChat] \(action ?? "post") for \(a.groupId.prefix(8)) not held: the filter dropped its invite (§6.5)")
            }
            return
        }
        let signatureBytes = a.packed.flatMap { $0.count >= 96 ? $0.subdata(in: 32..<96) : nil }
        holdArrival(blob: a.blob, groupId: a.groupId, source: a.sourceHex, hash: a.hash, signature: signatureBytes,
                    validated: signature == DeliveryPolicy.Signature.validated, countsAgainstSource: true,
                    distro: distro, what: action ?? "post")
    }

    /// §6.5: keep `blob` until its group is joined here, within the bounds (HeldArrivals). Every
    /// eviction and refusal is logged with the group, the source and the bound.
    private func holdArrival(blob: Data, groupId: String, source: String, hash: String, signature: Data?,
                             validated: Bool, countsAgainstSource: Bool, distro: String, what: String) {
        guard let ctx = modelContext else { return }
        let rows = (try? ctx.fetch(FetchDescriptor<GroupHeldArrivalEntity>(sortBy: [SortDescriptor(\.seq)]))) ?? []
        let pendingDesc = FetchDescriptor<ChatEntity>(predicate: #Predicate { $0.isGroup == true && $0.groupStatus == "pending" })
        let pendingIds = Set(((try? ctx.fetch(pendingDesc)) ?? []).map(\.id))
        let items = rows.map {
            HeldArrivals.Item(seq: $0.seq, groupId: $0.groupId, source: $0.srcHash, hash: $0.msgHash,
                              signature: $0.signature, validated: $0.validated, size: $0.size,
                              countsAgainstSource: $0.countsAgainstSource)
        }
        let seq = (rows.map(\.seq).max() ?? 0) + 1
        let new = HeldArrivals.Item(seq: seq, groupId: groupId, source: source, hash: hash, signature: signature,
                                    validated: validated, size: blob.count, countsAgainstSource: countsAgainstSource)
        switch HeldArrivals.decide(new, existing: items, pending: { pendingIds.contains($0) }) {
        case .duplicate:
            print("[GroupChat] \(what) \(hash.prefix(8)) for \(groupId.prefix(8)) is held already (§6.5)")
        case .refuse(let why):
            print("[GroupChat] \(what) for \(groupId.prefix(8)) from \(source.prefix(8)) not held: \(why) (§6.5)")
        case .hold(let evict):
            for eviction in evict {
                guard let row = rows.first(where: { $0.seq == eviction.seq }) else { continue }
                print("[GroupChat] held message \(row.msgHash.prefix(8)) for \(row.groupId.prefix(8)) from \(row.srcHash.prefix(8)) evicted: \(eviction.bound) (§6.5)")
                ctx.delete(row)
            }
            let key = "\(hash):" + (signature?.hexString ?? (validated ? "validated" : "unverified"))
            ctx.insert(GroupHeldArrivalEntity(key: key, groupId: groupId, srcHash: source, msgHash: hash,
                                              signature: signature, validated: validated,
                                              countsAgainstSource: countsAgainstSource, distro: distro,
                                              blob: blob, seq: seq))
            try? ctx.save()
            print("[GroupChat] \(what) \(hash.prefix(8)) for \(groupId.prefix(8)) from \(source.prefix(8)) held until the group is joined here (§6.5)")
        }
    }

    /// §6.5: the group is joined here now: what was held for it is fed to the distro path again,
    /// in arrival order, and forgotten. Each is judged as a new arrival (ordering, not a retry).
    private func replayHeldArrivals(groupId: String) {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<GroupHeldArrivalEntity>(predicate: #Predicate { $0.groupId == groupId },
                                                            sortBy: [SortDescriptor(\.seq)])
        let rows = (try? ctx.fetch(desc)) ?? []
        guard !rows.isEmpty else { return }
        let blobs = rows.map(\.blob)
        for row in rows { ctx.delete(row) }
        try? ctx.save()
        print("[GroupChat] \(blobs.count) message(s) held for \(groupId.prefix(8)) judged again: the group is joined here (§6.5)")
        for blob in blobs { RfedDistroClient.ingestBlob(blob) }
    }

    /// §6.5: the group is closed or gone here: what was held for it is forgotten (one line).
    private func forgetHeldArrivals(groupId: String, why: String) {
        guard let ctx = modelContext else { return }
        let desc = FetchDescriptor<GroupHeldArrivalEntity>(predicate: #Predicate { $0.groupId == groupId })
        let rows = (try? ctx.fetch(desc)) ?? []
        guard !rows.isEmpty else { return }
        for row in rows { ctx.delete(row) }
        try? ctx.save()
        print("[GroupChat] \(rows.count) message(s) held for \(groupId.prefix(8)) forgotten: \(why) (§6.5)")
    }

    /// The distro held changed. Once the Keychain has said what the device holds: the arrivals
    /// held for a distro given up are forgotten (§6.5), and its known siblings dropped unless a
    /// group here still has it as its own address (§8.7).
    private func onDistroHeldChanged(_ held: String?) {
        defer { refreshChats() }
        guard distroSettled, let ctx = modelContext else { return }
        let rows = (try? ctx.fetch(FetchDescriptor<GroupHeldArrivalEntity>())) ?? []
        let gone = rows.filter { $0.distro != held }
        if !gone.isEmpty {
            for row in gone { ctx.delete(row) }
            try? ctx.save()
            print("[GroupChat] \(gone.count) message(s) held for a distro this device no longer holds forgotten (§6.5)")
        }
        let groups = (try? ctx.fetch(FetchDescriptor<ChatEntity>(predicate: #Predicate { $0.isGroup == true }))) ?? []
        let owners = Set(groups.compactMap(\.ownMember))
        let known = prefs.distroSiblings
        let pruned = KnownSiblings.prune(known, heldDistro: held, ownMembers: owners)
        if pruned != known {
            prefs.distroSiblings = pruned
            print("[GroupChat] the known siblings of \(known.count - pruned.count) distro(s) this device no longer holds dropped (§8.7)")
        }
    }

    // MARK: The group sync G (§11)

    /// A group sync G (SPEC §17.14): §11.1's rules 1 to 4, then 5 and 6 by the group as held
    /// here, then `left`. Applying G never sends anything and never owes a G. True when kept
    /// (applied, or this device's own echo): its `gsync:` key is recorded. False when dropped
    /// (judged again on its next copy) or held (judged as a new arrival when replayed).
    private func handleDistroGroupSync(_ a: DistroGroupSyncArrival) -> Bool {
        guard modelContext != nil else {
            print("[GroupSync] G \(a.hash.prefix(8)): modelContext is nil; not recorded")
            return false
        }
        let device = ownHashHex
        guard !device.isEmpty else {
            print("[GroupSync] G \(a.hash.prefix(8)) not judged yet: this device's own address is not known (the stack has not started); not recorded")
            return false
        }
        switch DistroGroupSync.disposition(sourceHex: a.sourceHex, distroHex: a.distroHex,
                                           signatureValidated: a.signatureValidated, reading: a.reading,
                                           deviceHex: device) {
        case .notFromDistro:
            print("[GroupSync] G \(a.hash.prefix(8)) from \(a.sourceHex.prefix(8)) ignored: its source is not the distro (§11.1 rule 1)")
            return false
        case .forged:
            print("[GroupSync] G \(a.hash.prefix(8)) dropped: its signature does not validate under the distro's key (§11.1 rule 2)")
            return false
        case .ownEcho:
            return true
        case .malformed(let why, let sibling):
            if let sibling { learnSibling(sibling, of: a.distroHex) }
            print("[GroupSync] G \(a.hash.prefix(8)) dropped: \(why) (§11.1 rule 4)")
            return false
        case .apply(let form, let sibling):
            if let sibling { learnSibling(sibling, of: a.distroHex) }
            let kept = applyGroupSync(form, arrival: a)
            applyLeft(form, distro: a.distroHex, hash: a.hash)
            return kept
        }
    }

    /// Where the group `groupId` stands here, for §11.2.
    private func syncStanding(_ groupId: String) -> (standing: DistroGroupSync.Standing, chat: ChatEntity?) {
        if let ctx = modelContext,
           let chat = try? ctx.fetch(FetchDescriptor<ChatEntity>(predicate: #Predicate { $0.id == groupId })).first,
           chat.isGroup {
            return (chat.groupStatus == "pending" ? .pending : .joined, chat)
        }
        return (ClosedGroups.contains(prefs.closedGroupIds, groupId) ? .closed : .notHeld, nil)
    }

    /// §11.2 for G's own group. True when applied (recorded as seen), false when held.
    private func applyGroupSync(_ form: DistroGroupSync.Form, arrival a: DistroGroupSyncArrival) -> Bool {
        let d = a.distroHex
        let groupId = form.groupId
        let (standing, chat) = syncStanding(groupId)
        let pendingMatches: Bool = {
            guard form.op == .accept, standing == .pending, let chat else { return false }
            return chat.creatorHash == form.creator && Set(groupRows(groupId).map(\.hash)) == Set(form.members)
        }()
        let step = DistroGroupSync.step(form.op, standing: standing, ownMemberIsD: chat?.ownMember == d,
                                        pendingMatches: pendingMatches)
        let what = "the \(form.op.rawValue) sync \(a.hash.prefix(8)) for \(groupId.prefix(8))"
        switch step {
        case .holdFromSync:
            holdGroupFromSync(form, distro: d, what: what)
        case .discardPendingThenHold:
            // The user's own sync outranks anyone else's invite for its id: the pending invite is
            // discarded, sending nothing (a decline would be a final leave as D).
            print("[GroupSync] \(what): the pending invite from \(chat?.creatorHash?.prefix(8) ?? "?") is discarded, nothing sent; the group is held from the sync (§11.2)")
            deleteChatLocal(chatId: groupId, forgetHeld: false)
            holdGroupFromSync(form, distro: d, what: what)
        case .joinPending:
            if let chat { joinPendingFromSync(chat, distro: d, what: what) }
        case .close:
            if form.op == .leave { recordLeft([groupId], distro: d) }
            closeGroupFromSync(groupId, why: what)
        case .tombstone:
            prefs.closedGroupIds = ClosedGroups.record(prefs.closedGroupIds, groupId)
            recordLeft([groupId], distro: d)
            print("[GroupSync] \(what): not held here, recorded closed (§11.2)")
            // §6.5: closed here, so what was held for it can never be replayed.
            forgetHeldArrivals(groupId: groupId, why: "the group was closed here by the distro's leave")
        case .storeOwnPost:
            if let chat { storeOwnPostFromSync(form, hash: a.hash, distro: d, chat: chat) }
        case .applyOwnReaction:
            // REACTIONS-DESIGN.md §5.3: the user's reaction as D, applied as §3 with reactor = the
            // address the user takes part in this group as (D, rule 5). No bubble.
            if let postId = form.postId, let to = Reactions.hexBytes(postId, count: 16) {
                applyReaction(to: to, content: form.text, chatId: groupId, inGroup: true, reactor: d,
                              timestamp: Double(form.atMs) / 1000, path: "handleDistroGroupSync")
            }
        case .holdArrival:
            let filtered = prefs.filteredInviteIds.contains(groupId)
            guard HeldArrivals.holdable(isPostSync: true, action: nil, held: standing == .pending ? .pending : .none,
                                        closed: false, filtered: filtered,
                                        signature: DeliveryPolicy.Signature.validated, sourceIsSelf: false,
                                        keptIfJoined: true) else {
                print("[GroupSync] \(what) dropped: the filter dropped the group's invite here (§6.5)")
                return false
            }
            holdArrival(blob: a.blob, groupId: groupId, source: d, hash: a.hash, signature: nil, validated: true,
                        countsAgainstSource: false, distro: d, what: "post sync")
            return false
        case .nothing(let why):
            if form.op == .leave, standing == .closed { recordLeft([groupId], distro: d) }
            print("[GroupSync] \(what): nothing to apply, \(why) (§11.1-§11.2)")
        }
        return true
    }

    /// "Hold the group from G" (§11.2): list = members; creator D for `create`, `creator` for
    /// `accept`; own address D; joined; D accepted (and the creator, for `accept`), every other
    /// member invited; the keys bound and remembered; the members let through the privacy
    /// filter by association, no self address; the id out of the filtered-invite set; what was
    /// held for it replayed.
    private func holdGroupFromSync(_ form: DistroGroupSync.Form, distro d: String, what: String) {
        guard let ctx = modelContext else { return }
        let groupId = form.groupId
        if (try? ctx.fetch(FetchDescriptor<ChatEntity>(predicate: #Predicate { $0.id == groupId })).first) != nil {
            print("[GroupSync] \(what) names another chat here: ignored")
            return
        }
        let creator = form.op == .create ? d : (form.creator ?? d)
        ctx.insert(ChatEntity(id: groupId, peerHash: creator == d ? "" : creator,
                              lastMessageTime: Double(form.atMs) / 1000, isGroup: true,
                              groupName: form.name.isEmpty ? nil : form.name, groupStatus: "active",
                              creatorHash: creator, ownMember: d, membersCsv: form.membersCsv))
        var seen = Set<String>()
        for member in form.members where seen.insert(member).inserted {
            let accepted = member == d || (form.op == .accept && member == creator)
            ctx.insert(GroupMemberEntity(groupId: groupId, memberHash: member,
                                         inviteStatus: accepted ? MemberStatus.accepted : MemberStatus.invited))
        }
        let selfAddresses = GroupSelf.addresses(ownMember: d, device: ownHashHex, listed: form.members,
                                                heldDistro: heldDistroHex, siblings: knownSiblings(of:))
        bindSyncKeys(form.keys, listed: form.members, selfAddresses: selfAddresses)
        for member in form.members where !selfAddresses.contains(member) {
            ensureAllowlistedContact(destHash: member)
            if let hashData = Data(hexString: member) { RetichatBridge.shared.watchAnnounce(destHash: hashData) }
        }
        prefs.filteredInviteIds = FilteredInvites.remove(prefs.filteredInviteIds, groupId)
        try? ctx.save()
        groupStatuses.decideHeld()
        print("[GroupSync] \(what): the group is held from it, created by \(creator.prefix(8)), \(form.members.count) member(s), joined as the distro (§11.2)")
        replayHeldArrivals(groupId: groupId)
        refreshChats()
    }

    /// §11.2, `accept` for a matching pending invite: joined as the user's own accept here
    /// would make it, without sending.
    private func joinPendingFromSync(_ chat: ChatEntity, distro d: String, what: String) {
        guard let ctx = modelContext else { return }
        let groupId = chat.id
        chat.groupStatus = "active"
        let members = (try? ctx.fetch(FetchDescriptor<GroupMemberEntity>(predicate: #Predicate { $0.groupId == groupId }))) ?? []
        if let own = members.first(where: { $0.memberHash == d }) {
            own.inviteStatus = MemberStatus.accepted
        } else {
            ctx.insert(GroupMemberEntity(groupId: groupId, memberHash: d, inviteStatus: MemberStatus.accepted))
        }
        let rows = members.map { (hash: $0.memberHash, status: $0.inviteStatus) }
        let selfAddresses = groupSelf(chat, rows: rows)
        for member in members.map(\.memberHash) where !selfAddresses.contains(member) {
            ensureAllowlistedContact(destHash: member)
            if let hashData = Data(hexString: member) { RetichatBridge.shared.watchAnnounce(destHash: hashData) }
        }
        prefs.filteredInviteIds = FilteredInvites.remove(prefs.filteredInviteIds, groupId)
        try? ctx.save()
        groupStatuses.decideHeld()
        print("[GroupSync] \(what): the pending invite matches, joined as the distro, nothing sent (§11.2)")
        replayHeldArrivals(groupId: groupId)
        refreshChats()
    }

    /// §11.2, closed as the local decline or leave closes it, minus the send and minus owing a
    /// G: the id recorded closed and the conversation removed.
    private func closeGroupFromSync(_ groupId: String, why: String) {
        prefs.closedGroupIds = ClosedGroups.record(prefs.closedGroupIds, groupId)
        deleteChatLocal(chatId: groupId)
        print("[GroupSync] \(why): group \(groupId.prefix(8)) closed and removed here, nothing sent (§11.2)")
    }

    /// §11.2, `post` in a joined group: the user's own outgoing post, sender D, SENT, at
    /// `at_ms`, id = G's LXMF hash, the §17.11 placeholder for an empty text, no notification.
    private func storeOwnPostFromSync(_ form: DistroGroupSync.Form, hash: String, distro d: String, chat: ChatEntity) {
        guard let ctx = modelContext else { return }
        let dup = FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.id == hash })
        if let existing = try? ctx.fetch(dup), !existing.isEmpty { return }
        var content = form.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty { content = DistroMessageStore.unavailablePlaceholder }
        let timestamp = Double(form.atMs) / 1000
        insertMessage(MessageEntity(id: hash, chatId: chat.id, senderHash: d, content: content,
                                    timestamp: timestamp, isOutgoing: true, deliveryState: DeliveryState.sent,
                                    // REACTIONS-DESIGN.md §5.3: the post's id, when the sending device gave one.
                                    postId: form.postId),
                      into: ctx)
        updateChatTimestamp(chatId: chat.id, timestamp: timestamp)
        try? ctx.save()
        refreshChats()
    }

    /// §11.2, `left`: after the op, each id other than G's own.
    private func applyLeft(_ form: DistroGroupSync.Form, distro d: String, hash: String) {
        var changed: [String] = []
        var recorded: [String] = []
        for id in DistroGroupSync.leftIds(form) {
            let (standing, chat) = syncStanding(id)
            switch DistroGroupSync.leftStep(standing: standing, ownMemberIsD: chat?.ownMember == d) {
            case .close:
                closeGroupFromSync(id, why: "the left of G \(hash.prefix(8))")
                changed.append(id); recorded.append(id)
            case .tombstone:
                prefs.closedGroupIds = ClosedGroups.record(prefs.closedGroupIds, id)
                forgetHeldArrivals(groupId: id, why: "the group was closed here by the left of G \(hash.prefix(8))")
                changed.append(id); recorded.append(id)
            case .alreadyClosed:
                recorded.append(id)
            case .ignore:
                break
            }
        }
        if !recorded.isEmpty { recordLeft(recorded, distro: d) }
        if !changed.isEmpty {
            print("[GroupSync] the left of G \(hash.prefix(8)) closed \(changed.count) group(s) here: \(changed.map { String($0.prefix(8)) }.joined(separator: ", ")) (§11.2)")
        }
    }

    /// GROUP_MEMBER_KEYS entries of a group sync, each bound as an invite chunk's is (its key
    /// produces its hash, the hash is listed); one that does not bind is ignored.
    private func bindSyncKeys(_ keys: [String], listed: [String], selfAddresses: Set<String>) {
        for entry in keys {
            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let hash = DeliveryPolicy.hash(parts[0].lowercased()), listed.contains(hash),
                  !selfAddresses.contains(hash), let hashData = Data(hexString: hash),
                  let publicKey = Data(base64Encoded: parts[1]), publicKey.count == 64 else { continue }
            if !bridge.rememberLxmfDelivery(destHash: hashData, publicKey: publicKey) {
                print("[GroupSync] ignored a member key that does not hash to \(hash.prefix(8))")
            }
        }
    }

    // MARK: Shown

    /// A member's label in a group's member list: "You" for exactly the group's self addresses
    /// (§9.1, §9.2), else the member's name as any contact's (a sibling listed in a group that
    /// names no distro of the user is a member there, and shown by its name).
    func groupMemberDisplayName(for hash: String, groupId: String) -> String {
        if isGroupSelf(chatId: groupId, hex: hash) { return "You" }
        return resolvedContactName(for: hash) ?? DisplayNames.shortHash(hash)
    }

    /// §6.7: the App Group file the NSE decides group notifications from.
    private func nseGroupsSnapshot() -> NSEGroups {
        var groups: [String: NSEGroups.Group] = [:]
        if let ctx = modelContext {
            let chats = (try? ctx.fetch(FetchDescriptor<ChatEntity>(predicate: #Predicate { $0.isGroup == true }))) ?? []
            let rows = (try? ctx.fetch(FetchDescriptor<GroupMemberEntity>())) ?? []
            let byGroup = Dictionary(grouping: rows, by: \.groupId)
            for chat in chats where chat.isGroup {
                let members = (byGroup[chat.id] ?? []).map { (hash: $0.memberHash, status: $0.inviteStatus) }
                let accepted = GroupMemberStatuses.acceptedMembers(members, selfAddresses: [])
                groups[chat.id] = NSEGroups.Group(name: chat.groupName ?? "Group",
                                                  state: chat.groupStatus == "pending" ? "pending" : "joined",
                                                  accepted: accepted)
            }
        }
        var inviters: [String] = []
        if let ctx = modelContext {
            let allowed = FetchDescriptor<ContactEntity>(predicate: #Predicate { $0.isAllowlisted == true })
            inviters = ((try? ctx.fetch(allowed)) ?? []).map(\.destHash)
        }
        var me: [String] = ownHashHex.isEmpty ? [] : [ownHashHex]
        if let held = heldDistroHex { me += [held] + knownSiblings(of: held) }
        return NSEGroups(filterOn: prefs.filterStrangers, inviters: inviters, groups: groups,
                         closed: prefs.closedGroupIds + prefs.filteredInviteIds, selfAddresses: me)
    }

    // MARK: - Names (LXMF-rust/DISPLAY_NAMES.md §5)
    //
    // One resolver for every surface: localName ?? messageName ??
    // announceName ?? shortHash (DisplayNames.contactLabel). Nothing stores
    // a resolved name; system messages keep the subject's hash and are
    // named when shown.

    /// The resolved label for a hash: "You" for this device's own address.
    func contactDisplayName(for destHash: String) -> String {
        // Outside a group, the device and the distro it holds are the user; a known sibling of
        // that distro is the user only in a group naming it (GROUPS-DISTRO-DESIGN.md §9.1,
        // groupMemberDisplayName and label(for:in:groupSelf:)).
        if GroupSelf.shownAsYou(destHash, groupSelf: nil, device: ownHashHex, heldDistro: ownDistroHex) { return "You" }
        return resolvedContactName(for: destHash) ?? DisplayNames.shortHash(destHash)
    }

    /// The contact's name without the hash fallback (nil when it has none).
    func resolvedContactName(for destHash: String) -> String? {
        guard let ctx = modelContext else { return nil }
        let descriptor = FetchDescriptor<ContactEntity>(
            predicate: #Predicate { $0.destHash == destHash }
        )
        return (try? ctx.fetch(descriptor).first).flatMap { resolvedName($0) }
    }

    /// resolvedContactName with the slot it came from: a channel label
    /// shows a local-slot name first (DisplayNames.channelLabel, §5.3).
    func contactSharedName(for destHash: String) -> DisplayNames.SharedName? {
        guard let ctx = modelContext else { return nil }
        let descriptor = FetchDescriptor<ContactEntity>(
            predicate: #Predicate { $0.destHash == destHash }
        )
        return (try? ctx.fetch(descriptor).first).flatMap { sharedName($0) }
    }

    /// The three slots of a contact, for the rename UI (nil: no contact).
    func contactNameSlots(for destHash: String) -> (local: String?, message: String?, announce: String?)? {
        guard let ctx = modelContext else { return nil }
        let descriptor = FetchDescriptor<ContactEntity>(
            predicate: #Predicate { $0.destHash == destHash }
        )
        guard let c = try? ctx.fetch(descriptor).first else { return nil }
        return (c.localName, c.messageName, c.announceName)
    }

    /// localName ?? messageName ?? announceName. Until the §5.4 migration
    /// has run (it needs the stack, for the recalled announce names), a
    /// legacy name that is not a placeholder is shown as it was.
    private func resolvedName(_ c: ContactEntity) -> String? {
        sharedName(c)?.name
    }

    /// resolvedName, with the slot it came from and the contact's
    /// messageNameAt: the contact's chat_names.json entry for the NSE.
    private func sharedName(_ c: ContactEntity) -> DisplayNames.SharedName? {
        if let resolved = DisplayNames.contactNameAndSlot(local: c.localName, message: c.messageName,
                                                           announce: c.announceName) {
            return DisplayNames.SharedName(name: resolved.name, slot: resolved.slot,
                                           messageNameAt: c.messageNameAt)
        }
        if !prefs.contactNamesMigrated, !DisplayNames.isPlaceholder(c.displayName, ownHash: c.destHash) {
            return DisplayNames.SharedName(name: c.displayName, slot: .legacy, messageNameAt: c.messageNameAt)
        }
        return nil
    }

    /// Every contact's resolved name (nil: none) in one fetch.
    private func contactNameIndex() -> [String: String?] {
        contactNameEntries().mapValues { Optional($0.name) }
    }

    /// Every named contact's shared name in one fetch; a contact without a
    /// name is left out.
    private func contactNameEntries() -> [String: DisplayNames.SharedName] {
        guard let ctx = modelContext,
              let contacts = try? ctx.fetch(FetchDescriptor<ContactEntity>()) else { return [:] }
        var index: [String: DisplayNames.SharedName] = [:]
        for c in contacts { index[c.destHash] = sharedName(c) }
        return index
    }

    /// contactDisplayName against a prefetched index. In a group, `groupSelf` is that group's
    /// self addresses (§9.1): exactly those are "You" there (a former D included, a sibling
    /// listed in a device group not); nil outside groups.
    private func label(for hash: String, in names: [String: String?], groupSelf: Set<String>? = nil) -> String {
        if GroupSelf.shownAsYou(hash, groupSelf: groupSelf, device: ownHashHex, heldDistro: ownDistroHex) { return "You" }
        return (names[hash] ?? nil) ?? DisplayNames.shortHash(hash)
    }

    /// A stored message's text as shown: a system message's subject named now ("Your other device"
    /// for a known sibling's own join or leave, GroupSelf.memberLineSubject).
    private func shownText(_ content: String, id: String, senderHash: String, names: [String: String?],
                           groupSelf: Set<String>? = nil) -> String {
        let subject = GroupSelf.memberLineSubject(senderHash, messageId: id, groupSelf: groupSelf,
                                                  device: ownHashHex, siblings: knownSiblingAddresses())
            ?? label(for: senderHash, in: names, groupSelf: groupSelf)
        return DisplayNames.systemText(content, messageId: id, subject: subject)
    }

    /// Every known sibling of every distro (§9.1): the user's other devices this device has
    /// learnt. Within a group's self addresses, exactly its distro's.
    private func knownSiblingAddresses() -> Set<String> { Set(prefs.distroSiblings.values.joined()) }

    /// The self addresses of group `chatId` held here (§9.1); nil for a chat that is not a group.
    private func groupSelf(forChatId chatId: String) -> Set<String>? {
        guard let ctx = modelContext,
              let chat = try? ctx.fetch(FetchDescriptor<ChatEntity>(predicate: #Predicate { $0.id == chatId })).first,
              chat.isGroup else { return nil }
        return groupSelf(chat, rows: groupRows(chatId))
    }

    /// The self addresses of every group among `chats` (§9.1), with one fetch of the member rows.
    private func groupSelves(_ chats: [ChatEntity]) -> [String: Set<String>] {
        let groups = chats.filter(\.isGroup)
        guard !groups.isEmpty, let ctx = modelContext else { return [:] }
        let rows = (try? ctx.fetch(FetchDescriptor<GroupMemberEntity>())) ?? []
        let byGroup = Dictionary(grouping: rows, by: \.groupId)
        var out: [String: Set<String>] = [:]
        for chat in groups {
            let members = (byGroup[chat.id] ?? []).map { (hash: $0.memberHash, status: $0.inviteStatus) }
            out[chat.id] = groupSelf(chat, rows: members)
        }
        return out
    }

    /// A contact's name slots changed: the chat list, open conversations
    /// (namesVersion) and the NSE's name file follow.
    private func namesChanged() {
        namesVersion &+= 1
        scheduleRefreshChats()
    }

    /// The user's own name for a contact (§5.1 localName), cleaned like any
    /// name (§3). Saving an empty name clears it, and the contact shows its
    /// provided name again.
    func setLocalName(destHash: String, name: String) {
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<ContactEntity>(
            predicate: #Predicate { $0.destHash == destHash }
        )
        let contact: ContactEntity
        if let existing = try? ctx.fetch(descriptor).first {
            contact = existing
        } else {
            contact = ContactEntity(destHash: destHash)
            ctx.insert(contact)
        }
        contact.localName = LxmfClient.cleanDisplayName(name)
        try? ctx.save()
        namesChanged()
        refreshChats()
    }

    /// §5.2: a message's 0xD1 applied to the messageName of its LXMF source,
    /// with the ordering rule: only a message whose LXMF timestamp
    /// (`messageTime`) is newer than messageNameAt counts, and accepting one
    /// records its timestamp, a repeat of the current name included.
    /// Callers pass only messages this device accepted (allowlist, group
    /// policy, distro, NSE import); this device's own addresses are skipped.
    private func applyMessageName(_ field: DisplayNames.NameField, unverifiedReason: Int, sourceHex: String,
                                  messageTime: Double) {
        guard field != .absent, !isOwnAddress(sourceHex), let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<ContactEntity>(
            predicate: #Predicate { $0.destHash == sourceHex }
        )
        let existing = try? ctx.fetch(descriptor).first
        let change = DisplayNames.acceptMessageName(field, unverifiedReason: unverifiedReason,
                                                    current: existing?.messageName,
                                                    currentAt: existing?.messageNameAt,
                                                    messageTime: messageTime)
        let name: String?
        switch change {
        case .keep: return
        case .set(let n): name = n
        case .fill(let n): name = n
        }
        let contact: ContactEntity
        if let existing {
            contact = existing
        } else {
            // A plain row, not allowlisted, as for any sender we accepted.
            // Also for a clear: its timestamp keeps an older name out.
            contact = ContactEntity(destHash: sourceHex)
            ctx.insert(contact)
        }
        let renamed = contact.messageName != name
        contact.messageName = name
        // A fill (unknown source) leaves messageNameAt alone, so the
        // source's validated names that follow still replace it.
        if case .set = change { contact.messageNameAt = messageTime }
        try? ctx.save()
        guard renamed else {
            // Only the timestamp moved: no surface changes, but the NSE's
            // copy of messageNameAt (chat_names.json) follows.
            scheduleRefreshChats()
            return
        }
        print("[Retichat] message name for \(sourceHex.prefix(8)) \(name == nil ? "cleared" : "set") (reason \(unverifiedReason))")
        namesChanged()
    }

    /// Bring a contact's announceName up to the announce cache (the Rust
    /// side's record of the last validated announce, DISPLAY_NAMES.md §5.1):
    /// for a contact whose announce arrived before the contact existed, or
    /// before the callbacks were wired, so handleAnnounce never saw it. A
    /// hit that differs replaces the stored name; a miss changes nothing
    /// (DisplayNames.announceNameFromCache). The lookup runs on ffiQueue; an
    /// announce handled meanwhile is at least as new, so it wins.
    private func refreshAnnounceNameFromCache(destHash: String) {
        guard let client = lxmfClient, let hashData = Data(hexString: destHash) else { return }
        let generation = announceGeneration[destHash, default: 0]
        ffiQueue.async { [weak self] in
            // Without the old web announce suffix (§5.4), as handleAnnounce.
            let recalled = client.recallDisplayName(for: hashData)
                .map { DisplayNames.stripOwnHashSuffix($0, ownHash: destHash) }
            guard recalled != nil else { return }
            Task { @MainActor [weak self] in
                guard let self, let ctx = self.modelContext else { return }
                let descriptor = FetchDescriptor<ContactEntity>(
                    predicate: #Predicate { $0.destHash == destHash }
                )
                guard let contact = try? ctx.fetch(descriptor).first else { return }
                let announcedSince = self.announceGeneration[destHash, default: 0] != generation
                guard case .set(let name) = DisplayNames.announceNameFromCache(
                    recalled: recalled, stored: contact.announceName,
                    announcedSinceLookup: announcedSince) else { return }
                contact.announceName = name
                try? ctx.save()
                self.namesChanged()
            }
        }
    }

    /// §5.4, once (guarded by a persisted flag): each contact's single old
    /// name goes to the slot it came from. A placeholder (the spec's list,
    /// DisplayNames.isPlaceholder) is dropped, a value equal to the
    /// contact's recalled announce name becomes announceName, anything else
    /// was typed by the user and becomes localName. A slot filled since (a message or announce that already
    /// arrived) is not overwritten. The recalls run on ffiQueue.
    private func migrateLegacyContactNamesIfNeeded(client: LxmfClient) {
        guard !prefs.contactNamesMigrated, let ctx = modelContext,
              let contacts = try? ctx.fetch(FetchDescriptor<ContactEntity>()) else { return }
        let legacy = contacts.filter { !$0.displayName.isEmpty }.map { ($0.destHash, $0.displayName) }
        ffiQueue.async { [weak self] in
            var recalled: [String: String] = [:]
            for (hash, _) in legacy {
                if let data = Data(hexString: hash), let name = client.recallDisplayName(for: data) {
                    recalled[hash] = name
                }
            }
            Task { @MainActor [weak self, recalled] in
                guard let self, !self.prefs.contactNamesMigrated, let ctx = self.modelContext else { return }
                var moved = 0
                for (hash, value) in legacy {
                    let descriptor = FetchDescriptor<ContactEntity>(predicate: #Predicate { $0.destHash == hash })
                    guard let contact = try? ctx.fetch(descriptor).first else { continue }
                    // Cleaned as any saved name is (§3): an old announce name
                    // was stored raw, and the recalled one comes back cleaned.
                    let cleaned = LxmfClient.cleanDisplayName(value) ?? ""
                    switch DisplayNames.migrateLegacyName(cleaned, hash: hash, recalledAnnounceName: recalled[hash]) {
                    case .drop:
                        break
                    case .announceName(let name):
                        if contact.announceName == nil { contact.announceName = name; moved += 1 }
                    case .localName(let name):
                        if contact.localName == nil { contact.localName = name; moved += 1 }
                    }
                }
                try? ctx.save()
                self.prefs.contactNamesMigrated = true
                print("[Retichat] contact names migrated: \(moved) of \(legacy.count) kept")
                self.namesChanged()
            }
        }
    }

    /// §5.4's one-off second pass (guarded by a persisted flag), for names
    /// stored before the old web node defaults and the old web announce
    /// suffix were placeholders: each contact's localName and announceName
    /// go through DisplayNames.remigratedName (as Android's database 12
    /// pass). Needs no stack; runs once the store is configured.
    private func remigrateContactNamesIfNeeded() {
        guard !prefs.contactNamesPlaceholderPass, let ctx = modelContext,
              let contacts = try? ctx.fetch(FetchDescriptor<ContactEntity>()) else { return }
        var changed = 0
        for contact in contacts {
            let local = DisplayNames.remigratedName(contact.localName, ownHash: contact.destHash, isLocalName: true)
            let announce = DisplayNames.remigratedName(contact.announceName, ownHash: contact.destHash,
                                                       isLocalName: false)
            if local != contact.localName { contact.localName = local; changed += 1 }
            if announce != contact.announceName { contact.announceName = announce; changed += 1 }
        }
        try? ctx.save()
        prefs.contactNamesPlaceholderPass = true
        print("[Retichat] contact names: placeholder pass changed \(changed) name(s)")
        if changed > 0 { namesChanged() }
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

    private func updateChatTimestamp(chatId: String, timestamp: Double) {
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<ChatEntity>(
            predicate: #Predicate { $0.id == chatId }
        )
        if let chat = try? ctx.fetch(descriptor).first {
            chat.lastMessageTime = max(chat.lastMessageTime, timestamp)
        }
    }

    /// The one way a MessageEntity enters the store: it drops that chat's
    /// memoized preview in the same step, so no insert path can leave a stale
    /// chat-list preview behind (see chatPreviewMemo).
    private func insertMessage(_ message: MessageEntity, into ctx: ModelContext) {
        ctx.insert(message)
        chatPreviewMemo[message.chatId] = nil
    }

    private func lastMessage(forChatId chatId: String) throws -> MessageEntity? {
        guard let ctx = modelContext else { return nil }
        var descriptor = FetchDescriptor<MessageEntity>(
            predicate: #Predicate { $0.chatId == chatId },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try ctx.fetch(descriptor).first
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
