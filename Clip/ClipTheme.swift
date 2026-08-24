import SwiftUI

// MARK: - Palette

enum ClipTheme {
    /// Tahoe-style translucent window background.
    static func windowBackground() -> Color {
        Color(nsColor: .windowBackgroundColor)
    }

    static let accent = Color.accentColor
    static let lavender = Color("ClipLavender")
    static let rosewood = Color("ClipRosewood")
    static let coral = Color("ClipCoral")
    static let bronze = Color("ClipBronze")
    static let success = Color("ClipSuccess")

    static func platformTint(_ platform: Platform) -> Color {
        switch platform {
        case .youtube: return coral
        case .twitter: return accent
        case .instagram: return rosewood
        case .tiktok: return lavender
        case .reddit: return bronze
        case .unknown: return secondary
        }
    }

    static var secondary: Color { Color(nsColor: .secondaryLabelColor) }
    static var separator: Color { Color(nsColor: .separatorColor) }
}

// MARK: - GlassCard

/// Tahoe Liquid Glass card: controlBackground fill, hairline stroke, soft shadow.
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = ClipConstants.cardCornerRadius
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
}

// MARK: - GlassProgressBar

struct GlassProgressBar: View {
    let fraction: Double
    var tint: Color = .accentColor

    var body: some View {
        Capsule()
            .fill(Color.black.opacity(0.05))
            .frame(height: ClipConstants.progressBarHeight)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(tint)
                        .frame(width: max(0, min(1, fraction)) * geo.size.width)
                }
            }
            .animation(.easeOut(duration: 0.25), value: fraction)
    }
}

// MARK: - Button styles

struct GlassPillButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(filled ? Color.white : tint)
            .background(
                Capsule().fill(filled ? tint : tint.opacity(0.12))
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}

struct GhostPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(Color.primary.opacity(0.75))
            .background(Capsule().fill(Color.primary.opacity(0.05)))
            .opacity(configuration.isPressed ? 0.65 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}
