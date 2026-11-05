//
//  RfedCollect.swift
//  Retichat
//
//  What RFed holds for this device, collected in one order (James,
//  2026-11-05: "distro and propagation should be first"): the distro queue,
//  then the messages waiting on the propagation node, then the channels with
//  push on, the ones RFed wakes this device for (RfedNotifyRegistrar). The
//  other channels wait until they are opened. Android RfedCollect.kt.
//
//  It is how a device that holds no link to RFed (RfedLink.holdsNoLink)
//  collects: on a wake from RFed over the mesh (MeshWake.swift), on each link
//  the device opens for its requests, and at the 6-hour check. The
//  collection is one run on rfed.link (RfedLink.holding): the link opens
//  once for it and closes when it ends.
//
//  One collection at a time. A link that opens while one runs was opened by
//  it, and is covered by it; a wake while one runs may name a message stored
//  after its pulls passed, so the collection runs once more when it ends.
//

import Foundation
import UIKit

final class RfedCollect {
    private let repository: ChatRepository
    private let channelClient: RfedChannelClient
    private var turns = Turns()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(repository: ChatRepository, channelClient: RfedChannelClient) {
        self.repository = repository
        self.channelClient = channelClient
    }

    /// Collect, unless a collection runs. `why` is for the log; `linkOpened`:
    /// asked by a link opening.
    func request(why: String, linkOpened: Bool = false) {
        guard turns.ask(linkOpened: linkOpened) else { return }
        beginBackgroundTime()
        Task {
            var reason = why
            repeat {
                await collect(why: reason)
                reason = "a wake came while collecting"
            } while turns.next()
            // Paths and ratchets learned, kept before iOS suspends the app.
            repository.persist()
            endBackgroundTime()
        }
    }

    private func collect(why: String) async {
        let node = UserPreferences.shared.effectiveRfedNodeIdentityHash
        print("[RfedCollect] collecting (\(why)): the distro queue, then propagation, then the channels with push on")
        await RfedLink.shared.holding(nodeHexes: [node]) {
            await RfedDistroClient.shared.pull()
            _ = await repository.syncPropagationNode()
            await channelClient.pullPushChannels()
        }
    }

    /// Time to finish when the app is in the background. iOS may still
    /// suspend it; the collection goes on when the app resumes.
    private func beginBackgroundTime() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "RfedCollect") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTime() }
        }
    }

    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// One collection at a time; a wake while one runs has it run once more.
    struct Turns {
        private var running = false
        private var again = false

        /// True: the caller collects. False: the running collection covers
        /// it, or runs again for it.
        mutating func ask(linkOpened: Bool) -> Bool {
            if running {
                if !linkOpened { again = true }
                return false
            }
            running = true
            return true
        }

        /// Whether to collect again; when not, the collection has ended.
        mutating func next() -> Bool {
            if again {
                again = false
                return true
            }
            running = false
            return false
        }
    }
}
