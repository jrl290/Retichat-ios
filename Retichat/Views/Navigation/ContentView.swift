//
//  ContentView.swift
//  Retichat
//
//  Main navigation container. Mirrors Android NavGraph.kt.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @EnvironmentObject var repository: ChatRepository
    @State private var selectedChatId: String?
    @State private var showNewChat = false
    @State private var showSettings = false
    @State private var showQRCode = false
    @State private var deepLinkHash: String?

    var body: some View {
        NavigationStack {
            ChatListView(
                selectedChatId: $selectedChatId,
                showNewChat: $showNewChat,
                showSettings: $showSettings,
                showQRCode: $showQRCode
            )
            .blur(radius: (showSettings || showNewChat) ? 8 : 0)
            .animation(.easeInOut(duration: 0.25), value: showSettings || showNewChat)
            .navigationDestination(item: $selectedChatId) { chatId in
                ConversationView(chatId: chatId)
            }
            .sheet(isPresented: $showNewChat) {
                NewChatView(selectedChatId: $selectedChatId)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showQRCode) {
                QRCodeView(mode: .display)
            }
        }
        .preferredColorScheme(.dark)
        .tint(.retichatPrimary)
        .onOpenURL { url in
            handleDeepLink(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChatFromNotification)) { notif in
            if let chatId = notif.object as? String {
                // Dismiss any presented sheets first
                showNewChat = false
                showSettings = false
                showQRCode = false
                // Navigate to the chat
                selectedChatId = chatId
            }
        }
    }

    private func handleDeepLink(_ url: URL) {
        // Handle lxmf:// deep links
        guard url.scheme == "lxmf" else { return }
        var hash = url.host ?? ""
        if hash.isEmpty {
            hash = url.absoluteString
                .replacingOccurrences(of: "lxmf://", with: "")
                .replacingOccurrences(of: "lxmf:", with: "")
        }
        hash = hash.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-f0-9]", with: "", options: .regularExpression)

        if hash.count == 32 {
            let chatId = repository.createDirectChat(destHash: hash)
            selectedChatId = chatId
        }
    }
}
