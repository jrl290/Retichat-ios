//
//  ChatListView.swift
//  Retichat
//
//  Main screen showing all chats. Mirrors Android ChatListScreen.kt.
//

import SwiftUI

// MARK: - Unified list entry

private enum ListEntry: Identifiable {
    case chat(Chat)
    case channel(Channel)

    var id: String {
        switch self {
        case .chat(let c): return "c_\(c.id)"
        case .channel(let ch): return "ch_\(ch.id)"
        }
    }

    /// Sort key for the unified chat list.  DM/group chats sort by their
    /// real `lastMessageTime`.  Channels sort by the user's own "last
    /// opened" timestamp so incoming channel traffic does not keep
    /// bouncing them to the top of the list — they only bubble up when
    /// the user actively opens them.  Channels that have never been
    /// opened on this device fall back to `lastMessageTime` so they
    /// still take a sensible time-based slot interleaved with chats
    /// instead of clumping at the bottom at timestamp 0.
    ///
    /// All timestamps are seconds (Apple epoch) so chats and channels
    /// sort directly against each other.
    var sortTime: Double {
        switch self {
        case .chat(let c):
            return c.lastMessageTime
        case .channel(let ch):
            let opened = UserPreferences.shared.channelLastOpenedTime(ch.id)
            return opened > 0 ? opened : ch.lastMessageTime
        }
    }
}

struct ChatListView: View {
    @EnvironmentObject var repository: ChatRepository
    @EnvironmentObject var channelClient: RfedChannelClient
    @Binding var selectedChatId: String?
    @Binding var selectedChannel: Channel?
    @Binding var showNewConversation: Bool
    @Binding var showSettings: Bool
    @Binding var showQRCode: Bool

    @State private var searchText = ""

    private var entries: [ListEntry] {
        let chatEntries: [ListEntry] = (searchText.isEmpty
            ? repository.chats
            : repository.searchAllChats(query: searchText)
        ).map { .chat($0) }

        let channelEntries: [ListEntry] = channelClient.channels
            .filter { searchText.isEmpty || $0.channelName.localizedCaseInsensitiveContains(searchText) }
            .map { .channel($0) }

        return (chatEntries + channelEntries)
            .sorted { $0.sortTime > $1.sortTime }
    }

    /// True when the given list entry corresponds to the conversation
    /// currently displayed in the detail pane (DM/group chat or channel).
    /// Used to render a light tint on the selected row.
    private func isSelected(_ entry: ListEntry) -> Bool {
        switch entry {
        case .chat(let c):     return selectedChatId == c.id
        case .channel(let ch): return selectedChannel?.id == ch.id
        }
    }

    var body: some View {
        ZStack {
            Color.retichatBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Search bar with QR and Settings icons
                HStack(spacing: 10) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.retichatOnSurfaceVariant)
                        TextField("Search chats…", text: $searchText)
                            .foregroundColor(.retichatOnSurface)
                            .autocorrectionDisabled()
                    }
                    .padding(12)
                    .glassBackground(cornerRadius: 12)

                    Button { showQRCode = true } label: {
                        Image(systemName: "qrcode")
                            .font(.system(size: 20))
                            .foregroundColor(.retichatPrimary)
                    }

                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 20))
                            .foregroundColor(.retichatPrimary)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 8)

                // Chat list
                if entries.isEmpty {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 48))
                            .foregroundColor(.retichatOnSurfaceVariant)
                        Text("No conversations yet")
                            .font(.headline)
                            .foregroundColor(.retichatOnSurfaceVariant)
                        Text("Start a new chat using the + button")
                            .font(.subheadline)
                            .foregroundColor(.retichatOnSurfaceVariant.opacity(0.7))

                        if searchText.isEmpty && UserPreferences.shared.filterStrangers {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "person.crop.circle.badge.exclamationmark")
                                    .font(.body)
                                    .foregroundColor(.orange)
                                Text("Privacy filter is on — only messages from contacts you've added will appear. Add contacts via the + button or disable the filter in Settings.")
                                    .font(.caption)
                                    .foregroundColor(.retichatOnSurfaceVariant)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(12)
                            .glassBackground(cornerRadius: 12)
                            .padding(.horizontal, 32)
                        }
                    }
                    Spacer()
                } else {
                    List(entries) { entry in
                        Group {
                            switch entry {
                            case .chat(let chat):
                                ChatRow(chat: chat, isSelected: isSelected(entry))
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedChannel = nil
                                        selectedChatId = chat.id
                                    }
                                    .swipeActions(edge: .trailing) {
                                        if chat.isPendingInvite {
                                            Button(role: .destructive) {
                                                repository.declineGroupInvite(groupId: chat.id)
                                            } label: {
                                                Label("Decline", systemImage: "xmark")
                                            }
                                            Button {
                                                repository.acceptGroupInvite(groupId: chat.id)
                                            } label: {
                                                Label("Accept", systemImage: "checkmark")
                                            }
                                            .tint(.green)
                                        } else {
                                            Button(role: .destructive) {
                                                repository.archiveChat(chatId: chat.id)
                                            } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                        }
                                    }
                            case .channel(let channel):
                                ChannelRow(channel: channel, isSelected: isSelected(entry))
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedChatId = nil
                                        selectedChannel = channel
                                        UserPreferences.shared.markChannelOpened(channel.id)
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            if selectedChannel?.id == channel.id {
                                                selectedChannel = nil
                                            }
                                            Task { await channelClient.leaveChannel(channelHashHex: channel.id) }
                                        } label: {
                                            Label("Leave", systemImage: "arrow.right.square")
                                        }
                                    }
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }

            // Floating new chat button – bottom right
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button { showNewConversation = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 56, height: 56)
                            .background(Circle().fill(Color.retichatPrimary))
                            .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 20)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            repository.refreshChats()
        }
    }
}

// MARK: - Chat row

struct ChatRow: View {
    let chat: Chat
    var isSelected: Bool = false
    @Environment(\.isWideLayout) private var isWideLayout

    private var outerHorizontalPadding: CGFloat {
        isWideLayout ? 16 : 12
    }

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: chat.displayName)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if chat.isGroup {
                        Image(systemName: "person.3.fill")
                            .font(.caption)
                            .foregroundColor(.retichatPrimary)
                    } else {
                        Image(systemName: "person.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    Text(chat.displayName)
                        .font(.headline)
                        .foregroundColor(.retichatOnSurface)
                        .lineLimit(1)

                    Spacer()

                    Text(formatRelativeTime(chat.lastMessageTime))
                        .font(.caption)
                        .foregroundColor(.retichatOnSurfaceVariant)
                }

                HStack {
                    Text(chat.lastMessage)
                        .font(.subheadline)
                        .foregroundColor(.retichatOnSurfaceVariant)
                        .lineLimit(2)

                    Spacer()

                    if chat.isPendingInvite {
                        Text("Invited")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange))
                    } else if chat.isArchived {
                        Text("Archived")
                            .font(.caption2)
                            .foregroundColor(.retichatOnSurfaceVariant)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.retichatOnSurfaceVariant.opacity(0.15)))
                    } else if chat.unreadCount > 0 {
                        Text("\(chat.unreadCount)")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.retichatPrimary))
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.retichatPrimary.opacity(isSelected ? 0.15 : 0))
        )
        .glassBackground(cornerRadius: 12)
        .padding(.horizontal, outerHorizontalPadding)
        .padding(.bottom, 6)
    }

    private func formatRelativeTime(_ timestamp: Double) -> String {
        guard timestamp > 0 else { return "" }
        let date = Date(timeIntervalSince1970: timestamp)
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        }
    }
}

// MARK: - Channel row

struct ChannelRow: View {
    let channel: Channel
    var isSelected: Bool = false
    @Environment(\.isWideLayout) private var isWideLayout

    private var outerHorizontalPadding: CGFloat { isWideLayout ? 16 : 12 }

    /// Visible display name: strip the first dot-notation segment.
    /// "public.general" → "general", "a3f92b1c.team.news" → "team.news"
    private var displayName: String {
        let parts = channel.channelName.split(separator: ".", maxSplits: 1)
        return parts.count > 1 ? String(parts[1]) : channel.channelName
    }

    private var isPublic: Bool { channel.channelName.hasPrefix("public.") }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.retichatPrimary.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: isPublic ? "number" : "lock.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.retichatPrimary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: isPublic ? "globe" : "lock")
                        .font(.caption)
                        .foregroundColor(isPublic ? .green : .orange)
                    Text(displayName)
                        .font(.headline)
                        .foregroundColor(.retichatOnSurface)
                        .lineLimit(1)
                    Spacer()
                    if channel.lastMessageTime > 0 {
                        Text(formatRelativeTime(channel.lastMessageTime))
                            .font(.caption)
                            .foregroundColor(.retichatOnSurfaceVariant)
                    }
                }
                Text(channel.channelName)
                    .font(.caption)
                    .foregroundColor(.retichatOnSurfaceVariant)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.retichatPrimary.opacity(isSelected ? 0.15 : 0))
        )
        .glassBackground(cornerRadius: 12)
        .padding(.horizontal, outerHorizontalPadding)
        .padding(.bottom, 6)
    }

    private func formatRelativeTime(_ timestamp: Double) -> String {
        guard timestamp > 0 else { return "" }
        let date = Date(timeIntervalSince1970: timestamp)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter(); formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        }
    }
}
