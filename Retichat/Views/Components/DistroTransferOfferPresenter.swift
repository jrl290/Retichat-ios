//
//  DistroTransferOfferPresenter.swift
//  Retichat
//
//  "Import distro identity?" — shown when another of our devices sends this
//  one its distro key (RFed SPEC §17.9). iOS counterpart of Android
//  DistroTransferOfferDialog (IdentityScreen.kt), which is hosted at the
//  NavGraph root (NavGraph.kt:55-56) so it can appear over any screen.
//
//  Why UIKit: a SwiftUI .alert cannot present from a view that a sheet
//  covers, and Settings (→ Identity → Import/Add-device) and
//  ConversationView both stack sheets. Presenting a UIAlertController from
//  the top-most view controller works above any sheet.
//

import SwiftUI
import UIKit

@MainActor
final class DistroTransferOfferCoordinator {
    static let shared = DistroTransferOfferCoordinator()

    /// Weak: UIKit owns the alert while it is on screen (or the pending
    /// presentation closure does while it waits), so nil here means the alert
    /// is gone and a still-pending offer must be shown again.
    private weak var shown: OfferAlertController?
    private var shownId: UUID?

    private init() {}

    /// Makes the screen match `offer`: nothing when nil, one alert otherwise.
    /// Idempotent — safe to call from every event that might have changed it.
    func sync(_ offer: DistroTransferOffer?) {
        if offer?.id == shownId, offer == nil || shown != nil { return }

        let old = shown
        shown = nil
        shownId = nil
        var next: (alert: OfferAlertController, id: UUID)?
        if let offer {
            let alert = makeAlert(offer)
            // Recorded now, before it is on screen, so a repeat sync for the
            // same offer while it waits is a no-op (the closure below holds it).
            shown = alert
            shownId = offer.id
            next = (alert, offer.id)
        }
        if let old, old.presentingViewController != nil {
            // Show the newer offer only once the old alert is gone — the
            // dismissal completion is the event, not a delay.
            old.dismiss(animated: true) { [weak self] in
                if let next { self?.present(next.alert, id: next.id) }
            }
            return
        }
        if let next { present(next.alert, id: next.id) }
    }

    private func makeAlert(_ offer: DistroTransferOffer) -> OfferAlertController {
        let msg = "Device \(offer.fromHashHex.prefix(12))… sent this device a shared distro identity. "
            + "Importing it makes its address this device's address too"
            + (offer.replacesCurrent ? ", replacing the current one." : ".")
        let alert = OfferAlertController(title: "Import distro identity?", message: msg, preferredStyle: .alert)
        alert.offerId = offer.id
        let id = offer.id
        alert.addAction(UIAlertAction(title: "Ignore", style: .cancel) { [weak alert] _ in
            alert?.answered = true
            DistroTransferOfferCoordinator.shared.answered(id)
            RfedDistroClient.shared.resolveTransfer(accept: false)
        })
        alert.addAction(UIAlertAction(title: "Import", style: .default) { [weak alert] _ in
            alert?.answered = true
            DistroTransferOfferCoordinator.shared.answered(id)
            RfedDistroClient.shared.resolveTransfer(accept: true)
        })
        return alert
    }

    private func present(_ alert: OfferAlertController, id: UUID) {
        // A newer sync may have replaced or cleared this offer while we waited.
        guard shownId == id else { return }
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
        else {
            // No key window (app not active). The next sync — on scenePhase
            // .active — presents it from that event.
            shown = nil
            shownId = nil
            return
        }
        var top = root
        while let next = top.presentedViewController { top = next }

        if top.isBeingDismissed, let coordinator = top.transitionCoordinator {
            // Wait for the dismissal transition to finish, then re-resolve the
            // top — it will be a different controller by then.
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                self?.present(alert, id: id)
            }
            return
        }
        top.present(alert, animated: true)
    }

    /// The user tapped Import or Ignore on the alert for offer `id`; that
    /// alert dismisses itself. If vanished() already re-presented the same
    /// offer (UIKit may run the action handler after viewDidDisappear), take
    /// the copy down too — the offer is answered.
    fileprivate func answered(_ id: UUID) {
        guard shownId == id else { return }
        let copy = shown
        shown = nil
        shownId = nil
        if let copy, !copy.answered, copy.presentingViewController != nil {
            copy.dismiss(animated: true)
        }
    }

    /// `alert` left the screen without Import or Ignore — UIKit tears a
    /// presented alert down with the sheet it sits on (ContentView closes
    /// Settings on .openChatFromNotification; AddDeviceSheet and
    /// ImportDistroSheet close themselves). Without this the offer stayed
    /// pending but invisible until the next foreground.
    fileprivate func vanished(_ alert: OfferAlertController) {
        // Only the alert we still consider shown: a replaced alert (sync's
        // old.dismiss) or an answered one is not ours to re-show.
        guard shown === alert || (shown == nil && shownId == alert.offerId) else { return }
        shown = nil
        shownId = nil
        // Hop to the next main-actor turn: this runs inside the dismissal
        // transition, when presenting would be refused, and it lets an
        // action handler that UIKit runs after viewDidDisappear land first
        // (it clears pendingTransfer, making this sync a no-op). An
        // ordering hop on the main queue, not a timed wait.
        Task { @MainActor in
            DistroTransferOfferCoordinator.shared.sync(RfedDistroClient.shared.pendingTransfer)
        }
    }
}

/// Tells the coordinator when it leaves the screen unanswered.
final class OfferAlertController: UIAlertController {
    fileprivate var offerId: UUID?
    fileprivate var answered = false

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard !answered else { return }
        DistroTransferOfferCoordinator.shared.vanished(self)
    }
}

// MARK: - View modifier

private struct DistroTransferOfferPresenterModifier: ViewModifier {
    @StateObject private var distroClient = RfedDistroClient.shared
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onReceive(distroClient.$pendingTransfer) { offer in
                DistroTransferOfferCoordinator.shared.sync(offer)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    DistroTransferOfferCoordinator.shared.sync(distroClient.pendingTransfer)
                }
            }
            .onAppear {
                DistroTransferOfferCoordinator.shared.sync(distroClient.pendingTransfer)
            }
    }
}

extension View {
    /// Host once, at the app root (ContentView). Mirrors Android hosting
    /// DistroTransferOfferDialog outside the NavHost.
    func distroTransferOfferPresenter() -> some View {
        modifier(DistroTransferOfferPresenterModifier())
    }
}
