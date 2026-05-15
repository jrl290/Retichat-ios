//
//  RetichatApp.swift
//  Retichat
//
//  App entry point.
//  Sets up SwiftData ModelContainer, injects ChatRepository, handles
//  scene lifecycle, push notifications, and deep‑link URLs.
//

import SwiftUI
import SwiftData
import UserNotifications

// MARK: - AppDelegate (early notification setup)

class RetichatAppDelegate: NSObject, UIApplicationDelegate {
    /// OS-level background task token for immediate background execution.
    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid

    /// Shared repository — created in didFinishLaunching so it’s available
    /// by the time `didReceiveRemoteNotification` fires on cold launch.
    let repository = ChatRepository()

    /// Shared ModelContainer — same instance used by the SwiftUI App struct.
    let modelContainer: ModelContainer = {
        do {
            return try ModelContainer(for:
                ContactEntity.self,
                ChatEntity.self,
                MessageEntity.self,
                AttachmentEntity.self,
                GroupMemberEntity.self,
                InterfaceConfigEntity.self,
                ChannelEntity.self,
                ChannelMessageEntity.self
            )
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    /// Channel client — shared across the app.
    let channelClient = RfedChannelClient()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Must set delegate before any notification arrives
        NotificationManager.shared.configure()
        // Clean up stale NSE handoff files from previous session
        PendingNotification.cleanup()
        // Wire up model context early so push handler can use the repository
        repository.configure(modelContext: modelContainer.mainContext)
        return true
    }

    // MARK: - APNs — token delivery

    /// Called (potentially every launch) after `registerForRemoteNotifications()`.
    /// Stores the token so it can be sent to the rfed notify relay once that bridge is built.
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        let oldToken = UserPreferences.shared.apnsDeviceToken
        UserPreferences.shared.apnsDeviceToken = hex

        // If the token changed (or is new), re-register with the rfed APNs bridge.
        if hex != oldToken, !repository.ownHash.isEmpty,
              !UserPreferences.shared.effectiveRfedNodeIdentityHash.isEmpty {
            ApnsTokenRegistrar.shared.registerIfNeeded(subscriberHash: repository.ownHash)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[APNs] registration failed: \(error)")
    }

    // MARK: - APNs — silent background push

    /// Fired when a push arrives while the app is running.
    /// The NSE handles `mutable-content` alerts, but the app must still react
    /// to rfed wake pushes that arrive as `content-available` notifications or
    /// that bypass the NSE entirely.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard userInfo["rfed"] != nil else {
            completionHandler(.noData)
            return
        }

        let isActive = application.applicationState == .active
        let hasContentAvailable = apsFlag(userInfo, key: "content-available")
        let hasMutableContent = apsFlag(userInfo, key: "mutable-content")
        print(
            "[APNs] remote push received active=\(isActive) " +
            "content-available=\(hasContentAvailable) " +
            "mutable-content=\(hasMutableContent)"
        )

        Task { @MainActor [weak self] in
            guard let self else {
                completionHandler(.failed)
                return
            }

            // --- Explicit APNs push receipt log ---
            print("[APNs] didReceiveRemoteNotification: APNs push received, importing NSE messages")

            // Import any message the NSE already fetched before we decide
            // whether we also need to wake the full stack.
            self.repository.importNSEMessages()

            if isActive {
                if self.repository.serviceRunning {
                    self.repository.pollPropagationNode(force: true)
                } else {
                    self.repository.startService()
                }
            } else {
                if !self.repository.serviceRunning {
                    self.repository.startService()
                }
                self.beginBackgroundExecution(repository: self.repository, forcePoll: true)
            }

            completionHandler(.newData)
        }
    }

    private func apsFlag(_ userInfo: [AnyHashable: Any], key: String) -> Bool {
        guard let aps = userInfo["aps"] as? [AnyHashable: Any] else { return false }
        if let value = aps[key] as? NSNumber {
            return value.intValue != 0
        }
        return false
    }

    // MARK: - Immediate background execution

    /// Request background time from the OS (~30 seconds guaranteed).
    /// This keeps the Rust stack alive long enough to flush outbound
    /// messages and poll propagation for new ones.
    func beginBackgroundExecution(repository: ChatRepository, forcePoll: Bool = false) {
        // End any existing background task first
        if bgTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskId)
            bgTaskId = .invalid
        }

        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "RetichatPoll") { [weak self, weak repository] in
            // Expiration — system is about to suspend us, which means iOS
            // will tear down all our TCP sockets and Reticulum links.
            // Mark the repository so the next foreground transition issues
            // a fresh PSYNC (any messages that arrived while we were
            // suspended would otherwise wait until the 5-minute timer fires).
            repository?.psyncNeededOnForeground = true
            guard let self else { return }
            if self.bgTaskId != .invalid {
                UIApplication.shared.endBackgroundTask(self.bgTaskId)
                self.bgTaskId = .invalid
            }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            // Flush any outbound messages waiting in the queue
            repository.flushPendingMessages()

            // Poll propagation nodes for new messages
            repository.pollPropagationNode(force: forcePoll)

            // Give the Rust networking stack time to complete the request
            try? await Task.sleep(for: .seconds(20))

            // Poll again to catch responses that arrived during wait
            repository.pollPropagationNode(force: forcePoll)

            // Persist path table and ratchets to disk before suspension
            repository.persist()

            // End background task
            if self.bgTaskId != .invalid {
                UIApplication.shared.endBackgroundTask(self.bgTaskId)
                self.bgTaskId = .invalid
            }
        }
    }

    func endBackgroundExecution() {
        if bgTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskId)
            bgTaskId = .invalid
        }
    }
}

// MARK: - App

@main
struct RetichatApp: App {
    @UIApplicationDelegateAdaptor(RetichatAppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    /// Repository and ModelContainer are owned by the AppDelegate so they’re
    /// available during `didReceiveRemoteNotification` on cold launch.
    private var repository: ChatRepository { appDelegate.repository }
    private var modelContainer: ModelContainer { appDelegate.modelContainer }
    private var channelClient: RfedChannelClient { appDelegate.channelClient }

    var body: some Scene {
        WindowGroup("") {
            ContentView()
                .environmentObject(repository)
                .environmentObject(channelClient)
                .modelContainer(modelContainer)
                .onOpenURL { url in
                    handleDeepLink(url)
                }
                .onAppear {
                    requestNotificationPermission()
                }
                .onReceive(repository.$serviceRunning) { running in
                    guard running, let client = repository.lxmfClient else { return }
                    channelClient.configure(
                        modelContext: modelContainer.mainContext,
                        identityHandle: client.identityHandle,
                        ownHashHex: repository.ownHashHex
                    )
                    channelClient.start()
                    // NOTE: Do NOT call ConnectionStateManager.openRfedNodeLink()
                    // here — `ConnectionStateManager.register(lxmfClient:)`
                    // already opened it during `finishStartService`. Calling
                    // again would be a no-op now that `app_link_open` is gated
                    // on PATH_REQUESTED, but it is also redundant signal noise
                    // in the startup log. The startup ordering is documented
                    // in `ChatRepository.finishStartService` (single sequenced
                    // path: identity → callbacks → connection-state register
                    // → publish → polling → notify → channelClient.start).
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Stop any in-flight background task
                appDelegate.endBackgroundExecution()

                // Clear badge when user opens the app
                NotificationManager.shared.clearAll()

                if !repository.serviceRunning {
                    Task { repository.startService() }
                } else {
                    // Import any messages the NSE delivered while backgrounded
                    repository.importNSEMessages()
                    // Force a PSYNC only if iOS actually suspended us
                    // (sockets would have been torn down). For quick
                    // app-switches the throttle keeps us off the network.
                    let needPsync = repository.psyncNeededOnForeground
                    repository.psyncNeededOnForeground = false
                    repository.pollPropagationNode(force: needPsync)
                    // Re-establish path discovery for the active conversation (if any).
                    ConnectionStateManager.shared.onAppForeground()
                    // Re-open the persistent rfed node link.
                    ConnectionStateManager.shared.openRfedNodeLink()
                    // Re-announce rfed delivery to flush deferred channel blobs
                    channelClient.announceDelivery()
                    // Note: lxmf.delivery is auto-announced by Transport's
                    // publish daemon on every interface up-edge and every
                    // 30 minutes — no explicit foreground re-announce needed.
                }
            case .background:
                // Do NOT close the rfed link here — rapid app-switching would
                // destroy an active link unnecessarily and force a slow
                // re-establishment on every return to foreground.  The link will
                // go STALE naturally after the keepalive timeout if the app stays
                // backgrounded long enough, and the reconnect handler will
                // re-establish it on the next rfed.channel announce.
                // Request immediate background time (~30s) to flush outbound and poll.
                appDelegate.beginBackgroundExecution(repository: repository)
            default:
                break
            }
        }
    }

    // MARK: - Deep link: lxmf://<hash>

    private func handleDeepLink(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "lxma" || scheme == "lxmf" else { return }
        // host may be <hash> or <hash>.<pubkey> — extract hash only
        let raw = (url.host ?? "").lowercased()
        let hashPart = raw.components(separatedBy: ".").first ?? raw
        let hash = hashPart.filter { "0123456789abcdef".contains($0) }
        guard hash.count == 32 else { return }
        _ = repository.createDirectChat(destHash: hash)
        NotificationCenter.default.post(
            name: .init("OpenChat"),
            object: hash
        )
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        NotificationManager.shared.checkPermission { status in
            switch status {
            case .notDetermined:
                NotificationManager.shared.requestPermission()
            case .authorized, .provisional, .ephemeral:
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            default:
                break
            }
        }
    }

}
