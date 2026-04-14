//
//  NewChatView.swift
//  Retichat
//
//  New chat screen: enter destination hash, scan QR, or pick from contacts.
//  Mirrors Android NewChatScreen.kt.
//

import SwiftUI

struct NewChatView: View {
    @EnvironmentObject var repository: ChatRepository
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedChatId: String?

    @State private var destHash = ""
    @State private var showScanner = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.retichatBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Destination hash input
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Destination Hash")
                                .font(.headline)
                                .foregroundColor(.retichatOnSurface)

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
                                    Button {
                                        destHash = ""
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.retichatOnSurfaceVariant)
                                    }
                                }
                            }
                            .padding(12)
                            .glassBackground(cornerRadius: 12)

                            if let error = errorMessage {
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.retichatError)
                            }
                        }

                        // Action buttons
                        HStack(spacing: 12) {
                            Button {
                                startChat()
                            } label: {
                                Label("Start Chat", systemImage: "paperplane.fill")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.retichatPrimary)
                            .disabled(destHash.count != 32)

                            Button {
                                showScanner = true
                            } label: {
                                Label("Scan QR", systemImage: "qrcode.viewfinder")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            }
                            .buttonStyle(.bordered)
                            .tint(.retichatPrimary)
                        }

                        Divider()
                            .background(Color.glassBorder)

        // Existing contacts
                        let contacts = repository.contacts()
                        if !contacts.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Contacts")
                                    .font(.headline)
                                    .foregroundColor(.retichatOnSurface)

                                ForEach(contacts) { contact in
                                    ContactRow(contact: contact) {
                                        destHash = contact.id
                                        startChat()
                                    } onRemove: {
                                        repository.removeContact(destHash: contact.id)
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showScanner) {
                QRCodeView(mode: .scan) { scannedHash in
                    destHash = scannedHash
                    showScanner = false
                    startChat()
                }
            }
        }
    }

    private func startChat() {
        let hash = destHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard hash.count == 32 else {
            errorMessage = "Hash must be exactly 32 hex characters"
            return
        }
        guard hash == hash.filter({ "0123456789abcdef".contains($0) }) else {
            errorMessage = "Invalid hex characters"
            return
        }

        if hash == repository.ownHashHex {
            errorMessage = "Cannot chat with yourself"
            return
        }

        let chatId = repository.createDirectChat(destHash: hash)
        selectedChatId = chatId
        dismiss()
    }
}

// MARK: - Contact row with swipe-to-remove

private struct ContactRow: View {
    let contact: Contact
    let onTap: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                AvatarView(
                    name: contact.displayName.isEmpty ? contact.id : contact.displayName,
                    size: 40
                )
                VStack(alignment: .leading) {
                    Text(contact.displayName.isEmpty
                         ? String(contact.id.prefix(16)) + "…"
                         : contact.displayName)
                        .foregroundColor(.retichatOnSurface)
                    Text(contact.id)
                        .font(.caption2)
                        .foregroundColor(.retichatOnSurfaceVariant)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(8)
            .glassBackground(cornerRadius: 10)
        }
        .contextMenu {
            Button("Remove Contact", role: .destructive, action: onRemove)
        }
        .swipeActions(edge: .trailing) {
            Button("Remove", role: .destructive, action: onRemove)
        }
    }
}
