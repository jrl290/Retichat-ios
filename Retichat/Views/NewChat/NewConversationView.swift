//
//  NewConversationView.swift
//  Retichat
//
//  Unified "Add" sheet – create a DM, Group, or Channel from one place.
//

import SwiftUI
import CryptoKit

// MARK: - Conversation type

enum NewConvType: String, CaseIterable {
    case direct  = "Direct"
    case group   = "Group"
    case channel = "Channel"
}

// MARK: - NewConversationView

struct NewConversationView: View {
    @EnvironmentObject var repository: ChatRepository
    @EnvironmentObject var channelClient: RfedChannelClient
    @Environment(\.dismiss) private var dismiss

    @Binding var selectedChatId: String?
    @Binding var selectedChannel: Channel?

    @State private var convType: NewConvType = .direct
    @State private var triggerStart = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.retichatBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    Picker("Conversation type", selection: $convType) {
                        ForEach(NewConvType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                    switch convType {
                    case .direct:
                        DirectMessageForm(selectedChatId: $selectedChatId, triggerStart: $triggerStart)
                    case .group:
                        GroupForm(selectedChatId: $selectedChatId, triggerStart: $triggerStart)
                    case .channel:
                        NewChannelForm(selectedChannel: $selectedChannel, triggerStart: $triggerStart)
                    }
                }
            }
            .navigationTitle("New Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Start") { triggerStart = true }
                        .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Direct message form

private struct DirectMessageForm: View {
    @EnvironmentObject var repository: ChatRepository
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedChatId: String?
    @Binding var triggerStart: Bool

    @State private var destHash = ""
    @State private var showScanner = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Fixed header
            VStack(alignment: .leading, spacing: 8) {
                Text("Destination Hash")
                    .font(.headline)
                    .foregroundColor(.retichatOnSurface)

                HStack(spacing: 10) {
                    HStack {
                        TextField("32-character hex hash…", text: $destHash)
                            .foregroundColor(.retichatOnSurface)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(.body, design: .monospaced))
                            .onChange(of: destHash) { _, newValue in
                                destHash = String(
                                    newValue.lowercased()
                                        .filter { "0123456789abcdef".contains($0) }
                                        .prefix(32)
                                )
                            }

                        if !destHash.isEmpty {
                            Button { destHash = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.retichatOnSurfaceVariant)
                            }
                        }
                    }
                    .padding(12)
                    .glassBackground(cornerRadius: 12)

                    Button { showScanner = true } label: {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 20))
                            .foregroundColor(.retichatPrimary)
                    }
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.retichatError)
                }
            }
            .padding([.horizontal, .top])
            .padding(.bottom, 8)

            Divider().background(Color.glassBorder)

            // Scrollable contacts
            let contacts = repository.contacts()
            if contacts.isEmpty {
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Contacts")
                            .font(.headline)
                            .foregroundColor(.retichatOnSurface)

                        ForEach(contacts) { contact in
                            DirectContactRow(contact: contact) {
                                destHash = contact.id
                                startChat()
                            } onRemove: {
                                repository.removeContact(destHash: contact.id)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .onChange(of: triggerStart) { _, fired in
            guard fired else { return }
            triggerStart = false
            startChat()
        }
        .sheet(isPresented: $showScanner) {
            QRCodeView(mode: .scan) { scannedHash in
                destHash = scannedHash
                showScanner = false
                startChat()
            }
        }
    }

    private func startChat() {
        let hash = destHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard hash.count == 32 else { errorMessage = "Hash must be exactly 32 hex characters"; return }
        guard hash == hash.filter({ "0123456789abcdef".contains($0) }) else { errorMessage = "Invalid hex characters"; return }
        if hash == repository.ownHashHex { errorMessage = "Cannot chat with yourself"; return }
        let chatId = repository.createDirectChat(destHash: hash)
        selectedChatId = chatId
        dismiss()
    }
}

private struct DirectContactRow: View {
    let contact: Contact
    let onTap: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                AvatarView(name: contact.displayName.isEmpty ? contact.id : contact.displayName, size: 40)
                VStack(alignment: .leading) {
                    Text(contact.displayName.isEmpty ? String(contact.id.prefix(16)) + "…" : contact.displayName)
                        .foregroundColor(.retichatOnSurface)
                    Text(contact.id).font(.caption2).foregroundColor(.retichatOnSurfaceVariant).lineLimit(1)
                }
                Spacer()
            }
            .padding(8)
            .glassBackground(cornerRadius: 10)
        }
        .contextMenu { Button("Remove Contact", role: .destructive, action: onRemove) }
        .swipeActions(edge: .trailing) { Button("Remove", role: .destructive, action: onRemove) }
    }
}

// MARK: - Group form

private struct GroupForm: View {
    @EnvironmentObject var repository: ChatRepository
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedChatId: String?
    @Binding var triggerStart: Bool

    @State private var groupName = ""
    @State private var selectedMembers: Set<String> = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Fixed header
            VStack(alignment: .leading, spacing: 8) {
                Text("Group Name")
                    .font(.headline)
                    .foregroundColor(.retichatOnSurface)
                TextField("Enter group name…", text: $groupName)
                    .foregroundColor(.retichatOnSurface)
                    .padding(12)
                    .glassBackground(cornerRadius: 12)

                if let error = errorMessage {
                    Text(error).font(.caption).foregroundColor(.retichatError)
                }
            }
            .padding([.horizontal, .top])
            .padding(.bottom, 8)

            Divider().background(Color.glassBorder)

            // Scrollable member list
            let contacts = repository.contacts()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select Members (\(selectedMembers.count))")
                        .font(.headline)
                        .foregroundColor(.retichatOnSurface)

                    if contacts.isEmpty {
                        Text("No contacts yet. Start a direct chat first.")
                            .font(.subheadline)
                            .foregroundColor(.retichatOnSurfaceVariant)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(contacts) { contact in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    if selectedMembers.contains(contact.id) { selectedMembers.remove(contact.id) }
                                    else { selectedMembers.insert(contact.id) }
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selectedMembers.contains(contact.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(selectedMembers.contains(contact.id) ? .retichatPrimary : .retichatOnSurfaceVariant)
                                        .font(.title3)
                                    AvatarView(name: contact.displayName.isEmpty ? contact.id : contact.displayName, size: 40)
                                    VStack(alignment: .leading) {
                                        Text(contact.displayName.isEmpty ? String(contact.id.prefix(16)) + "…" : contact.displayName)
                                            .foregroundColor(.retichatOnSurface)
                                        Text(contact.id).font(.caption2).foregroundColor(.retichatOnSurfaceVariant).lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(8)
                                .glassBackground(cornerRadius: 10)
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .onChange(of: triggerStart) { _, fired in
            guard fired else { return }
            triggerStart = false
            createGroup()
        }
    }

    private func createGroup() {
        let trimmed = groupName.trimmingCharacters(in: .whitespaces)
        let name: String
        if trimmed.isEmpty {
            let names = selectedMembers.map { hash -> String in
                let full = repository.contactDisplayName(for: hash)
                let first = String(full.split(separator: " ").first ?? full.prefix(8)[...])
                return first.isEmpty ? String(hash.prefix(6)) : first
            }
            name = names.sorted().prefix(3).joined(separator: ", ")
        } else {
            name = trimmed
        }
        guard !selectedMembers.isEmpty else { errorMessage = "Select at least one member"; return }
        let chatId = repository.createGroupChat(name: name, memberHashes: Array(selectedMembers))
        selectedChatId = chatId
        dismiss()
    }
}

// MARK: - New channel form

private struct NewChannelForm: View {
    @EnvironmentObject var channelClient: RfedChannelClient
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedChannel: Channel?
    @Binding var triggerStart: Bool

    enum Privacy: String, CaseIterable { case `public` = "Public"; case `private` = "Private" }

    @State private var privacy: Privacy = .public
    @State private var subdomain = ""
    @State private var privatePrefix: String = NewChannelForm.randomHex()
    @State private var isJoining = false
    @State private var errorMessage: String?

    private var fullChannelName: String {
        let sub = subdomain.trimmingCharacters(in: .whitespaces)
        guard !sub.isEmpty else { return "" }
        let prefix = privacy == .public ? "public" : privatePrefix
        return "\(prefix).\(sub)"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {

                // Privacy picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("Visibility")
                        .font(.headline)
                        .foregroundColor(.retichatOnSurface)
                    Picker("Visibility", selection: $privacy) {
                        ForEach(Privacy.allCases, id: \.self) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(privacy == .public
                         ? "Anyone who knows the name can join."
                         : "Only people you share the name with can join.")
                        .font(.caption)
                        .foregroundColor(.retichatOnSurfaceVariant)
                }

                // Subdomain field
                VStack(alignment: .leading, spacing: 8) {
                    Text("Channel name")
                        .font(.headline)
                        .foregroundColor(.retichatOnSurface)
                    HStack(spacing: 0) {
                        let prefixLabel = privacy == .public ? "public." : "\(privatePrefix)."
                        Text(prefixLabel)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.retichatOnSurfaceVariant)
                            .padding(.leading, 12)
                        TextField("general", text: $subdomain)
                            .foregroundColor(.retichatOnSurface)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(.body, design: .monospaced))
                            .onChange(of: subdomain) { _, val in
                                // Allow letters, digits, dots, hyphens
                                subdomain = val.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
                            }
                            .padding(12)
                    }
                    .glassBackground(cornerRadius: 12)

                    if !fullChannelName.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "number")
                                .font(.caption)
                                .foregroundColor(.retichatPrimary)
                            Text(fullChannelName)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.retichatPrimary)
                        }
                    }
                }

                // Private channel hint
                if privacy == .private {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Private channel prefix: \(privatePrefix)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.retichatOnSurface)
                            let exampleName = fullChannelName.isEmpty ? "\(privatePrefix).yourname" : fullChannelName
                            Text("Share the full name \"\(exampleName)\" with others so they can join.")
                                .font(.caption)
                                .foregroundColor(.retichatOnSurfaceVariant)
                            Button("Regenerate prefix") { privatePrefix = NewChannelForm.randomHex() }
                                .font(.caption)
                                .foregroundColor(.retichatPrimary)
                        }
                    }
                    .padding(12)
                    .glassBackground(cornerRadius: 12)
                }

                if let error = errorMessage {
                    Text(error).font(.caption).foregroundColor(.retichatError)
                }

                if isJoining {
                    ProgressView("Joining channel…")
                        .tint(.retichatPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
            .padding()
        }
        .onChange(of: triggerStart) { _, fired in
            guard fired else { return }
            triggerStart = false
            joinChannel()
        }
    }

    private func joinChannel() {
        let name = fullChannelName
        guard !name.isEmpty else { return }
        let nodeHash = UserPreferences.shared.effectiveRfedNodeIdentityHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard nodeHash.count >= 32 else { errorMessage = "RFed node hash not configured. Please set it in Settings."; return }
        isJoining = true
        errorMessage = nil
        Task {
            do {
                let channel = try await channelClient.joinChannel(name: name, rfedNodeIdentityHashHex: nodeHash)
                await MainActor.run {
                    selectedChannel = channel
                    isJoining = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isJoining = false
                }
            }
        }
    }

    private static func randomHex() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
