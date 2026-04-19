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
    @State private var showNewChat = false
    @State private var showNewGroup = false
    @State private var showSettings = false
    @State private var showQRCode = false
    @State private var windowWidth: CGFloat = 0
    @State private var selectedTab = 0

    private var useWideLayout: Bool {
        #if targetEnvironment(macCatalyst)
        return windowWidth >= 800
        #else
        return horizontalSizeClass == .regular
        #endif
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            // MARK: Tab 1 — Messages
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
            .tabItem {
                Label("Messages", systemImage: "bubble.left.and.bubble.right")
            }
            .tag(0)

            // MARK: Tab 2 — Channels
            ChannelListView()
                .tabItem {
                    Label("Channels", systemImage: "antenna.radiowaves.left.and.right")
                }
                .tag(1)
        }
        .preferredColorScheme(.dark)
        .tint(.retichatPrimary)
        .onOpenURL { url in
            handleDeepLink(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChatFromNotification)) { notif in
            if let chatId = notif.object as? String {
                selectedTab = 0
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
                showNewGroup: $showNewGroup,
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
            .sheet(isPresented: $showNewGroup) {
                NewGroupView(selectedChatId: $selectedChatId, onDismissParent: { showNewGroup = false })
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
                showNewGroup: $showNewGroup,
                showSettings: $showSettings,
                showQRCode: $showQRCode
            )
            .blur(radius: (showSettings || showNewChat) ? 8 : 0)
            .animation(.easeInOut(duration: 0.25), value: showSettings || showNewChat)
            .sheet(isPresented: $showNewChat) {
                NewChatView(selectedChatId: $selectedChatId)
            }
            .sheet(isPresented: $showNewGroup) {
                NewGroupView(selectedChatId: $selectedChatId, onDismissParent: { showNewGroup = false })
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
