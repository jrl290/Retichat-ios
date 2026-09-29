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
    /// repository.namesVersion when the bubbles were last built: names are
    /// resolved into them, so a name change rebuilds them.
    private var namesVersion = -1

    func loadChat(chatId: String, repository: ChatRepository) {
        namesVersion = repository.namesVersion
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
        refreshUploadProgress(repository: repository)
    }

    /// `namesVersion`: the version a `repository.$namesVersion` subscriber
    /// was sent, which the repository does not hold yet (@Published sends
    /// in willSet). nil reads the repository's (the 3 s timer).
    func refreshMessages(chatId: String, repository: ChatRepository, namesVersion sent: Int? = nil) {
        // Lightweight check: only re-query if the message count or latest
        // delivery states may have changed.  This avoids the heavy attachment
        // fetch + SwiftUI diff every tick when nothing is happening.
        let page = repository.messagesSummary(forChatId: chatId, limit: pageSize + currentOffset)
        let currentNames = sent ?? repository.namesVersion
        let namesChanged = currentNames != namesVersion
        let changed = namesChanged || page.count != messages.count
            || zip(page, messages).contains(where: { $0.0 != $1.id || $0.1 != $1.deliveryState })
        if changed {
            if namesChanged {
                namesVersion = currentNames
                if !isGroup { chatTitle = repository.contactDisplayName(for: chatId) }
            }

            var full = repository.messages(forChatId: chatId, limit: pageSize + currentOffset, offset: 0)
            let kept = UploadProgress.carried(from: messages.map { (id: $0.id, bar: $0.uploadProgress) },
                                              to: full.map(\.id))
            for index in full.indices {
                full[index].uploadProgress = kept[index]
            }
            messages = full
        }
        // Every tick, whether or not anything structural changed: a bar
        // moves with its transfer. Until 2026-09-29 the tick returned here
        // when nothing had, so a bar never moved between reloads.
        refreshUploadProgress(repository: repository)
    }

    /// A reading of the bars is on ffiQueue. Ticks while it is out start
    /// none, so readings never pile up behind a busy ffiQueue.
    private var readingUploadBars = false

    /// Read the live rows' bars off the main actor (ChatRepository.uploadBars
    /// on ffiQueue, §6) and assign those that changed (UploadProgress.changes).
    /// With no row live, clear any bar left at once.
    private func refreshUploadProgress(repository: ChatRepository) {
        let live = repository.liveUploads(in: messages)
        guard !live.isEmpty else {
            applyUploadBars([:], repository: repository)
            return
        }
        guard !readingUploadBars else { return }
        readingUploadBars = true
        Task { [weak self] in
            let read = await repository.uploadBars(for: live)
            guard let self else { return }
            self.readingUploadBars = false
            self.applyUploadBars(read, repository: repository)
        }
    }

    /// Assign each bar that changed, and only those: a row no longer live
    /// (its message completed while the reading was out) loses its bar.
    private func applyUploadBars(_ read: [String: Float?], repository: ChatRepository) {
        let live = Set(repository.liveUploads(in: messages).map(\.id))
        let rows = messages.map { (id: $0.id, bar: $0.uploadProgress) }
        for change in UploadProgress.changes(rows: rows, live: live, read: read) {
            messages[change.index].uploadProgress = change.bar
        }
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
