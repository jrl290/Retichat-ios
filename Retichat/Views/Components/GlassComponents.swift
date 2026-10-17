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
    /// Sends the user's reaction (REACTIONS-DESIGN.md §7): a quick reaction from the context
    /// menu, or a chip tapped to toggle it. Nil where reactions are not offered (channel posts).
    var onReact: ((String) -> Void)? = nil

    @State private var sharedAttachment: Attachment?
    @State private var selectingText = false

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 48) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                bubble
                if !message.reactions.isEmpty {
                    reactionChips
                }
            }
            .sheet(isPresented: $selectingText) {
                SelectableTextSheet(text: message.content)
            }

            if !message.isOutgoing { Spacer(minLength: 48) }
        }
    }

    /// Reactions are offered on a message that names a target (§2, §4) where the caller sends them.
    private var offersReactions: Bool { onReact != nil && message.reactable }

    private var bubble: some View {
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
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16))
        .contextMenu {
            if offersReactions, let onReact {
                // The quick reactions as one row at the top of the menu (§7).
                // A palette draws only each button's image, never its text, so each
                // emoji goes as an image too; the text stays for VoiceOver.
                ControlGroup {
                    ForEach(Reactions.quick, id: \.self) { emoji in
                        Button {
                            onReact(emoji)
                        } label: {
                            Label {
                                Text(emoji)
                            } icon: {
                                Image(uiImage: paletteImage(emoji))
                                    .renderingMode(.original)
                            }
                        }
                    }
                }
                .controlGroupStyle(.palette)
                // A palette stays open after a pick by default; a reaction is one pick.
                .menuActionDismissBehavior(.enabled)
            }
            if !message.content.isEmpty {
                Button {
                    UIPasteboard.general.string = message.content
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Button {
                    selectingText = true
                } label: {
                    Label("Select Text", systemImage: "selection.pin.in.out")
                }
            }
        }
        .sheet(item: $sharedAttachment) { attachment in
            ShareSheet(items: shareItems(for: attachment))
        }
    }

    /// `emoji` drawn as an image for the reaction palette, in its own colours (a menu would
    /// otherwise tint it as a template, one solid shape).
    private func paletteImage(_ emoji: String) -> UIImage {
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 28)]
        let text = emoji as NSString
        return UIGraphicsImageRenderer(size: text.size(withAttributes: attributes)).image { _ in
            text.draw(at: .zero, withAttributes: attributes)
        }.withRenderingMode(.alwaysOriginal)
    }

    /// The chips under the bubble (§3 "Display"): each reaction with how many gave it, marked when
    /// one of them is the user's; a tap gives that reaction, or takes it back when it is the user's.
    private var reactionChips: some View {
        HStack(spacing: 4) {
            ForEach(message.reactions) { chip in
                Button {
                    onReact?(chip.emoji)
                } label: {
                    HStack(spacing: 3) {
                        Text(chip.emoji)
                            .font(.callout)
                        Text("\(chip.count)")
                            .font(.caption2)
                            .fontWeight(chip.mine ? .semibold : .regular)
                            .foregroundColor(chip.mine ? .retichatPrimary : .retichatOnSurfaceVariant)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(chip.mine ? Color.retichatPrimary.opacity(0.22) : Color.glassBackground)
                            .overlay(
                                Capsule()
                                    .stroke(chip.mine ? Color.retichatPrimary.opacity(0.8) : Color.glassBorder,
                                            lineWidth: chip.mine ? 1 : 0.5)
                            )
                    )
                }
                .buttonStyle(.plain)
                .disabled(!offersReactions)
                .accessibilityLabel("\(chip.emoji) \(chip.count)\(chip.mine ? ", including yours" : "")")
            }
        }
        .padding(.horizontal, 6)
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

// MARK: - Select Text

/// The whole of a message's text, read-only, for selecting part of it (REACTIONS-DESIGN.md §7).
struct SelectableTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableTextView(text: text)
                .padding(.horizontal, 12)
                .background(Color.retichatBackground)
                .navigationTitle("Select Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

/// A read-only, selectable UITextView: SwiftUI's Text selects only the whole text.
struct SelectableTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.dataDetectorTypes = []
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = UIColor(Color.retichatOnSurface)
        view.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}
