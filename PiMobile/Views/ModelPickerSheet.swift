import SwiftUI

/// Searchable model catalog + thinking level (only when the selected model supports it).
struct ModelPickerSheet: View {
    let groups: [ModelGroup]
    @Binding var model: String?
    @Binding var thinking: String?
    var sessionModel: String?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// Provider sections the user has expanded. Empty = all collapsed.
    @State private var expanded = Set<String>()

    private var selectedId: String? { model ?? sessionModel }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filtered: [ModelGroup] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return groups }
        return groups.compactMap { group in
            let models = group.models.filter {
                $0.id.lowercased().contains(q) || prettyModel($0.id).lowercased().contains(q)
                    || group.title.lowercased().contains(q)
            }
            return models.isEmpty ? nil : ModelGroup(title: group.title, models: models)
        }
    }

    private var selectedInfo: ModelInfo? {
        HarnessModels.info(for: selectedId, in: groups)
    }

    private var selectedThinkingLevels: [ThinkingLevel] {
        (selectedInfo?.thinkingLevels ?? []).compactMap(ThinkingLevel.init(rawValue:))
    }

    var body: some View {
        NavigationStack {
            List {
                if let info = selectedInfo, info.supportsThinking, !selectedThinkingLevels.isEmpty {
                    Section("Thinking") {
                        thinkingRow(label: "Default", value: nil)
                        ForEach(selectedThinkingLevels) { level in
                            thinkingRow(label: level.label, value: level.rawValue)
                        }
                    }
                }

                ForEach(filtered, id: \.title) { group in
                    Section {
                        DisclosureGroup(
                            isExpanded: expansionBinding(for: group.title)
                        ) {
                            ForEach(group.models) { m in
                                modelRow(m)
                            }
                        } label: {
                            Text(group.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.text)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .searchable(text: $query, prompt: "Search models")
            .navigationTitle("Model")
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

    private func expansionBinding(for title: String) -> Binding<Bool> {
        Binding(
            get: { isSearching || expanded.contains(title) },
            set: { isExpanded in
                if isExpanded {
                    expanded.insert(title)
                } else {
                    expanded.remove(title)
                }
            }
        )
    }

    private func modelRow(_ m: ModelInfo) -> some View {
        Button {
            model = m.id
            if !m.supportsThinking {
                thinking = nil
            } else if let thinking, !m.thinkingLevels.contains(thinking) {
                self.thinking = nil
            }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(prettyModel(m.id))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Text(m.id)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                if m.supportsThinking {
                    Text("Think")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.white.opacity(0.06), in: Capsule())
                }
                if m.id == selectedId {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
    }

    private func thinkingRow(label: String, value: String?) -> some View {
        Button {
            thinking = value
        } label: {
            HStack {
                Text(label).foregroundStyle(Theme.text)
                Spacer()
                if thinking == value {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
    }
}
