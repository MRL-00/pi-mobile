import SwiftUI

// Design tokens from "Conductor Mobile.dc.html" (claude.ai/design).
enum Theme {
    static let bg = Color(red: 0.039, green: 0.039, blue: 0.043)          // #0A0A0B
    static let card = Color(red: 0.11, green: 0.11, blue: 0.125).opacity(0.6)
    static let toolBg = Color(red: 0.063, green: 0.063, blue: 0.075)      // #101013
    static let text = Color(red: 0.957, green: 0.957, blue: 0.961)        // #F4F4F5
    static let textSecondary = Color(red: 0.788, green: 0.788, blue: 0.82) // #C9C9D1
    static let textTertiary = Color(red: 0.541, green: 0.541, blue: 0.58)  // #8A8A94
    static let textMuted = Color(red: 0.384, green: 0.384, blue: 0.424)    // #62626C
    static let accent = Color(red: 0.478, green: 0.635, blue: 0.969)      // #7AA2F7
    static let green = Color(red: 0.29, green: 0.87, blue: 0.5)           // #4ADE80
    static let amber = Color(red: 0.984, green: 0.749, blue: 0.141)       // #FBBF24
    static let border = Color.white.opacity(0.1)
    static let separator = Color.white.opacity(0.06)
}

struct StatusStyle {
    let label: String
    let color: Color
    let pulses: Bool

    init(_ status: String) {
        switch status {
        case "done": self.init(label: "Done", color: Theme.green, pulses: false)
        case "in-review": self.init(label: "In review", color: Theme.accent, pulses: true)
        case "in-progress": self.init(label: "In progress", color: Theme.amber, pulses: true)
        default: self.init(label: "New", color: Color(red: 0.63, green: 0.63, blue: 0.67), pulses: false)
        }
    }

    init(label: String, color: Color, pulses: Bool) {
        self.label = label
        self.color = color
        self.pulses = pulses
    }
}

struct StatusBadge: View {
    let style: StatusStyle
    @State private var dim = false

    init(status: String) { style = StatusStyle(status) }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(style.color).frame(width: 5, height: 5)
                .opacity(dim ? 0.25 : 1)
                .animation(style.pulses ? .easeInOut(duration: 0.8).repeatForever() : .default, value: dim)
                .onAppear { if style.pulses { dim = true } }
            Text(style.label)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(style.color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(style.color.opacity(0.12), in: Capsule())
    }
}

// Deterministic tint per repo name, matching the design's tinted glyph tiles.
struct RepoTint {
    let bg: Color
    let fg: Color

    init(name: String) {
        let palette: [(Color, Color)] = [
            (Theme.accent.opacity(0.14), Color(red: 0.66, green: 0.72, blue: 0.91)),
            (Theme.amber.opacity(0.12), Color(red: 0.91, green: 0.81, blue: 0.56)),
            (Theme.green.opacity(0.10), Color(red: 0.58, green: 0.86, blue: 0.66)),
            (Color(red: 0.91, green: 0.48, blue: 0.98).opacity(0.12), Color(red: 0.93, green: 0.68, blue: 0.97)),
        ]
        let i = abs(name.hashValue) % palette.count
        (bg, fg) = palette[i]
    }
}

struct GlyphTile: View {
    let name: String
    var size: CGFloat = 38

    var body: some View {
        let tint = RepoTint(name: name)
        Text(String(name.prefix(2)).lowercased())
            .font(.system(size: size * 0.39, weight: .semibold, design: .monospaced))
            .foregroundStyle(tint.fg)
            .frame(width: size, height: size)
            .background(tint.bg, in: RoundedRectangle(cornerRadius: size * 0.26))
    }
}

struct BranchChip: View {
    let branch: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9))
                .opacity(0.7)
            Text(branch).lineLimit(1)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}
