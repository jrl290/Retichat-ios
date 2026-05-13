//
//  ChannelView.swift
//  Retichat
//
//  Channel info sheet presented from ConversationView toolbar.
//

import SwiftUI

// MARK: - Channel info sheet

struct ChannelInfoSheet: View {
    @EnvironmentObject var channelClient: RfedChannelClient
    @Environment(\.dismiss) private var dismiss

    let channel: Channel
    /// Called after leaving so the presenting view can also dismiss (e.g. pop the nav stack).
    var onLeave: (() -> Void)? = nil
    @State private var pushEnabled = false
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

                        // Push & notification settings
                        GlassCard {
                            VStack(spacing: 0) {
                                Toggle(isOn: $pushEnabled) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Push All Messages")
                                            .foregroundColor(.retichatOnSurface)
                                        Text(pushEnabled
                                             ? "Device is woken up for every new message"
                                             : "No push wakeups for this channel")
                                            .font(.caption)
                                            .foregroundColor(.retichatOnSurfaceVariant)
                                    }
                                }
                                .tint(.retichatPrimary)
                                .onChange(of: pushEnabled) { _, enabled in
                                    if enabled {
                                        channelClient.enableChannelPush(channelHashHex: channel.id)
                                    } else {
                                        channelClient.disableChannelPush(channelHashHex: channel.id)
                                    }
                                }

                                Divider()
                                    .background(Color.retichatOnSurfaceVariant.opacity(0.2))
                                    .padding(.vertical, 10)

                                Toggle(isOn: $notificationsEnabled) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Notifications")
                                            .foregroundColor(pushEnabled
                                                             ? .retichatOnSurface
                                                             : .retichatOnSurfaceVariant)
                                        Text(pushEnabled && notificationsEnabled
                                             ? "You'll be notified of new messages"
                                             : pushEnabled
                                               ? "Notifications are off"
                                               : "Enable Push All Messages first")
                                            .font(.caption)
                                            .foregroundColor(.retichatOnSurfaceVariant)
                                    }
                                }
                                .tint(.retichatPrimary)
                                .disabled(!pushEnabled)
                                .onChange(of: notificationsEnabled) { _, enabled in
                                    if enabled {
                                        UserPreferences.shared.enableChannelNotifications(channel.id)
                                    } else {
                                        UserPreferences.shared.disableChannelNotifications(channel.id)
                                    }
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
                pushEnabled = UserPreferences.shared.isChannelPushEnabled(channel.id)
                notificationsEnabled = UserPreferences.shared.isChannelNotificationsEnabled(channel.id)
            }
        }
    }
}
