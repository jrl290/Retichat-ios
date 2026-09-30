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
                // Sender name in group chats and channels, and in a channel
                // the grey secondary text beside it (DISPLAY_NAMES.md §5.3):
                // the channel name beside a local name, or the short hash
                // (monospace) beside a channel name.
                if isGroup && !message.isOutgoing {
                    HStack(spacing: 4) {
                        Text(message.senderName)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.retichatPrimary)
                            .lineLimit(1)
                            .layoutPriority(1)
                        if let secondary = message.senderSecondary {
                            Text(secondary)
                                .font(message.senderSecondaryIsHash
                                      ? .system(.caption2, design: .monospaced) : .caption2)
                                .foregroundColor(.retichatOnSurfaceVariant)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
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

// MARK: - Date marker

/// The day above the first message of a day in a message list (DayMarkers):
/// small, centred, secondary text, as in Messages. Not a message and not
/// tappable; VoiceOver reads it as a heading.
struct DayMarkerView: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundColor(.retichatOnSurfaceVariant)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .allowsHitTesting(false)
            .accessibilityAddTraits(.isHeader)
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
