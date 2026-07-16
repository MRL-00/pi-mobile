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
    static let accent = Color(red: 0.957, green: 0.447, blue: 0.714)      // #F472B6 pink
    static let sage = Color(red: 0.658, green: 0.804, blue: 0.71)         // muted green for "done"
    static let champagne = Color(red: 0.898, green: 0.776, blue: 0.53)    // muted gold for "in progress"
    static let lilac = Color(red: 0.776, green: 0.655, blue: 0.937)       // for "in review"
    static let green = sage                                               // diff insertions
    static let border = Color.white.opacity(0.1)
    static let separator = Color.white.opacity(0.06)
}

struct StatusStyle {
    let label: String
    let color: Color
    let pulses: Bool

    init(_ status: String) {
        switch status {
        case "done": self.init(label: "Done", color: Theme.sage, pulses: false)
        case "in-review": self.init(label: "In review", color: Theme.lilac, pulses: true)
        case "in-progress": self.init(label: "In progress", color: Theme.champagne, pulses: true)
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

// Stable across launches, unlike String.hashValue. Shared by RepoTint and GlyphTile.
func djb2(_ s: String) -> Int {
    s.utf8.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1) }
}

// Deterministic tint per repo name, matching the design's tinted glyph tiles.
struct RepoTint {
    let bg: Color
    let fg: Color

    init(name: String) {
        let palette: [(Color, Color)] = [
            (Theme.accent.opacity(0.13), Color(red: 0.96, green: 0.62, blue: 0.8)),
            (Theme.lilac.opacity(0.13), Color(red: 0.82, green: 0.72, blue: 0.95)),
            (Theme.sage.opacity(0.12), Color(red: 0.72, green: 0.84, blue: 0.76)),
            (Theme.champagne.opacity(0.12), Color(red: 0.91, green: 0.81, blue: 0.62)),
        ]
        // String.hashValue is seeded per launch; djb2 keeps the tint stable.
        (bg, fg) = palette[abs(djb2(name)) % palette.count]
    }
}

// Pixel identicon derived from the repo name — same idea as the desktop's
// generated project icons (theirs are app code, so ours match in spirit, not pixels).
struct GlyphTile: View {
    let name: String
    var size: CGFloat = 38

    var body: some View {
        let tint = RepoTint(name: name)
        Canvas { ctx, canvasSize in
            let grid = 5
            let cell = canvasSize.width / CGFloat(grid + 2) // 1-cell padding
            var seed = UInt64(bitPattern: Int64(djb2(name)))
            var bits: [Bool] = []
            for _ in 0..<15 { // left half + center column, mirrored
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                bits.append((seed >> 33) & 1 == 1)
            }
            for row in 0..<grid {
                for col in 0..<grid {
                    let src = col < 3 ? col : 4 - col // mirror
                    guard bits[row * 3 + src] else { continue }
                    let rect = CGRect(x: cell * CGFloat(col + 1), y: cell * CGFloat(row + 1), width: cell, height: cell)
                    ctx.fill(Path(rect.insetBy(dx: 0.25, dy: 0.25)), with: .color(tint.fg))
                }
            }
        }
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
