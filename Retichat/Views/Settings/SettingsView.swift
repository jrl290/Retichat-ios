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
    @EnvironmentObject var channelClient: RfedChannelClient
    @StateObject private var vm = SettingsViewModel()
    /// Live RNode lifecycle status feed. Drives the leading status dot for
    /// RNode interface rows so it reflects real connection/configuration
    /// state without waiting for the Apply button. `@StateObject` (not
    /// `@ObservedObject`) so the SwiftUI subscription is established once
    /// and survives parent view re-inits — the singleton itself is never
    /// re-created.
    @StateObject private var rnodeCoord = RNodeInterfaceCoordinator.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showQR = false
    @State private var showRevertAlert = false
    @State private var showAddInterface = false
    @State private var showInterfaceTypeChooser = false
    @State private var addingKind: InterfaceKind = .tcpClient
    @State private var newInterfaceName = ""
    @State private var newInterfaceHost = ""
    @State private var newInterfacePort = ""
    /// Working RNode profile while the editor sheet is open.
    @State private var rnodeProfile: RNodeInterfaceProfile = .default
    @State private var editingInterface: PendingInterface?
    @State private var showEditInterface = false
    @State private var notificationStatus: String = "Checking…"

    /// Per-interface online status, keyed by interface name.  Refreshed by
    /// `interfaceStatusTimer` while the Settings screen is visible.  `nil`
    /// means the interface isn't known to the running transport (e.g. service
    /// not started, or pending interfaces that haven't been Applied yet).
    @State private var interfaceOnlineStatus: [String: Bool] = [:]
    @State private var interfaceStatusTimer: Timer?

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
                .blur(radius: (showQR || showAddInterface || showEditInterface || showInterfaceTypeChooser) ? 8 : 0)
                .animation(.easeInOut(duration: 0.25), value: showQR || showAddInterface || showEditInterface || showInterfaceTypeChooser)
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
            .sheet(isPresented: $showInterfaceTypeChooser) {
                interfaceTypeChooser
            }
            .sheet(isPresented: $showAddInterface) {
                interfaceEditor(existing: nil, kind: addingKind)
            }
            .sheet(isPresented: $showEditInterface) {
                if let iface = editingInterface {
                    interfaceEditor(existing: iface, kind: iface.kind)
                }
            }
            .onAppear {
                vm.loadInterfaces(from: repository)
                refreshNotificationStatus()
                channelClient.startRfedLinkMonitor()
                refreshInterfaceStatus()
                interfaceStatusTimer?.invalidate()
                interfaceStatusTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                    refreshInterfaceStatus()
                }
            }
            .onDisappear {
                channelClient.stopRfedLinkMonitor()
                interfaceStatusTimer?.invalidate()
                interfaceStatusTimer = nil
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
            VStack(alignment: .leading, spacing: 12) {
                Text("Profile")
                    .font(.headline)
                    .foregroundColor(.retichatOnSurface)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Display Name")
                        .font(.caption)
                        .foregroundColor(.retichatOnSurfaceVariant)
                    TextField("Your name in DMs", text: $vm.displayName)
                        .foregroundColor(.retichatOnSurface)
                        .padding(10)
                        .glassBackground(cornerRadius: 8)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Channel Display Name")
                        .font(.caption)
                        .foregroundColor(.retichatOnSurfaceVariant)
                    TextField(vm.displayName.isEmpty ? "Same as Display Name" : vm.displayName,
                              text: $vm.channelDisplayName)
                        .foregroundColor(.retichatOnSurface)
                        .padding(10)
                        .glassBackground(cornerRadius: 8)
                    Text("Shown to others in channels. If blank, uses your Display Name.")
                        .font(.caption2)
                        .foregroundColor(.retichatOnSurfaceVariant)
                }
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
                HStack {
                    Text("RFed Node")
                        .font(.headline)
                        .foregroundColor(.retichatOnSurface)
                    Spacer()
                    rfedNodeStatusIndicator
                }

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

    private var rfedNodeStatusIndicator: some View {
        let (color, label): (Color, String) = {
            switch channelClient.rfedNodeStatus {
            case .connected:    return (.green, "Linked")
            case .establishing: return (.orange, "Linking…")
            case .unreachable:  return (.red, "No path")
            case .unknown:      return (.gray, "")
            }
        }()
        return HStack(spacing: 5) {
            if channelClient.rfedNodeStatus != .unknown {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(.caption)
                    .foregroundColor(color)
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
                        showInterfaceTypeChooser = true
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
                    // NOTE: We deliberately use ForEach on the *value* collection (not
                    // ForEach($vm.pendingInterfaces)) and synthesize the Toggle binding
                    // by ID lookup. Index-derived bindings produced by ForEach($…) crash
                    // ("Fatal error: Index out of range" inside SwiftUI.ToggleState.stateFor)
                    // when a row is removed mid-update — the SwiftUI internal aggregate
                    // Toggle still holds a Binding<Bool> capturing the now-invalid index.
                    ForEach(vm.pendingInterfaces) { iface in
                        let ifaceID = iface.id
                        HStack {
                            Circle()
                                .fill(interfaceDotColor(for: iface))
                                .frame(width: 8, height: 8)

                            Image(systemName: iface.kind.symbolName)
                                .font(.body)
                                .foregroundColor(.retichatOnSurfaceVariant)
                                .frame(width: 18)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(iface.name)
                                    .font(.subheadline)
                                    .foregroundColor(.retichatOnSurface)
                                Text(interfaceSubtitle(for: iface))
                                    .font(.caption)
                                    .foregroundColor(.retichatOnSurfaceVariant)
                            }

                            Spacer()

                            Toggle("", isOn: Binding<Bool>(
                                get: {
                                    vm.pendingInterfaces.first(where: { $0.id == ifaceID })?.enabled ?? false
                                },
                                set: { newValue in
                                    if let idx = vm.pendingInterfaces.firstIndex(where: { $0.id == ifaceID }) {
                                        vm.pendingInterfaces[idx].enabled = newValue
                                    }
                                }
                            ))
                            .tint(.retichatPrimary)
                            .labelsHidden()

                            Button {
                                openEditor(for: iface)
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.body)
                                    .frame(width: 36, height: 36)
                                    .contentShape(Rectangle())
                            }
                            .tint(.retichatOnSurfaceVariant)

                            Button {
                                // Defer to the next runloop tick so the current SwiftUI
                                // update cycle finishes before the array shrinks.
                                DispatchQueue.main.async {
                                    vm.pendingInterfaces.removeAll { $0.id == ifaceID }
                                }
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

    /// Subtitle text for an interface row, based on type.
    private func interfaceSubtitle(for iface: PendingInterface) -> String {
        switch iface.kind {
        case .tcpClient:
            return "TCP • \(iface.targetHost):\(String(iface.targetPort))"
        case .rnode:
            if let p = RNodeInterfaceProfile(jsonString: iface.configJSON) {
                let dev = p.peripheralName.isEmpty ? "No device paired" : p.peripheralName
                let mhz = String(format: "%.3f MHz", Double(p.radio.frequency) / 1_000_000)
                return "RNode • \(dev) • \(mhz)"
            }
            return "RNode • not configured"
        }
    }

    /// Open the editor sheet for an existing row, prefilling state.
    private func openEditor(for iface: PendingInterface) {
        editingInterface = iface
        newInterfaceName = iface.name
        newInterfaceHost = iface.targetHost
        newInterfacePort = String(iface.targetPort)
        rnodeProfile = RNodeInterfaceProfile(jsonString: iface.configJSON) ?? .default
        showEditInterface = true
    }

    private func interfaceDotColor(for iface: PendingInterface) -> Color {
        if !iface.enabled {
            return .retichatOnSurfaceVariant
        }
        // Row hasn't been applied (new, or edited since last Apply): the
        // transport doesn't know about this configuration yet, so don't
        // claim it's offline — show a neutral "pending Apply" indicator.
        if vm.isUnsaved(iface) {
            return .retichatOnSurfaceVariant
        }
        // RNode rows: consult the coordinator's live lifecycle status so the
        // dot follows the project-wide convention
        // (grey idle / yellow trying / green ready / red failed) without
        // requiring the user to press Apply. As a robustness fallback, if the
        // coordinator hasn't reported anything yet but the Reticulum transport
        // already knows the interface is online, treat that as ready — the
        // transport's view is authoritative for actual data flow.
        if iface.type == InterfaceKind.rnode.rawValue {
            let transportOnline = repository.serviceRunning ? interfaceOnlineStatus[iface.name] : nil
            switch rnodeCoord.status(forID: iface.id) {
            case .ready:
                return .retichatSuccess
            case .connecting, .configuring:
                return .orange
            case .failed:
                // Coordinator thinks we failed, but transport may have
                // succeeded out-of-band (e.g. after a restart) — prefer the
                // authoritative transport view if it says online.
                return transportOnline == true ? .retichatSuccess : .retichatError
            case .idle:
                if transportOnline == true { return .retichatSuccess }
                if transportOnline == false { return .retichatError }
                return .retichatOnSurfaceVariant
            }
        }
        // The transport reports per-interface TCP connectivity.  An interface
        // is only green when it's been registered with transport AND its
        // socket is currently connected — a fake/unreachable host stays red.
        guard repository.serviceRunning else {
            return .retichatError
        }
        switch interfaceOnlineStatus[iface.name] {
        case .some(true):  return .retichatSuccess
        case .some(false): return .retichatError
        case .none:
            // Unknown to transport (config not yet applied / service starting):
            // show red so an unconnected interface never appears green.
            return .retichatError
        }
    }

    /// Poll the running Reticulum transport for the current online status of
    /// each pending interface and update `interfaceOnlineStatus`.
    private func refreshInterfaceStatus() {
        let names = vm.pendingInterfaces.map(\.name)
        guard repository.serviceRunning else {
            if !interfaceOnlineStatus.isEmpty { interfaceOnlineStatus = [:] }
            return
        }
        let bridge = RetichatBridge.shared
        var next: [String: Bool] = [:]
        for name in names {
            if let online = bridge.interfaceOnline(name: name) {
                next[name] = online
            }
        }
        if next != interfaceOnlineStatus {
            interfaceOnlineStatus = next
        }
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

    // MARK: - Interface type chooser sheet

    private var interfaceTypeChooser: some View {
        NavigationStack {
            ZStack {
                Color.retichatBackground.ignoresSafeArea()
                VStack(spacing: 12) {
                    ForEach(InterfaceKind.allCases) { kind in
                        Button {
                            beginAdd(kind: kind)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: kind.symbolName)
                                    .font(.title2)
                                    .foregroundColor(.retichatPrimary)
                                    .frame(width: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(kind.displayName)
                                        .font(.headline)
                                        .foregroundColor(.retichatOnSurface)
                                    Text(kind.helpText)
                                        .font(.caption)
                                        .foregroundColor(.retichatOnSurfaceVariant)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.retichatOnSurfaceVariant)
                            }
                            .padding(14)
                            .glassBackground(cornerRadius: 12)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Add Interface")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { showInterfaceTypeChooser = false }
                }
            }
        }
    }

    /// Pick a kind from the chooser, prefill state, and open the matching editor.
    private func beginAdd(kind: InterfaceKind) {
        addingKind = kind
        editingInterface = nil
        switch kind {
        case .tcpClient:
            newInterfaceName = ""
            newInterfaceHost = ""
            newInterfacePort = "4242"
        case .rnode:
            newInterfaceName = "RNode"
            rnodeProfile = .default
        }
        showInterfaceTypeChooser = false
        // Defer so the chooser sheet finishes dismissing before the next presents.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            showAddInterface = true
        }
    }

    // MARK: - Interface Editor Sheet (type-routed)

    @ViewBuilder
    private func interfaceEditor(existing: PendingInterface?, kind: InterfaceKind) -> some View {
        switch kind {
        case .tcpClient:
            tcpInterfaceEditor(existing: existing)
        case .rnode:
            rnodeInterfaceEditor(existing: existing)
        }
    }

    // MARK: - TCP editor

    private func tcpInterfaceEditor(existing: PendingInterface?) -> some View {
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
            .navigationTitle(existing == nil ? "Add TCP Interface" : "Edit TCP Interface")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismissEditors() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { saveTCPInterface(existing: existing) }
                        .disabled(newInterfaceHost.isEmpty || newInterfaceName.isEmpty)
                }
            }
        }
    }

    private func saveTCPInterface(existing: PendingInterface?) {
        let port = Int(newInterfacePort) ?? 4242
        if let existing = existing,
           let idx = vm.pendingInterfaces.firstIndex(where: { $0.id == existing.id }) {
            vm.pendingInterfaces[idx].type = InterfaceKind.tcpClient.rawValue
            vm.pendingInterfaces[idx].name = newInterfaceName
            vm.pendingInterfaces[idx].targetHost = newInterfaceHost
            vm.pendingInterfaces[idx].targetPort = port
            vm.pendingInterfaces[idx].configJSON = nil
        } else {
            vm.pendingInterfaces.append(PendingInterface(
                id: UUID().uuidString,
                type: InterfaceKind.tcpClient.rawValue,
                name: newInterfaceName,
                targetHost: newInterfaceHost,
                targetPort: port,
                enabled: true,
                configJSON: nil
            ))
        }
        dismissEditors()
    }

    // MARK: - RNode editor

    private func rnodeInterfaceEditor(existing: PendingInterface?) -> some View {
        NavigationStack {
            RNodeInterfaceEditorView(
                name: $newInterfaceName,
                profile: $rnodeProfile,
                isEditing: existing != nil,
                onSave: { saveRNodeInterface(existing: existing) },
                onCancel: { dismissEditors() }
            )
        }
    }

    private func saveRNodeInterface(existing: PendingInterface?) {
        let json = rnodeProfile.jsonString
        if let existing = existing,
           let idx = vm.pendingInterfaces.firstIndex(where: { $0.id == existing.id }) {
            vm.pendingInterfaces[idx].type = InterfaceKind.rnode.rawValue
            vm.pendingInterfaces[idx].name = newInterfaceName
            vm.pendingInterfaces[idx].targetHost = ""
            vm.pendingInterfaces[idx].targetPort = 0
            vm.pendingInterfaces[idx].configJSON = json
        } else {
            vm.pendingInterfaces.append(PendingInterface(
                id: UUID().uuidString,
                type: InterfaceKind.rnode.rawValue,
                name: newInterfaceName,
                targetHost: "",
                targetPort: 0,
                enabled: true,
                configJSON: json
            ))
        }
        dismissEditors()
    }

    private func dismissEditors() {
        showAddInterface = false
        showEditInterface = false
        editingInterface = nil
    }
}
