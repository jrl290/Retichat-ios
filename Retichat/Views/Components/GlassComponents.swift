//
//  GlassComponents.swift
//  Retichat
//
//  Reusable UI components: glass surfaces, avatar, chat bubble.
//  Mirrors the Android GlassComponents.kt.
//

import SwiftUI

// MARK: - Avatar

/// Deterministic hash for a string — used for stable avatar colors across
/// process boundaries (main app and Notification Service Extension).
func avatarColorHue(for name: String) -> Double {
    var hash = 5381
    for scalar in name.unicodeScalars {
        hash = (hash &* 33) &+ Int(scalar.value)
    }
    return Double(abs(hash) % 360) / 360.0
}

struct AvatarView: View {
    let name: String
    var size: CGFloat = 48

    private var initials: String {
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    private var color: Color {
        return Color(hue: avatarColorHue(for: name), saturation: 0.5, brightness: 0.7)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.3))
                .overlay(
                    Circle()
                        .stroke(color.opacity(0.5), lineWidth: 1)
                )
            Text(initials)
                .font(.system(size: size * 0.35, weight: .semibold))
                .foregroundColor(color)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Chat bubble

struct ChatBubble: View {
    let message: ChatMessage
    let isGroup: Bool

    @State private var sharedAttachment: Attachment?

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 48) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                // Sender name in group chats
                if isGroup && !message.isOutgoing {
                    Text(message.senderName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.retichatPrimary)
                }

                // Attachments
                ForEach(message.attachments) { attachment in
                    attachmentView(for: attachment)
                }

                // Progress bar for outgoing attachment transfers (only when actively transferring)
                if message.isOutgoing, let progress = message.uploadProgress, progress >= 0, progress < 1.0 {
                    VStack(spacing: 2) {
                        ProgressView(value: Double(progress))
                            .tint(.retichatPrimary)
                            .frame(maxWidth: 200)
                        Text("\(Int(progress * 100))%")
                            .font(.caption2)
                            .foregroundColor(.retichatOnSurfaceVariant)
                    }
                }

                // Message content
                if !message.content.isEmpty {
                    Text(message.content)
                        .font(.body)
                        .foregroundColor(.retichatOnSurface)
                }

                // Timestamp + delivery status
                HStack(spacing: 4) {
                    Text(formatTime(message.timestamp))
                        .font(.caption2)
                        .foregroundColor(.retichatOnSurfaceVariant)

                    if message.isOutgoing {
                        deliveryIcon
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(message.isOutgoing ? Color.outgoingBubble : Color.incomingBubble)
            )
            .sheet(item: $sharedAttachment) { attachment in
                ShareSheet(items: shareItems(for: attachment))
            }

            if !message.isOutgoing { Spacer(minLength: 48) }
        }
    }

    @ViewBuilder
    private func attachmentView(for attachment: Attachment) -> some View {
        if attachment.isImage, let uiImage = UIImage(data: attachment.data) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 250, maxHeight: 250)
                .cornerRadius(12)
                .contentShape(Rectangle())
                .onTapGesture {
                    sharedAttachment = attachment
                }
        } else {
            HStack {
                Image(systemName: "doc.fill")
                    .foregroundColor(.retichatPrimary)
                Text(attachment.filename)
                    .font(.caption)
                    .foregroundColor(.retichatOnSurface)
            }
            .padding(8)
            .glassBackground(cornerRadius: 8)
            .contentShape(Rectangle())
            .onTapGesture {
                sharedAttachment = attachment
            }
        }
    }

    private func shareItems(for attachment: Attachment) -> [Any] {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(attachment.filename)
        try? attachment.data.write(to: fileURL)
        return [fileURL]
    }

    @ViewBuilder
    private var deliveryIcon: some View {
        switch message.deliveryState {
        case DeliveryState.pending:
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundColor(.retichatOnSurfaceVariant)
        case DeliveryState.sent:
            Text("\u{2713}")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.retichatOnSurfaceVariant)
        case DeliveryState.delivered:
            Text("\u{2713}\u{2713}")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.retichatPrimary)
        case DeliveryState.failed:
            Image(systemName: "xmark.circle")
                .font(.caption2)
                .foregroundColor(.retichatError)
        case DeliveryState.propagating:
            // Direct delivery failed; message is queued on a propagation node.
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption2)
                .foregroundColor(.retichatOnSurfaceVariant)
        default:
            EmptyView()
        }
    }

    private func formatTime(_ timestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "MMM d, HH:mm"
        }
        return formatter.string(from: date)
    }
}

// MARK: - Channel message bubble

/// Isolated bubble component for RFed channel messages.
/// The caller resolves `senderDisplayName` from the contact store so this view
/// stays free of service dependencies. If no name is known, the caller passes
/// the truncated identity hash instead.
struct ChannelBubble: View {
    let message: ChannelMessage
    let senderDisplayName: String

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if message.isOutgoing { Spacer(minLength: 60) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                if !message.isOutgoing {
                    Text(senderDisplayName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.retichatPrimary)
                }

                Text(message.content)
                    .font(.body)
                    .foregroundColor(.retichatOnSurface)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(message.isOutgoing ? Color.outgoingBubble : Color.incomingBubble)
                    )

                Text(Date(timeIntervalSince1970: message.timestamp / 1000), style: .time)
                    .font(.caption2)
                    .foregroundColor(.retichatOnSurfaceVariant.opacity(0.7))
            }

            if !message.isOutgoing { Spacer(minLength: 60) }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Status dot

struct StatusDot: View {
    let isOnline: Bool
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(isOnline ? Color.retichatSuccess : Color.retichatError)
            .frame(width: size, height: size)
    }
}

// MARK: - Glass card

struct GlassCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(16)
            .glassBackground()
    }
}

// MARK: - Share sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
