//
//  ChannelListView.swift
//  Retichat
//
//  List of subscribed channels.
//

import SwiftUI

struct ChannelListView: View {
    @EnvironmentObject var channelClient: RfedChannelClient
    @State private var showAddChannel = false
    @State private var selectedChannelId: String?

    var body: some View {
        ZStack {
            Color.retichatBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Channels")
                        .font(.title2).bold()
                        .foregroundColor(.retichatOnSurface)
                    Spacer()
                    Button { showAddChannel = true } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.retichatPrimary)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)

                Divider().background(Color.retichatOnSurfaceVariant.opacity(0.2))

                if channelClient.channels.isEmpty {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 48))
                            .foregroundColor(.retichatOnSurfaceVariant)
                        Text("No channels yet")
                            .font(.headline)
                            .foregroundColor(.retichatOnSurfaceVariant)
                        Text("Tap + to join or create a channel")
                            .font(.subheadline)
                            .foregroundColor(.retichatOnSurfaceVariant.opacity(0.7))
                    }
                    Spacer()
                } else {
                    NavigationStack {
                        List {
                            ForEach(channelClient.channels.sorted { $0.lastMessageTime > $1.lastMessageTime }) { channel in
                                NavigationLink(destination: ChannelView(channel: channel)) {
                                    ChannelRowView(channel: channel)
                                }
                                .listRowBackground(Color.retichatSurface)
                            }
                            .onDelete { offsets in
                                let sorted = channelClient.channels.sorted { $0.lastMessageTime > $1.lastMessageTime }
                                for idx in offsets {
                                    let channel = sorted[idx]
                                    Task { await channelClient.leaveChannel(channelHashHex: channel.id) }
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .background(Color.retichatBackground)
                    }
                }
            }
        }
        .sheet(isPresented: $showAddChannel) {
            AddChannelView()
        }
    }
}

// MARK: - Channel row

private struct ChannelRowView: View {
    let channel: Channel

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.retichatPrimary.opacity(0.15))
                    .frame(width: 44, height: 44)
                Text("#")
                    .font(.title3.bold())
                    .foregroundColor(.retichatPrimary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(channel.channelName)
                    .font(.headline)
                    .foregroundColor(.retichatOnSurface)
                if channel.lastMessageTime > 0 {
                    Text(Date(timeIntervalSince1970: channel.lastMessageTime / 1000),
                         style: .relative)
                        .font(.caption)
                        .foregroundColor(.retichatOnSurfaceVariant)
                } else {
                    Text("No messages yet")
                        .font(.caption)
                        .foregroundColor(.retichatOnSurfaceVariant.opacity(0.6))
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
