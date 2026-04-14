//
//  Theme.swift
//  Retichat
//
//  Color scheme and theme constants mirroring the Android Material3 dark theme.
//

import SwiftUI

// MARK: - Colors

extension Color {
    // Primary palette — deep blue/purple matching Android dark theme
    static let retichatPrimary = Color(red: 0.5, green: 0.7, blue: 1.0)
    static let retichatOnPrimary = Color(red: 0.0, green: 0.2, blue: 0.5)
    static let retichatPrimaryContainer = Color(red: 0.0, green: 0.3, blue: 0.6)
    static let retichatOnPrimaryContainer = Color(red: 0.8, green: 0.9, blue: 1.0)

    // Secondary
    static let retichatSecondary = Color(red: 0.7, green: 0.8, blue: 0.9)
    static let retichatOnSecondary = Color(red: 0.15, green: 0.25, blue: 0.35)

    // Background
    static let retichatBackground = Color(red: 0.06, green: 0.06, blue: 0.10)
    static let retichatSurface = Color(red: 0.10, green: 0.10, blue: 0.14)
    static let retichatSurfaceVariant = Color(red: 0.15, green: 0.16, blue: 0.20)

    // Text
    static let retichatOnBackground = Color(red: 0.90, green: 0.90, blue: 0.95)
    static let retichatOnSurface = Color(red: 0.90, green: 0.90, blue: 0.95)
    static let retichatOnSurfaceVariant = Color(red: 0.65, green: 0.67, blue: 0.72)

    // Accent / error
    static let retichatError = Color(red: 1.0, green: 0.4, blue: 0.4)
    static let retichatSuccess = Color(red: 0.4, green: 0.9, blue: 0.5)

    // Glass
    static let glassBackground = Color.white.opacity(0.06)
    static let glassBorder = Color.white.opacity(0.12)

    // Bubble colors
    static let outgoingBubble = Color(red: 0.15, green: 0.25, blue: 0.45)
    static let incomingBubble = Color(red: 0.15, green: 0.16, blue: 0.22)
}

// MARK: - Glass modifier

struct GlassBackground: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.glassBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(Color.glassBorder, lineWidth: 0.5)
                    )
            )
    }
}

extension View {
    func glassBackground(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassBackground(cornerRadius: cornerRadius))
    }
}
