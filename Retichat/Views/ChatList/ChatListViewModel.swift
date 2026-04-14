//
//  ChatListViewModel.swift
//  Retichat
//
//  Thin wrapper for ChatListView state.
//

import Foundation
import Combine

@MainActor
final class ChatListViewModel: ObservableObject {
    @Published var searchQuery = ""

    private let repository: ChatRepository

    init(repository: ChatRepository) {
        self.repository = repository
    }

    func refresh() {
        repository.refreshChats()
    }

    func archiveChat(chatId: String) {
        repository.archiveChat(chatId: chatId)
    }
}
