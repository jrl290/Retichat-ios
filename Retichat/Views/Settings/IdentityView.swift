//
//  IdentityView.swift
//  Retichat
//
//  Settings → Identity: the distro address (shared by all of this person's
//  devices, RFed SPEC §17) and this device's own address, each with its
//  identity hash, public key and contact link.
//
//  Mirrors Android ui/settings/IdentityScreen.kt (wording, sections, dialogs)
//  and retichat.com app.js _renderIdentityModal (distro section first, the
//  two identities kept as separate groups). The private keys are never shown
//  (Android; SPEC §17.9 — the distro key only leaves via "Add another device").
//

import SwiftUI

struct IdentityView: View {
    @EnvironmentObject var repository: ChatRepository
    @StateObject private var distroClient = RfedDistroClient.shared

    @State private var device: DeviceIdentityInfo?
    @State private var showGenerate = false
    @State private var showImport = false
    @State private var showForget = false
    @State private var showAddDevice = false
    @State private var importText = ""
    @State private var addDeviceHash = ""
    @State private var busy = false
    @State private var toast: String?

    var body: some View {
        ZStack {
            Color.retichatBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    distroSection
                    deviceSection
                }
                .padding()
            }
            .blur(radius: (showImport || showAddDevice) ? 8 : 0)
            .animation(.easeInOut(duration: 0.25), value: showImport || showAddDevice)
        }
        .navigationTitle("Identity")
        .navigationBarTitleDisplayMode(.inline)
        .toast($toast)
        // Later outcomes of Add another device / an accepted transfer
        // ("Identity delivered", …) are RfedDistroClient notices, shown once
        // app-wide by ContentView's distroNoticePresenter — not here too.
        .onAppear { device = repository.deviceIdentityInfo() }
        // The device values only exist while the stack runs (Android computes
        // them once with remember{}; here they follow the service).
        .onChange(of: repository.serviceRunning) { device = repository.deviceIdentityInfo() }
        .alert("Generate a distro identity?", isPresented: $showGenerate) {
            Button("Cancel", role: .cancel) {}
            Button("Generate") {
                busy = true
                Task {
                    let r = await distroClient.generate()
                    busy = false
                    switch r {
                    case .ok: break
                    case .storageFailed: toast = "Could not save the distro key to the Keychain"
                    case .invalidKey: toast = "Could not generate a distro identity"
                    }
                }
            }
        } message: {
            Text("This device will create a new shared address and register it with RFed. Add your other devices afterwards with “Add another device”.")
        }
        .alert("Forget the distro identity?", isPresented: $showForget) {
            Button("Cancel", role: .cancel) {}
            Button("Forget", role: .destructive) {
                busy = true
                Task {
                    let ok = await distroClient.forget()
                    busy = false
                    // Android ignores the unregister result; iOS surfaces it
                    // (plan critique 10) because RFed keeps fanning out to a
                    // device it still believes is registered.
                    if !ok {
                        toast = "Distro forgotten. RFed did not confirm, so it may keep sending to this device."
                    }
                }
            }
        } message: {
            Text("This device stops receiving mail for the shared address. Other devices that hold the key are not affected.")
        }
        // A sheet, not an alert: on a bad key the form must stay open with
        // the text intact (Android keeps its Import dialog open).
        .sheet(isPresented: $showImport) {
            ImportDistroSheet(isPresented: $showImport, text: $importText)
        }
        .sheet(isPresented: $showAddDevice) {
            AddDeviceSheet(isPresented: $showAddDevice, hash: $addDeviceHash) { h in
                Task {
                    let ok = await distroClient.sendIdentity(toDeviceHashHex: h)
                    toast = ok ? "Identity sent" : "Could not send the identity"
                }
            }
        }
    }

    // MARK: - Distro address

    private var distroSection: some View {
        sectionCard(title: "Distro address") {
            if let d = distroClient.distro {
                keyValueRow(label: "Address", value: d.deliveryHashHex)
                keyValueRow(label: "Identity", value: d.identityHashHex)
                keyValueRow(label: "Public key", value: d.publicKeyHex)
                keyValueRow(label: "Contact", value: d.contactUri)

                hint("Give senders the contact link. Address is where distro mail is delivered; identity is the key's own hash and is not routable.")

                Text(registrationLine(distroClient.status))
                    .font(.caption2)
                    .foregroundColor(.retichatOnSurfaceVariant)

                HStack(spacing: 8) {
                    Button("Add another device") {
                        addDeviceHash = ""
                        showAddDevice = true
                    }
                    .buttonStyle(.bordered)

                    Button("Forget") { showForget = true }
                        .buttonStyle(.borderless)
                }
                .tint(.retichatPrimary)
                .disabled(busy)
            } else {
                hint("One LXMF address shared by all your devices. Anything sent to it is fanned out by RFed to every registered device.")

                // A key is stored but will not load. Say so rather than show
                // a bare Generate/Import: both keep a Keychain backup of the
                // unreadable item before replacing it (DistroManager
                // `.undecodable`; Android logs such a key and lets import
                // or generate back it up and replace it).
                if distroClient.storedKeyUnreadable {
                    Text("A distro key is stored on this device but could not be loaded. Generate or Import replaces it and keeps a backup copy in the Keychain.")
                        .font(.caption)
                        .foregroundColor(.retichatError)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button("Generate") { showGenerate = true }
                        .buttonStyle(.borderedProminent)
                        .tint(.retichatPrimary)

                    Button("Import") {
                        importText = ""
                        showImport = true
                    }
                    .buttonStyle(.bordered)
                    .tint(.retichatPrimary)
                }
                .disabled(busy)
            }
        }
    }

    /// Same precedence as Android IdentityScreen.kt:146-152.
    private func registrationLine(_ s: DistroRegistrationStatus) -> String {
        if let err = s.lastError { return "RFed: \(err)" }
        if s.registered && s.announced { return "Registered with RFed · RFed announces this address" }
        if s.registered { return "Registered with RFed" }
        return "Not yet registered with RFed"
    }

    // MARK: - This device

    private var deviceSection: some View {
        sectionCard(title: "This device") {
            keyValueRow(label: "Address", value: device?.deliveryHashHex)
            keyValueRow(label: "Identity", value: device?.identityHashHex)
            keyValueRow(label: "Public key", value: device?.publicKeyHex)
            if let uri = device?.contactUri {
                keyValueRow(label: "Contact", value: uri)
            }

            hint(distroClient.hasDistro
                 ? "This device's own address. Messages you send go out from the distro address."
                 : "This device's own address. Share the contact link so others can reach you.")
        }
    }

    // MARK: - Helpers

    /// Android SectionCard.
    private func sectionCard<Content: View>(title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.retichatOnSurface)
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.retichatOnSurfaceVariant)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Line breaks at fixed points for long hex values: 32 characters per
    /// line, and for an lxma:// link a break after the scheme and after the
    /// address. Values that already fit a line are returned unchanged.
    static func displayGrouped(_ value: String) -> String {
        func chunks(_ s: Substring) -> [String] {
            stride(from: 0, to: s.count, by: 32).map { start in
                let a = s.index(s.startIndex, offsetBy: start)
                let b = s.index(a, offsetBy: min(32, s.count - start))
                return String(s[a..<b])
            }
        }
        if value.hasPrefix("lxma://"), let colon = value.lastIndex(of: ":"), colon > value.index(value.startIndex, offsetBy: 6) {
            let address = value[value.index(value.startIndex, offsetBy: 7)..<colon]
            let key = value[value.index(after: colon)...]
            return (["lxma://", String(address) + ":"] + chunks(key)).joined(separator: "\n")
        }
        guard value.count > 32 else { return value }
        return chunks(Substring(value)).joined(separator: "\n")
    }

    /// Android KeyValueRow: the value wraps under its label and never pushes
    /// the copy button off-screen. `nil` shows "—" (stack not running).
    private func keyValueRow(label: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.retichatOnSurfaceVariant)
            HStack(alignment: .top) {
                // Grouped for display only: iOS hyphenates a long unbroken
                // word, which put "-" into keys and contact links on screen
                // (the copy button always copies the exact value). Selection
                // stays off so a hand-copied value can't pick up the breaks.
                Text(verbatim: value.map(Self.displayGrouped) ?? "—")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.retichatOnSurface)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    guard let value else { return }
                    UIPasteboard.general.string = value
                    toast = "\(label) copied"
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .tint(.retichatPrimary)
                .disabled(value == nil)
                .accessibilityLabel("Copy \(label)")
            }
        }
    }
}

// MARK: - Import sheet

/// Own struct so its busy/toast state is local to the sheet — the parent's
/// toast would render underneath the sheet.
private struct ImportDistroSheet: View {
    @Binding var isPresented: Bool
    @Binding var text: String

    @State private var sheetBusy = false
    @State private var sheetToast: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.retichatBackground.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Paste a rfed-distro-private-key:// URI or a 128-character hex private key.")
                        .font(.caption)
                        .foregroundColor(.retichatOnSurfaceVariant)

                    TextField("", text: $text, axis: .vertical)
                        .lineLimit(3...6)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.retichatOnSurface)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(10)
                        .glassBackground(cornerRadius: 8)

                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Import distro identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Import") {
                        sheetBusy = true
                        Task {
                            let r = await RfedDistroClient.shared.importKey(text)
                            sheetBusy = false
                            switch r {
                            case .ok: isPresented = false
                            case .invalidKey: sheetToast = "That is not a distro private key"
                            case .storageFailed: sheetToast = "Could not save the distro key to the Keychain"
                            }
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sheetBusy)
                }
            }
        }
        .toast($sheetToast)
    }
}

// MARK: - Add-device sheet

/// "Add another device": sends the distro key to another of the user's
/// devices as an LXMF transfer (SPEC §17.9). Android accepts any 32
/// characters; here the address must be 32 hex and not one of our own.
private struct AddDeviceSheet: View {
    @EnvironmentObject var repository: ChatRepository
    @Binding var isPresented: Bool
    @Binding var hash: String
    let onSend: (String) -> Void

    private var canSend: Bool {
        hash.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil
            && !repository.isOwnAddress(hash)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.retichatBackground.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Send the distro identity to another device you own. It travels as a private LXMF message; the other device is asked before importing it.")
                        .font(.caption)
                        .foregroundColor(.retichatOnSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("That device's LXMF address")
                            .font(.caption)
                            .foregroundColor(.retichatOnSurfaceVariant)
                        TextField("", text: $hash)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.retichatOnSurface)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(10)
                            .glassBackground(cornerRadius: 8)
                    }

                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Add another device")
            // Large: inline, Cancel + "Send identity" left no room and the
            // title truncated to "Add another d…". Wording matches Android.
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Send identity") {
                        let h = hash
                        isPresented = false
                        onSend(h)
                    }
                    .disabled(!canSend)
                }
            }
            // Android IdentityScreen.kt:248 — trim().lowercase() on every change.
            .onChange(of: hash) { _, new in
                let clean = new.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if clean != new { hash = clean }
            }
        }
    }
}
