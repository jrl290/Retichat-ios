//
//  ChatListView.swift
//  Retichat
//
//  Main screen showing all chats. Mirrors Android ChatListScreen.kt.
//

import SwiftUI

struct ChatListView: View {
    @EnvironmentObject var repository: ChatRepository
    @Binding var selectedChatId: String?
    @Binding var showNewChat: Bool
    @Binding var showSettings: Bool
    @Binding var showQRCode: Bool

    @State private var searchText = ""

    private var filteredChats: [Chat] {
        if searchText.isEmpty {
            return repository.chats
        }
        return repository.searchAllChats(query: searchText)
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

                // Chat list
                if filteredChats.isEmpty {
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
                    List(filteredChats) { chat in
                        ChatRow(chat: chat)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .contentShape(Rectangle())
                            .onTapGesture {
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
                    Button { showNewChat = true } label: {
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

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: chat.displayName)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if chat.isGroup {
                        Image(systemName: "person.3.fill")
                            .font(.caption)
                            .foregroundColor(.retichatPrimary)
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
        .glassBackground(cornerRadius: 12)
        .padding(.horizontal, 8)
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
