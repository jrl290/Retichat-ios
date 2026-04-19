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
            }
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
