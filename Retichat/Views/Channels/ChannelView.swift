//
//  ChannelView.swift
//  Retichat
//
//  Conversation view for a single channel.
//

import SwiftUI

struct ChannelView: View {
    let channel: Channel
    @EnvironmentObject var channelClient: RfedChannelClient
    @State private var composeText = ""
    @State private var isPulling = false
    @State private var showChannelInfo = false

    private var channelMessages: [ChannelMessage] {
        channelClient.messages[channel.id] ?? []
    }

    var body: some View {
        ZStack {
            Color.retichatBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(channelMessages) { msg in
                                ChannelMessageBubble(msg: msg)
                                    .id(msg.id)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: channelMessages.count) { _, _ in
                        if let last = channelMessages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                    .onAppear {
                        if let last = channelMessages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }

                Divider().background(Color.retichatOnSurfaceVariant.opacity(0.2))

                // Compose bar
                HStack(spacing: 8) {
                    TextField("Message #\(channel.channelName)…", text: $composeText, axis: .vertical)
                        .lineLimit(1...5)
                        .padding(10)
                        .background(Color.retichatSurface)
                        .cornerRadius(20)
                        .foregroundColor(.retichatOnSurface)

                    Button {
                        let text = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        channelClient.sendMessage(content: text, toChannel: channel)
                        composeText = ""
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                             ? .retichatOnSurfaceVariant.opacity(0.4)
                                             : .retichatPrimary)
                    }
                    .disabled(composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .navigationTitle("#\(channel.channelName)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    Button {
                        isPulling = true
                        Task {
                            await channelClient.pullDeferred(channel: channel)
                            isPulling = false
                        }
                    } label: {
                        if isPulling {
                            ProgressView().tint(.retichatPrimary)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(.retichatPrimary)
                        }
                    }
                    .disabled(isPulling)

                    Button {
                        showChannelInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundColor(.retichatPrimary)
                    }
                }
            }
        }
        .sheet(isPresented: $showChannelInfo) {
            ChannelInfoSheet(channel: channel)
        }
        .task {
            // Pull deferred messages on open
            await channelClient.pullDeferred(channel: channel)
        }
    }
}

// MARK: - Message bubble

private struct ChannelMessageBubble: View {
    let msg: ChannelMessage

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if msg.isOutgoing { Spacer(minLength: 60) }

            VStack(alignment: msg.isOutgoing ? .trailing : .leading, spacing: 2) {
                if !msg.isOutgoing {
                    Text(msg.senderHash.prefix(8) + "…")
                        .font(.caption2)
                        .foregroundColor(.retichatOnSurfaceVariant)
                }
                Text(msg.content)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(msg.isOutgoing ? Color.retichatPrimary : Color.retichatSurface)
                    .foregroundColor(msg.isOutgoing ? .white : .retichatOnSurface)
                    .cornerRadius(18)
                Text(Date(timeIntervalSince1970: msg.timestamp / 1000), style: .time)
                    .font(.caption2)
                    .foregroundColor(.retichatOnSurfaceVariant.opacity(0.7))
            }

            if !msg.isOutgoing { Spacer(minLength: 60) }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Channel info sheet

struct ChannelInfoSheet: View {
    @EnvironmentObject var channelClient: RfedChannelClient
    @Environment(\.dismiss) private var dismiss

    let channel: Channel
    /// Called after leaving so the presenting view can also dismiss (e.g. pop the nav stack).
    var onLeave: (() -> Void)? = nil
    @State private var notificationsEnabled = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.retichatBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        // Header
                        VStack(spacing: 6) {
                            Text("#\(channel.channelName)")
                                .font(.title3).fontWeight(.semibold)
                                .foregroundColor(.retichatOnSurface)
                            Text(channel.id)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.retichatOnSurfaceVariant)
                                .textSelection(.enabled)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 8)

                        // Notifications
                        GlassCard {
                            Toggle(isOn: $notificationsEnabled) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Notifications")
                                        .foregroundColor(.retichatOnSurface)
                                    Text(notificationsEnabled ? "You'll be notified of new messages" : "Notifications are off")
                                        .font(.caption)
                                        .foregroundColor(.retichatOnSurfaceVariant)
                                }
                            }
                            .tint(.retichatPrimary)
                            .onChange(of: notificationsEnabled) { _, enabled in
                                if enabled {
                                    UserPreferences.shared.enableChannelNotifications(channel.id)
                                } else {
                                    UserPreferences.shared.disableChannelNotifications(channel.id)
                                }
                            }
                        }

                        // Leave
                        GlassCard {
                            Button {
                                dismiss()
                                Task {
                                    await channelClient.leaveChannel(channelHashHex: channel.id)
                                    onLeave?()
                                }
                            } label: {
                                Label("Leave Channel", systemImage: "rectangle.portrait.and.arrow.right")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .foregroundColor(.retichatError)
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Channel Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                notificationsEnabled = UserPreferences.shared.isChannelNotificationsEnabled(channel.id)
            }
        }
    }
}
