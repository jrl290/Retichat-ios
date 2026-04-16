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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedChatId: String?
    @State private var showNewChat = false
    @State private var showSettings = false
    @State private var showQRCode = false

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                wideLayout
            } else {
                stackLayout
            }
        }
        .preferredColorScheme(.dark)
        .tint(.retichatPrimary)
        .onOpenURL { url in
            handleDeepLink(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChatFromNotification)) { notif in
            if let chatId = notif.object as? String {
                showNewChat = false
                showSettings = false
                showQRCode = false
                selectedChatId = chatId
            }
        }
        // Deselect if the active chat was deleted or archived out of the list
        .onChange(of: repository.chats.map(\.id)) { _, ids in
            if let current = selectedChatId, !ids.contains(current) {
                selectedChatId = nil
            }
        }
    }

    // MARK: - Compact layout (iPhone)

    private var stackLayout: some View {
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
    }

    // MARK: - Wide layout (iPad / landscape)

    private var wideLayout: some View {
        NavigationSplitView {
            ChatListView(
                selectedChatId: $selectedChatId,
                showNewChat: $showNewChat,
                showSettings: $showSettings,
                showQRCode: $showQRCode
            )
            .blur(radius: (showSettings || showNewChat) ? 8 : 0)
            .animation(.easeInOut(duration: 0.25), value: showSettings || showNewChat)
            .sheet(isPresented: $showNewChat) {
                NewChatView(selectedChatId: $selectedChatId)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showQRCode) {
                QRCodeView(mode: .display)
            }
        } detail: {
            if let chatId = selectedChatId {
                ConversationView(chatId: chatId)
                    .id(chatId)
            } else {
                noSelectionPlaceholder
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    // MARK: - Detail placeholder

    private var noSelectionPlaceholder: some View {
        ZStack {
            Color.retichatBackground.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 64))
                    .foregroundColor(.retichatOnSurfaceVariant.opacity(0.4))
                Text("Select a conversation")
                    .font(.title3)
                    .foregroundColor(.retichatOnSurfaceVariant.opacity(0.6))
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Deep link

    private func handleDeepLink(_ url: URL) {
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
