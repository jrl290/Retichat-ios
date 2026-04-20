//
//  ContentView.swift
//  Retichat
//
//  Main navigation container. Mirrors Android NavGraph.kt.
//

import SwiftUI
import SwiftData

// MARK: - Environment key for layout mode

private struct IsWideLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isWideLayout: Bool {
        get { self[IsWideLayoutKey.self] }
        set { self[IsWideLayoutKey.self] = newValue }
    }
}

struct ContentView: View {
    @EnvironmentObject var repository: ChatRepository
    @EnvironmentObject var channelClient: RfedChannelClient
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedChatId: String?
    @State private var selectedChannel: Channel?
    @State private var showNewConversation = false
    @State private var showSettings = false
    @State private var showQRCode = false
    @State private var windowWidth: CGFloat = 0

    private var useWideLayout: Bool {
        #if targetEnvironment(macCatalyst)
        return windowWidth >= 800
        #else
        return horizontalSizeClass == .regular
        #endif
    }

    var body: some View {
        GeometryReader { geo in
            Group {
                if useWideLayout {
                    wideLayout
                } else {
                    stackLayout
                }
            }
            .environment(\.isWideLayout, useWideLayout)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: geo.size.width) { _, newWidth in
                windowWidth = newWidth
            }
            .onAppear {
                windowWidth = geo.size.width
            }
        }
        .preferredColorScheme(.dark)
        .tint(.retichatPrimary)
        .onOpenURL { url in
            handleDeepLink(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChatFromNotification)) { notif in
            if let chatId = notif.object as? String {
                showNewConversation = false
                showSettings = false
                showQRCode = false
                selectedChannel = nil
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
                selectedChannel: $selectedChannel,
                showNewConversation: $showNewConversation,
                showSettings: $showSettings,
                showQRCode: $showQRCode
            )
            .blur(radius: (showSettings || showNewConversation) ? 8 : 0)
            .animation(.easeInOut(duration: 0.25), value: showSettings || showNewConversation)
            .navigationDestination(item: $selectedChatId) { chatId in
                ConversationView(mode: .dm(chatId: chatId))
            }
            .navigationDestination(item: $selectedChannel) { channel in
                ConversationView(mode: .channel(channel))
            }
            .sheet(isPresented: $showNewConversation) {
                NewConversationView(selectedChatId: $selectedChatId, selectedChannel: $selectedChannel)
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
                selectedChannel: $selectedChannel,
                showNewConversation: $showNewConversation,
                showSettings: $showSettings,
                showQRCode: $showQRCode
            )
            .blur(radius: (showSettings || showNewConversation) ? 8 : 0)
            .animation(.easeInOut(duration: 0.25), value: showSettings || showNewConversation)
            .sheet(isPresented: $showNewConversation) {
                NewConversationView(selectedChatId: $selectedChatId, selectedChannel: $selectedChannel)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showQRCode) {
                QRCodeView(mode: .display)
            }
        } detail: {
            if let chatId = selectedChatId {
                ConversationView(mode: .dm(chatId: chatId))
                    .id(chatId)
            } else if let channel = selectedChannel {
                ConversationView(mode: .channel(channel))
                    .id(channel.id)
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
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "lxma" || scheme == "lxmf" else { return }
        // host contains <hash> or <hash>.<pubkey> — take only the hash part
        var raw = (url.host ?? "").lowercased()
        if raw.isEmpty {
            raw = url.absoluteString
                .replacingOccurrences(of: "\(scheme)://", with: "")
        }
        // Strip optional .<pubkey> suffix
        let hashPart = raw.components(separatedBy: ".").first ?? raw
        let hash = hashPart.filter { "0123456789abcdef".contains($0) }

        if hash.count == 32 {
            let chatId = repository.createDirectChat(destHash: hash)
            selectedChatId = chatId
        }
    }
}
