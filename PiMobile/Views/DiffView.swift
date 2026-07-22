import SwiftUI

struct DiffView: View {
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss
    let workspace: Workspace
    @State private var diff: WorkspaceDiff?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if let diff {
                    if diff.diff.isEmpty {
                        Text("No changes vs \(diff.base)")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textMuted)
                    } else {
                        ScrollView([.vertical, .horizontal]) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(diff.diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                                    DiffLine(line: String(line))
                                }
                            }
                            .padding(12)
                        }
                    }
                } else if failed {
                    Text("Couldn't load diff").foregroundStyle(Theme.textMuted)
                } else {
                    ProgressView().tint(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)
            .navigationTitle(diffTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .preferredColorScheme(.dark)
        .task {
            do { diff = try await api.diff(workspaceId: workspace.id) } catch { failed = true }
        }
    }

    private var diffTitle: String {
        guard let diff else { return "Diff" }
        // last line of --stat: " 17 files changed, 1470 insertions(+), 8 deletions(-)"
        return diff.stat.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "Diff"
    }
}

struct DiffLine: View {
    let line: String

    var body: some View {
        Text(line.isEmpty ? " " : line)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var color: Color {
        if line.hasPrefix("+") { return Color(red: 0.5, green: 0.87, blue: 0.6) }
        if line.hasPrefix("-") { return Color(red: 0.95, green: 0.57, blue: 0.56) }
        if line.hasPrefix("@@") { return Theme.accent }
        if line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("+++") || line.hasPrefix("---") {
            return Theme.textMuted
        }
        return Color(red: 0.44, green: 0.44, blue: 0.49)
    }

    private var background: Color {
        if line.hasPrefix("+") { return Theme.green.opacity(0.06) }
        if line.hasPrefix("-") { return Color(red: 0.97, green: 0.44, blue: 0.44).opacity(0.06) }
        if line.hasPrefix("diff ") { return Color.white.opacity(0.04) }
        return .clear
    }
}
