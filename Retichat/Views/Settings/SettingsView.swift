//
//  SettingsView.swift
//  Retichat
//
//  Full settings screen: service control, identity display, display name,
//  connection preferences, network interface management.
//  Mirrors Android SettingsScreen.kt.
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @EnvironmentObject var repository: ChatRepository
    @StateObject private var vm = SettingsViewModel()
    @Environment(\.dismiss) private var dismiss

    @State private var showQR = false
    @State private var showRevertAlert = false
    @State private var showAddInterface = false
    @State private var newInterfaceName = ""
    @State private var newInterfaceHost = ""
    @State private var newInterfacePort = ""
    @State private var editingInterface: PendingInterface?
    @State private var showEditInterface = false
    @State private var notificationStatus: String = "Checking…"

    var body: some View {
        NavigationStack {
            ZStack {
                Color.retichatBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        identitySection
                        profileSection
                        privacySection
                        rfedSection
                        notificationSection
                        interfacesSection
                        aboutSection
                    }
                    .padding()
                }
                .blur(radius: (showQR || showAddInterface || showEditInterface) ? 8 : 0)
                .animation(.easeInOut(duration: 0.25), value: showQR || showAddInterface || showEditInterface)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if vm.hasChanges {
                            showRevertAlert = true
                        } else {
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apply") {
                        applySettings()
                    }
                    .disabled(!vm.hasChanges)
                }
            }
            .alert("Unsaved Changes", isPresented: $showRevertAlert) {
                Button("Revert", role: .destructive) {
                    vm.revert()
                    dismiss()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Revert to your original settings and go back?")
            }
            .sheet(isPresented: $showQR) {
                QRCodeView(mode: .display)
            }
            .sheet(isPresented: $showAddInterface) {
                interfaceEditor(existing: nil)
            }
            .sheet(isPresented: $showEditInterface) {
                if let iface = editingInterface {
                    interfaceEditor(existing: iface)
                }
            }
            .onAppear {
                vm.loadInterfaces(from: repository)
                refreshNotificationStatus()
            }
        }
    }

    // MARK: - Apply

    private func applySettings() {
        // Capture old rfed notify hash before prefs are overwritten.
        let oldNotifyHash = UserPreferences.shared.rfedNotifyHash
        let rfedNodeChanged = vm.rfedNodeIdentityHash != UserPreferences.shared.rfedNodeIdentityHash

        // Persist all settings to UserDefaults.
        vm.apply()
        vm.applyInterfaces(to: repository)
        vm.markClean()

        // If the rfed node changed and the service is running, best-effort
        // deregister from the old node before restarting (which will re-register
        // with the new node automatically via registerRfedNotify()).
        if rfedNodeChanged,
           let client = repository.lxmfClient {
            RfedNotifyRegistrar.shared.deregisterFrom(
                oldNotifyHashHex: oldNotifyHash,
                identityHandle: client.identityHandle
            )
        }

        guard repository.serviceRunning else { return }
        repository.stopService()
        Task { repository.startService() }
    }

    // MARK: - Identity

    private var identitySection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Identity")
                    .font(.headline)
                    .foregroundColor(.retichatOnSurface)

                let hash = repository.ownHashHex
                if hash.isEmpty {
                    Text("Not loaded")
                        .foregroundColor(.retichatOnSurfaceVariant)
                } else {
                    HStack {
                        Text(hash)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.retichatOnSurfaceVariant)
                            .textSelection(.enabled)
                            .lineLimit(1)

                        Spacer()

                        Button {
                            UIPasteboard.general.string = hash
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                        }
                        .tint(.retichatPrimary)

                        Button {
                            showQR = true
                        } label: {
                            Image(systemName: "qrcode")
                                .font(.caption)
                        }
                        .tint(.retichatPrimary)
                    }
                }
            }
        }
    }

    // MARK: - Profile

    private var profileSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Profile")
                    .font(.headline)
                    .foregroundColor(.retichatOnSurface)

                TextField("Display Name", text: $vm.displayName)
                    .foregroundColor(.retichatOnSurface)
                    .padding(10)
                    .glassBackground(cornerRadius: 8)
            }
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Privacy")
                    .font(.headline)
                    .foregroundColor(.retichatOnSurface)

                Toggle(isOn: $vm.filterStrangers) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Privacy filter")
                            .foregroundColor(.retichatOnSurface)
                        Text("Only accept messages from contacts you have explicitly added")
                            .font(.caption)
                            .foregroundColor(.retichatOnSurfaceVariant)
                    }
                }
                .tint(.retichatPrimary)
            }
        }
    }

    // MARK: - RFed Node

    private var rfedSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("RFed Node")
                    .font(.headline)
                    .foregroundColor(.retichatOnSurface)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Node Identity Hash")
                        .font(.caption)
                        .foregroundColor(.retichatOnSurfaceVariant)
                    TextField("32-char hex", text: $vm.rfedNodeIdentityHash)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.retichatOnSurface)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(10)
                        .glassBackground(cornerRadius: 8)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("LXMF Propagation")
                        .font(.caption)
                        .foregroundColor(.retichatOnSurfaceVariant)
                    TextField(
                        vm.derivedLxmfPropHex.isEmpty ? "32-char hex (optional)" : vm.derivedLxmfPropHex,
                        text: $vm.rfedLxmfPropOverride
                    )
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.retichatOnSurface)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(10)
                    .glassBackground(cornerRadius: 8)
                }

                Text("Enter the RFed Node's public identity hash. Notify, channel, delivery, and LXMF propagation hashes are derived automatically. Leave the propagation field empty to use the derived address, or enter a different one to override it. Changes take effect on next service restart.")
                    .font(.caption)
                    .foregroundColor(.retichatOnSurfaceVariant)
            }
        }
    }

    // MARK: - Notifications

    private var notificationSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Notifications")
                    .font(.headline)
                    .foregroundColor(.retichatOnSurface)

                HStack {
                    Image(systemName: notificationStatus == "Enabled"
                          ? "bell.badge.fill" : "bell.slash")
                        .foregroundColor(notificationStatus == "Enabled"
                                         ? .retichatPrimary : .retichatOnSurfaceVariant)

                    Text(notificationStatus)
                        .foregroundColor(.retichatOnSurface)

                    Spacer()

                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("iOS Settings")
                            Image(systemName: "arrow.up.right.square")
                        }
                        .font(.caption)
                    }
                    .tint(.retichatPrimary)
                }

                Text("Message notifications are delivered when the app runs in the background or you're in a different chat.")
                    .font(.caption)
                    .foregroundColor(.retichatOnSurfaceVariant)
            }
        }
    }

    private func refreshNotificationStatus() {
        NotificationManager.shared.checkPermission { status in
            switch status {
            case .authorized:
                notificationStatus = "Enabled"
            case .denied:
                notificationStatus = "Denied"
            case .provisional:
                notificationStatus = "Provisional"
            case .notDetermined:
                notificationStatus = "Not requested"
            case .ephemeral:
                notificationStatus = "Ephemeral"
            @unknown default:
                notificationStatus = "Unknown"
            }
        }
    }

    // MARK: - Interfaces

    private var interfacesSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Network Interfaces")
                        .font(.headline)
                        .foregroundColor(.retichatOnSurface)
                    Spacer()
                    Button {
                        newInterfaceName = ""
                        newInterfaceHost = ""
                        newInterfacePort = "4242"
                        showAddInterface = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                    .tint(.retichatPrimary)
                }

                if vm.pendingInterfaces.isEmpty {
                    Text("Using default endpoints")
                        .font(.caption)
                        .foregroundColor(.retichatOnSurfaceVariant)
                } else {
                    ForEach($vm.pendingInterfaces) { $iface in
                        HStack {
                            Circle()
                                .fill(interfaceDotColor(for: iface))
                                .frame(width: 8, height: 8)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(iface.name)
                                    .font(.subheadline)
                                    .foregroundColor(.retichatOnSurface)
                                Text("\(iface.targetHost):\(String(iface.targetPort))")
                                    .font(.caption)
                                    .foregroundColor(.retichatOnSurfaceVariant)
                            }

                            Spacer()

                            Toggle("", isOn: $iface.enabled)
                                .tint(.retichatPrimary)
                                .labelsHidden()

                            Button {
                                editingInterface = iface
                                newInterfaceName = iface.name
                                newInterfaceHost = iface.targetHost
                                newInterfacePort = String(iface.targetPort)
                                showEditInterface = true
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.body)
                                    .frame(width: 36, height: 36)
                                    .contentShape(Rectangle())
                            }
                            .tint(.retichatOnSurfaceVariant)

                            Button {
                                vm.pendingInterfaces.removeAll { $0.id == iface.id }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.body)
                                    .frame(width: 36, height: 36)
                                    .contentShape(Rectangle())
                            }
                            .tint(.retichatError)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private func interfaceDotColor(for iface: PendingInterface) -> Color {
        if !iface.enabled {
            return .retichatOnSurfaceVariant
        }
        return repository.serviceRunning ? .retichatSuccess : .retichatError
    }

    // MARK: - About

    private var aboutSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("About")
                    .font(.headline)
                    .foregroundColor(.retichatOnSurface)

                HStack {
                    Text("Version")
                        .foregroundColor(.retichatOnSurfaceVariant)
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                        .foregroundColor(.retichatOnSurface)
                }

                HStack {
                    Text("Build")
                        .foregroundColor(.retichatOnSurfaceVariant)
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                        .foregroundColor(.retichatOnSurface)
                }

                Text("Built on Reticulum & LXMF")
                    .font(.caption)
                    .foregroundColor(.retichatOnSurfaceVariant)
            }
        }
    }

    // MARK: - Interface Editor Sheet

    private func interfaceEditor(existing: PendingInterface?) -> some View {
        NavigationStack {
            ZStack {
                Color.retichatBackground.ignoresSafeArea()
                VStack(spacing: 16) {
                    TextField("Name", text: $newInterfaceName)
                        .foregroundColor(.retichatOnSurface)
                        .padding(10)
                        .glassBackground(cornerRadius: 8)

                    TextField("Host / IP", text: $newInterfaceHost)
                        .foregroundColor(.retichatOnSurface)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .padding(10)
                        .glassBackground(cornerRadius: 8)

                    TextField("Port", text: $newInterfacePort)
                        .foregroundColor(.retichatOnSurface)
                        .keyboardType(.numberPad)
                        .padding(10)
                        .glassBackground(cornerRadius: 8)

                    Spacer()
                }
                .padding()
            }
            .navigationTitle(existing == nil ? "Add Interface" : "Edit Interface")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        showAddInterface = false
                        showEditInterface = false
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        let port = Int(newInterfacePort) ?? 4242
                        if let existing = existing,
                           let idx = vm.pendingInterfaces.firstIndex(where: { $0.id == existing.id }) {
                            vm.pendingInterfaces[idx].name = newInterfaceName
                            vm.pendingInterfaces[idx].targetHost = newInterfaceHost
                            vm.pendingInterfaces[idx].targetPort = port
                        } else {
                            let newIface = PendingInterface(
                                id: UUID().uuidString,
                                type: "TCPClient",
                                name: newInterfaceName,
                                targetHost: newInterfaceHost,
                                targetPort: port,
                                enabled: true
                            )
                            vm.pendingInterfaces.append(newIface)
                        }
                        showAddInterface = false
                        showEditInterface = false
                    }
                    .disabled(newInterfaceHost.isEmpty)
                }
            }
        }
    }
}
