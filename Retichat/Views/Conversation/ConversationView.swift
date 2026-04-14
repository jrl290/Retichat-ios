//
//  ConversationView.swift
//  Retichat
//
//  Chat conversation screen. Mirrors Android ConversationScreen.kt.
//

import SwiftUI
import PhotosUI
import Combine
import GameController

struct ConversationView: View {
    @EnvironmentObject var repository: ChatRepository
    @StateObject private var viewModel: ConversationViewModel
    @Environment(\.dismiss) private var dismiss

    let chatId: String

    @State private var messageText = ""
    @State private var showAttachmentPicker = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var pendingAttachments: [(String, Data)] = []
    @State private var showChatInfo = false
    @State private var scrollProxy: ScrollViewProxy?
    @FocusState private var isTextFieldFocused: Bool

    private var isGroupPending: Bool {
        repository.chats.first(where: { $0.id == chatId })?.isPendingInvite ?? false
    }

    init(chatId: String) {
        self.chatId = chatId
        _viewModel = StateObject(wrappedValue: ConversationViewModel())
    }

    var body: some View {
        ZStack {
            Color.retichatBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                messagesList

                attachmentPreview

                // Input bar / invite overlay
                if viewModel.isGroup && isGroupPending {
                    inviteOverlay
                } else {
                    inputBar
                }
            }
            .blur(radius: showChatInfo ? 8 : 0)
            .animation(.easeInOut(duration: 0.25), value: showChatInfo)
        }
        .navigationTitle(viewModel.chatTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isGroupPending {
                    Menu {
                        Button("Accept Invite") {
                            repository.acceptGroupInvite(groupId: chatId)
                        }
                        Button("Decline Invite", role: .destructive) {
                            repository.declineGroupInvite(groupId: chatId)
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundColor(.retichatPrimary)
                    }
                } else {
                    Button {
                        showChatInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundColor(.retichatPrimary)
                    }
                }
            }
        }
        .photosPicker(isPresented: $showAttachmentPicker, selection: $selectedPhotos,
                       maxSelectionCount: 5, matching: .any(of: [.images, .videos]))
        .onChange(of: selectedPhotos) { _, newItems in
            Task {
                for item in newItems {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        let filename = "photo_\(Date().timeIntervalSince1970).jpg"
                        pendingAttachments.append((filename, data))
                    }
                }
                selectedPhotos = []
            }
        }
        .sheet(isPresented: $showChatInfo) {
            ChatInfoSheet(
                chatId: chatId,
                isGroup: viewModel.isGroup,
                onArchive: {
                    repository.archiveChat(chatId: chatId)
                    dismiss()
                },
                onDelete: {
                    repository.deleteChat(chatId: chatId)
                    dismiss()
                },
                onLeave: {
                    repository.leaveGroup(chatId: chatId)
                    dismiss()
                }
            )
        }
        .onAppear {
            viewModel.loadChat(chatId: chatId, repository: repository)
            NotificationManager.shared.activeChatId = chatId
            NotificationManager.shared.clearNotifications(forChatId: chatId)
            repository.openConversation(chatId: chatId)
            isTextFieldFocused = true
        }
        .onDisappear {
            NotificationManager.shared.activeChatId = nil
            repository.closeConversation(chatId: chatId)
        }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            viewModel.refreshMessages(chatId: chatId, repository: repository)
        }
    }

    // MARK: - Sub-views

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    // Load more button at top
                    if viewModel.canLoadMore {
                        Button {
                            let firstId = viewModel.messages.first?.id
                            viewModel.loadMoreMessages(chatId: chatId, repository: repository)
                            if let fid = firstId {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    proxy.scrollTo(fid, anchor: .top)
                                }
                            }
                        } label: {
                            Text("Load earlier messages")
                                .font(.caption)
                                .foregroundColor(.retichatPrimary)
                                .padding(.vertical, 8)
                        }
                    }

                    ForEach(viewModel.messages) { msg in
                        ChatBubble(message: msg, isGroup: viewModel.isGroup)
                            .id(msg.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: viewModel.messages.count) { oldCount, newCount in
                if let lastId = viewModel.messages.last?.id {
                    if oldCount == 0 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    } else if newCount > oldCount {
                        withAnimation {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                if let lastId = viewModel.messages.last?.id {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
            }
            .onAppear { scrollProxy = proxy }
        }
    }

    @ViewBuilder
    private var attachmentPreview: some View {
        if !pendingAttachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(pendingAttachments.enumerated()), id: \.offset) { i, att in
                        HStack(spacing: 4) {
                            if let img = UIImage(data: att.1) {
                                Image(uiImage: img)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 40, height: 40)
                                    .cornerRadius(6)
                            } else {
                                Image(systemName: "doc.fill")
                                    .foregroundColor(.retichatPrimary)
                            }
                            Text(att.0)
                                .font(.caption2)
                                .lineLimit(1)

                            Button {
                                pendingAttachments.remove(at: i)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundColor(.retichatOnSurfaceVariant)
                            }
                        }
                        .padding(6)
                        .glassBackground(cornerRadius: 8)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
            }
        }
    }

    private var inviteOverlay: some View {
        VStack(spacing: 0) {
            Divider()
            Text("You have been invited to this group")
                .font(.caption)
                .foregroundColor(.retichatOnSurfaceVariant)
                .padding(.top, 8)
            HStack(spacing: 16) {
                Button {
                    repository.declineGroupInvite(groupId: chatId)
                    dismiss()
                } label: {
                    Text("Decline")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.retichatSurface)
                        .cornerRadius(10)
                        .foregroundColor(.retichatOnSurface)
                }
                Button {
                    repository.acceptGroupInvite(groupId: chatId)
                } label: {
                    Text("Accept")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.retichatPrimary)
                        .cornerRadius(10)
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.retichatSurface)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Button {
                showAttachmentPicker = true
            } label: {
                Image(systemName: "paperclip")
                    .font(.title3)
                    .foregroundColor(.retichatPrimary)
            }

            TextField("Message…", text: $messageText, axis: .vertical)
                .focused($isTextFieldFocused)
                .foregroundColor(.retichatOnSurface)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassBackground(cornerRadius: 20)
                #if targetEnvironment(macCatalyst)
                .onChange(of: messageText) { _, newValue in
                    guard newValue.hasSuffix("\n") else { return }
                    let shiftHeld: Bool = {
                        guard let kb = GCKeyboard.coalesced?.keyboardInput else { return false }
                        return kb.button(forKeyCode: .leftShift)?.isPressed == true
                            || kb.button(forKeyCode: .rightShift)?.isPressed == true
                    }()
                    if !shiftHeld {
                        messageText = String(newValue.dropLast())
                        sendMessage()
                    }
                }
                #endif

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundColor(
                        (messageText.isEmpty && pendingAttachments.isEmpty)
                        ? .retichatOnSurfaceVariant
                        : .retichatPrimary
                    )
            }
            .disabled(messageText.isEmpty && pendingAttachments.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.retichatSurface)
    }

    private func sendMessage() {
        let content = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        let atts = pendingAttachments
        guard !content.isEmpty || !atts.isEmpty else { return }

        messageText = ""
        pendingAttachments = []

        repository.sendMessage(chatId: chatId, content: content, attachments: atts)
        viewModel.refreshMessages(chatId: chatId, repository: repository)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let lastId = viewModel.messages.last?.id {
                withAnimation {
                    scrollProxy?.scrollTo(lastId, anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - Chat info / settings sheet

struct ChatInfoSheet: View {
    @EnvironmentObject var repository: ChatRepository
    @Environment(\.dismiss) private var dismiss

    let chatId: String
    let isGroup: Bool
    let onArchive: () -> Void
    let onDelete: () -> Void
    let onLeave: () -> Void

    @State private var renameText: String = ""
    @State private var notificationsEnabled: Bool = true
    @State private var showDeleteConfirm = false
    @State private var showLeaveConfirm = false

    private var chat: Chat? { repository.chats.first(where: { $0.id == chatId }) }
    private var title: String { chat?.displayName ?? chatId }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.retichatBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        // Avatar + name header
                        VStack(spacing: 8) {
                            AvatarView(name: title, size: 64)
                            Text(title)
                                .font(.title3).fontWeight(.semibold)
                                .foregroundColor(.retichatOnSurface)
                            if !isGroup {
                                Text(chat?.peerHash ?? "")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.retichatOnSurfaceVariant)
                                    .textSelection(.enabled)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .padding(.top, 8)

                        // Rename
                        GlassCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(isGroup ? "Group Name" : "Contact Name")
                                    .font(.headline)
                                    .foregroundColor(.retichatOnSurface)
                                HStack {
                                    TextField("Name", text: $renameText)
                                        .foregroundColor(.retichatOnSurface)
                                        .padding(10)
                                        .glassBackground(cornerRadius: 8)
                                    Button("Save") {
                                        applyRename()
                                    }
                                    .disabled(renameText.isEmpty || renameText == title)
                                    .tint(.retichatPrimary)
                                }
                            }
                        }

                        // Notifications
                        GlassCard {
                            Toggle(isOn: $notificationsEnabled) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Notifications")
                                        .foregroundColor(.retichatOnSurface)
                                    Text(notificationsEnabled ? "You'll be notified of new messages" : "Notifications are silenced")
                                        .font(.caption)
                                        .foregroundColor(.retichatOnSurfaceVariant)
                                }
                            }
                            .tint(.retichatPrimary)
                            .onChange(of: notificationsEnabled) { _, enabled in
                                if enabled {
                                    UserPreferences.shared.unmuteChat(chatId)
                                } else {
                                    UserPreferences.shared.muteChat(chatId)
                                }
                            }
                        }

                        // Group members (group only)
                        if isGroup, let members = repository.groupMembersWithStatus(groupId: chatId) {
                            GlassCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Members")
                                        .font(.headline)
                                        .foregroundColor(.retichatOnSurface)
                                    ForEach(members, id: \.memberHash) { member in
                                        HStack {
                                            AvatarView(
                                                name: repository.contactDisplayName(for: member.memberHash),
                                                size: 36
                                            )
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(repository.contactDisplayName(for: member.memberHash))
                                                    .foregroundColor(.retichatOnSurface)
                                                Text(member.memberHash)
                                                    .font(.caption2)
                                                    .foregroundColor(.retichatOnSurfaceVariant)
                                                    .lineLimit(1)
                                            }
                                            Spacer()
                                            Text(memberStatusLabel(member.inviteStatus))
                                                .font(.caption2)
                                                .foregroundColor(memberStatusColor(member.inviteStatus))
                                        }
                                        .padding(.vertical, 4)
                                    }
                                }
                            }
                        }

                        // Archive / Delete / Leave
                        GlassCard {
                            VStack(spacing: 0) {
                                if isGroup {
                                    Button {
                                        showLeaveConfirm = true
                                    } label: {
                                        Label("Leave Group", systemImage: "rectangle.portrait.and.arrow.right")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .foregroundColor(.retichatError)
                                    }
                                } else {
                                    Button {
                                        dismiss()
                                        onArchive()
                                    } label: {
                                        Label("Archive", systemImage: "archivebox")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .foregroundColor(.retichatOnSurface)
                                    }

                                    Divider().background(Color.glassBorder).padding(.vertical, 8)

                                    Button {
                                        showDeleteConfirm = true
                                    } label: {
                                        Label("Delete Conversation", systemImage: "trash")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .foregroundColor(.retichatError)
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle(isGroup ? "Group Info" : "Chat Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Delete this conversation?", isPresented: $showDeleteConfirm,
                                 titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    dismiss()
                    onDelete()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All messages will be permanently deleted. This cannot be undone.")
            }
            .confirmationDialog("Leave this group?", isPresented: $showLeaveConfirm,
                                 titleVisibility: .visible) {
                Button("Leave Group", role: .destructive) {
                    dismiss()
                    onLeave()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You will stop receiving messages from this group.")
            }
            .onAppear {
                renameText = title
                notificationsEnabled = !UserPreferences.shared.isChatMuted(chatId)
            }
        }
    }

    private func applyRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isGroup {
            repository.renameGroup(chatId: chatId, newName: trimmed)
        } else {
            repository.renameContact(destHash: chat?.peerHash ?? chatId, newName: trimmed)
        }
    }

    private func memberStatusLabel(_ status: String) -> String {
        switch status {
        case MemberStatus.accepted: return "Accepted"
        case MemberStatus.invited:  return "Invited"
        case MemberStatus.left:     return "Left"
        case MemberStatus.declined: return "Declined"
        default:                    return status
        }
    }

    private func memberStatusColor(_ status: String) -> Color {
        switch status {
        case MemberStatus.accepted: return .retichatSuccess
        case MemberStatus.invited:  return .orange
        case MemberStatus.left, MemberStatus.declined: return .retichatOnSurfaceVariant
        default: return .retichatOnSurfaceVariant
        }
    }
}
