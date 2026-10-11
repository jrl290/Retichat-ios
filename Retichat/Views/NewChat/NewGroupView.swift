//
//  NewGroupView.swift
//  Retichat
//
//  Create a new group chat – enter name and select members from contacts.
//  Mirrors Android NewGroupScreen.kt.
//

import SwiftUI

struct NewGroupView: View {
    @EnvironmentObject var repository: ChatRepository
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedChatId: String?
    var onDismissParent: (() -> Void)?

    @State private var groupName = ""
    @State private var selectedMembers: Set<String> = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.retichatBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Group name input
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Group Name")
                                .font(.headline)
                                .foregroundColor(.retichatOnSurface)

                            TextField("Enter group name…", text: $groupName)
                                .foregroundColor(.retichatOnSurface)
                                .padding(12)
                                .glassBackground(cornerRadius: 12)
                        }

                        // Member selection
                        let contacts = repository.contacts()
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
                                            if selectedMembers.contains(contact.id) {
                                                selectedMembers.remove(contact.id)
                                            } else {
                                                selectedMembers.insert(contact.id)
                                            }
                                        }
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: selectedMembers.contains(contact.id)
                                                  ? "checkmark.circle.fill"
                                                  : "circle")
                                                .foregroundColor(
                                                    selectedMembers.contains(contact.id)
                                                    ? .retichatPrimary
                                                    : .retichatOnSurfaceVariant
                                                )
                                                .font(.title3)

                                            AvatarView(
                                                name: contact.displayName,
                                                size: 40
                                            )

                                            VStack(alignment: .leading) {
                                                Text(contact.displayName)
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
                                }
                            }
                        }

                        if let error = errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.retichatError)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Greyed, with no text, until a group can be created (§8.7; James, 2026-10-11).
                    Button("Create") { createGroup() }
                        .disabled(groupName.trimmingCharacters(in: .whitespaces).isEmpty
                                  || selectedMembers.isEmpty
                                  || !repository.canCreateGroup)
                }
            }
        }
    }

    private func createGroup() {
        let trimmedName = groupName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            errorMessage = "Group name is required"
            return
        }
        guard !selectedMembers.isEmpty else {
            errorMessage = "Select at least one member"
            return
        }

        // Nil only when no group can be created yet (Create is greyed then, GROUPS-DISTRO-DESIGN.md
        // §8.7): nothing was created or queued, and nothing is said.
        guard let chatId = repository.createGroupChat(name: trimmedName, memberHashes: Array(selectedMembers)) else { return }
        selectedChatId = chatId
        dismiss()
        onDismissParent?()
    }
}
