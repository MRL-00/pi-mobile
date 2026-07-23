import SwiftUI

/// Catalog of Pi skills installed on the Mac (`~/.pi/agent/skills` + packages).
/// Selecting one inserts `/skill:name` into the composer so RPC expands it.
struct SkillPickerSheet: View {
    let skills: [SkillInfo]
    let onPick: (SkillInfo) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [SkillInfo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return skills }
        return skills.filter {
            $0.name.lowercased().contains(q)
                || $0.description.lowercased().contains(q)
                || $0.command.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if skills.isEmpty {
                    ContentUnavailableView(
                        "No skills",
                        systemImage: "sparkles",
                        description: Text("Install skills into ~/.pi/agent/skills on your Mac, then pull to refresh.")
                    )
                } else {
                    List {
                        ForEach(filtered) { skill in
                            Button {
                                onPick(skill)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(skill.name)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(Theme.text)
                                    if !skill.description.isEmpty {
                                        Text(skill.description)
                                            .font(.system(size: 12.5))
                                            .foregroundStyle(Theme.textMuted)
                                            .lineLimit(3)
                                    }
                                    Text(skill.command)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.bg)
            .searchable(text: $query, prompt: "Search skills")
            .navigationTitle("Skills")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
