//
//  ConversationViewModel.swift
//  Retichat
//
//  State management for the conversation screen.
//

import Foundation
import Combine

@MainActor
final class ConversationViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var chatTitle: String = ""
    @Published var peerHash: String = ""
    @Published var isGroup: Bool = false
    @Published var canLoadMore: Bool = true

    private let pageSize = 50
    private var currentOffset = 0
    private var isLoadingMore = false

    func loadChat(chatId: String, repository: ChatRepository) {
        if let chat = repository.chats.first(where: { $0.id == chatId }) {
            chatTitle = chat.displayName
            peerHash = chat.peerHash
            isGroup = chat.isGroup
        } else {
            chatTitle = repository.contactDisplayName(for: chatId)
            peerHash = chatId
        }
        // Load initial page (most recent messages)
        currentOffset = 0
        let page = repository.messages(forChatId: chatId, limit: pageSize, offset: 0)
        messages = page
        canLoadMore = page.count >= pageSize
    }

    func refreshMessages(chatId: String, repository: ChatRepository) {
        // Lightweight check: only re-query if the message count or latest
        // delivery states may have changed.  This avoids the heavy attachment
        // fetch + SwiftUI diff every tick when nothing is happening.
        let page = repository.messagesSummary(forChatId: chatId, limit: pageSize + currentOffset)
        let changed = page.count != messages.count
            || zip(page, messages).contains(where: { $0.0 != $1.id || $0.1 != $1.deliveryState })
        guard changed else { return }

        let full = repository.messages(forChatId: chatId, limit: pageSize + currentOffset, offset: 0)
        messages = full
    }

    func loadMoreMessages(chatId: String, repository: ChatRepository) {
        guard canLoadMore, !isLoadingMore else { return }
        isLoadingMore = true
        currentOffset += pageSize
        let olderPage = repository.messages(forChatId: chatId, limit: pageSize, offset: currentOffset)
        if olderPage.isEmpty {
            canLoadMore = false
        } else {
            // Prepend older messages
            messages = olderPage + messages
            if olderPage.count < pageSize {
                canLoadMore = false
            }
        }
        isLoadingMore = false
    }
}
