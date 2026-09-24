//
//  Toast.swift
//  Retichat
//
//  A small transient message at the bottom of a screen — the iOS stand-in
//  for an Android Toast (IdentityScreen.kt copy(), "Identity sent", …) —
//  and the app-wide window that shows RfedDistroClient's notices.
//

import Combine
import SwiftUI
import UIKit

// MARK: - Toast

/// The bubble itself, shared by the per-screen toast and the app-wide
/// distro notice window so both look the same.
private struct ToastBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.retichatOnSurface)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            // Opaque under the glass: the toast floats over monospaced key
            // text on the Identity screen, which showed through the glass
            // alone and made the notice unreadable.
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.retichatSurfaceVariant))
            .glassBackground(cornerRadius: 16)
            .padding(.horizontal, 24)
    }
}

private struct ToastModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                ZStack {
                    if let msg = message {
                        ToastBubble(text: msg)
                            .transition(.opacity)
                    }
                }
                .padding(.bottom, 24)
                .animation(.easeInOut(duration: 0.2), value: message)
                .allowsHitTesting(false)
            }
            // Presentation timing only: how long the text stays readable.
            // No network, no synchronisation — nothing waits on this.
            // A new message restarts the timer (task id changes).
            .task(id: message) {
                guard message != nil else { return }
                try? await Task.sleep(for: .seconds(1.6))
                guard !Task.isCancelled else { return }
                message = nil
            }
    }
}

extension View {
    /// Shows `message` briefly at the bottom of the view, then sets it to nil.
    func toast(_ message: Binding<String?>) -> some View {
        modifier(ToastModifier(message: message))
    }
}

// MARK: - Distro notices

/// Shows RfedDistroClient's one-shot `notice` ("Distro identity imported",
/// "Identity delivered", "Could not deliver the identity", …) once, above
/// every sheet, and clears it only after it has actually been on screen.
///
/// Why a window: these outcomes arrive seconds to minutes after the action,
/// usually while Settings (a sheet over ContentView) or a sheet inside it is
/// up. A SwiftUI overlay on the root is drawn UNDER those sheets, and its
/// timer then cleared the notice unseen — the failure path was silent in
/// practice. Android shows the same outcomes as system Toasts
/// (RfedDistroClient.kt), which draw above every screen; a passthrough
/// UIWindow above the app's window is the iOS equivalent. Same reasoning as
/// DistroTransferOfferCoordinator, which presents its alert from UIKit.
@MainActor
final class DistroNoticeCoordinator {
    static let shared = DistroNoticeCoordinator()

    private let model = DistroNoticeModel()
    private var window: UIWindow?
    private var clearTask: Task<Void, Never>?

    private init() {}

    /// Makes the screen match `notice`. `active` is the scene phase: while
    /// the app is not frontmost nothing is visible, so the notice stays
    /// pending (not cleared) and is shown by the sync on the next `.active`.
    func sync(_ notice: String?, active: Bool) {
        clearTask?.cancel()
        clearTask = nil
        guard let notice, active, let window = ensureWindow() else {
            hide()
            return
        }
        window.isHidden = false
        withAnimation(.easeInOut(duration: 0.2)) { model.text = notice }
        // Android Toasts are read by TalkBack; do the same for VoiceOver.
        UIAccessibility.post(notification: .announcement, argument: notice)
        // Presentation timing only (how long the text stays readable), the
        // same 1.6 s as the per-screen toast. Nothing waits on it.
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.clearTask = nil
            RfedDistroClient.shared.clearNotice()   // → sync(nil) → hide()
        }
    }

    private func hide() {
        guard model.text != nil else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            model.text = nil
        } completion: { [weak self] in
            // A newer notice may have been shown during the fade-out.
            guard let self, self.model.text == nil else { return }
            self.window?.isHidden = true
        }
    }

    /// The overlay window for the frontmost scene; nil when no scene is in
    /// the foreground (the notice then waits for the next `.active` sync).
    private func ensureWindow() -> UIWindow? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return nil }
        if let window, window.windowScene === scene { return window }

        let w = PassthroughWindow(windowScene: scene)
        // Above the app window and anything it presents (sheets, the offer
        // alert). Never made key, so it takes no keyboard or focus.
        w.windowLevel = .alert + 1
        w.backgroundColor = .clear
        w.isUserInteractionEnabled = false
        // The app is dark-only (ContentView .preferredColorScheme(.dark));
        // this window is outside that view tree, so say it again.
        w.overrideUserInterfaceStyle = .dark
        let host = UIHostingController(rootView: DistroNoticeOverlay(model: model))
        host.view.backgroundColor = .clear
        w.rootViewController = host
        w.isHidden = true
        window?.isHidden = true
        window = w
        return w
    }
}

@MainActor
private final class DistroNoticeModel: ObservableObject {
    @Published var text: String?
}

/// Touches fall through to the app window underneath.
private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

private struct DistroNoticeOverlay: View {
    @ObservedObject var model: DistroNoticeModel

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            if let text = model.text {
                ToastBubble(text: text)
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct DistroNoticePresenterModifier: ViewModifier {
    @StateObject private var distroClient = RfedDistroClient.shared
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onReceive(distroClient.$notice) { notice in
                DistroNoticeCoordinator.shared.sync(notice, active: scenePhase == .active)
            }
            .onChange(of: scenePhase) { _, phase in
                DistroNoticeCoordinator.shared.sync(distroClient.notice, active: phase == .active)
            }
    }
}

extension View {
    /// Host once, at the app root (ContentView), next to
    /// distroTransferOfferPresenter(). Screens must not add their own copy:
    /// the notice is drawn by one window above everything.
    func distroNoticePresenter() -> some View {
        modifier(DistroNoticePresenterModifier())
    }
}
