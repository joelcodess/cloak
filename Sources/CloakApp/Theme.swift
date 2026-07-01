import SwiftUI

// Brand tokens applied to native controls: teal is the only accent, flat
// surfaces, 8px card / 4px input radii, platform font, no emoji.

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

enum Theme {
    static let accent = Color(hex: 0x00869E)   // brand teal
    static let danger = Color(hex: 0xF14668)
    static let cardRadius: CGFloat = 8
    static let inputRadius: CGFloat = 4
    static let surface = Color(nsColor: .textBackgroundColor)
    static let panel = Color(nsColor: .underPageBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)
}

/// A flat bordered card (no resting shadow), matching the design system.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(14)
            .background(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.hairline))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
    }
}
