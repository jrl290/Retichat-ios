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
