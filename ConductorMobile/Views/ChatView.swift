import SwiftUI

struct ChatView: View {
    @Environment(APIClient.self) private var api
    let workspace: Workspace
    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var session: ChatSession?
    private var sessionId: String? { session?.id }
    @State private var running = false
    @State private var activity = ""
    @State private var model: PickableModel?   // nil = session default

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(messages) { MessageRow(message: $0, sessionId: sessionId) }
                }
                .padding(16)
            }
            .defaultScrollAnchor(.bottom)
            VStack(spacing: 9) {
                if running { streamingBar }
                composer
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .overlay(alignment: .top) { Divider().overlay(Theme.separator) }
        }
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(workspace.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if let branch = workspace.branch {
                        Text(branch)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                StatusBadge(status: workspace.status)
            }
            .sharedBackgroundVisibility(.hidden)   // drop iOS 26's glass capsule around the badge
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private var streamingBar: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small).tint(Theme.accent)
            Text(activity.isEmpty ? "Working…" : activity)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(red: 0.63, green: 0.63, blue: 0.67))
                .lineLimit(1)
            Spacer()
            Button {
                Task { if let sessionId { try? await api.stop(sessionId: sessionId) } }
            } label: {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.97, green: 0.44, blue: 0.44)).frame(width: 8, height: 8)
                    Text("Stop")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 0.95, green: 0.63, blue: 0.63))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.13), lineWidth: 1))
            }
        }
        .padding(.horizontal, 4)
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespaces).isEmpty && !running && sessionId != nil }

    private var composerPlaceholder: String {
        running ? "Agent is working…" : "Message \(workspace.branch ?? workspace.name)"
    }

    private var isClaude: Bool { session?.isClaude ?? true }

    private var modelPill: some View {
        Menu {
            Picker("Model", selection: $model) {
                Text("Default").tag(PickableModel?.none)
            }
            Section("Claude Code") {
                Picker("Claude Code", selection: $model) {
                    ForEach(PickableModel.allCases) { m in
                        Text(m.label).tag(PickableModel?.some(m))
                    }
                }
            }
            // Visible parity with desktop; disabled until the server can drive these CLIs.
            ForEach(DesktopOnlyModels.groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.models, id: \.self) { name in
                        Button(name) {}.disabled(true)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(model?.label ?? session?.modelLabel ?? "Default")
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.5)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Color.white.opacity(0.06), in: Capsule())
        }
        // Model override only works for claude sessions; other harnesses run their session's model.
        .disabled(!isClaude)
    }

    private var composer: some View {
        HStack(spacing: 6) {
            modelPill
            TextField(composerPlaceholder, text: $draft)
                .font(.system(size: 14.5))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 8)
                .onSubmit { send() }
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(canSend ? Theme.bg : Theme.textMuted)
                    .frame(width: 34, height: 34)
                    .background(canSend ? Theme.accent : Color.white.opacity(0.07), in: Circle())
            }
            .disabled(!canSend)
        }
        .padding(6)
        .background(Color(red: 0.47, green: 0.47, blue: 0.5).opacity(0.13), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.white.opacity(0.13), lineWidth: 0.5))
    }

    private func send() {
        guard canSend, let sessionId else { return }
        let text = draft.trimmingCharacters(in: .whitespaces)
        draft = ""
        running = true
        Task {
            try? await api.send(sessionId: sessionId, text: text, model: model?.rawValue)
            await refresh()
            await poll()
        }
    }

    private func poll() async {
        guard let sessionId else { return }
        while running {
            try? await Task.sleep(for: .seconds(1.5))
            let status = try? await api.status(sessionId: sessionId)
            activity = status?.activity ?? ""
            await refresh()
            if status?.running == false { running = false }
        }
    }

    private func load() async {
        if session == nil {
            session = try? await api.sessions(workspaceId: workspace.id).first
        }
        await refresh()
        if let sessionId, let status = try? await api.status(sessionId: sessionId), status.running {
            running = true
            activity = status.activity
            await poll()
        }
    }

    private func refresh() async {
        guard let sessionId else { return }
        messages = (try? await api.messages(sessionId: sessionId)) ?? messages
    }
}

// Conductor embeds pasted files in message text as "@⟦name⟧(url-encoded-relative-path)".
struct Attachment: Identifiable {
    let name: String
    let path: String
    var id: String { path }
    var isImage: Bool { ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains((name as NSString).pathExtension.lowercased()) }
}

func parseAttachments(_ text: String) -> (text: String, attachments: [Attachment]) {
    var attachments: [Attachment] = []
    var stripped = text
    while let m = stripped.range(of: #"@⟦([^⟧]*)⟧\(([^)]+)\)"#, options: .regularExpression) {
        let token = String(stripped[m])
        let name = String(token.dropFirst(2).prefix(while: { $0 != "⟧" }))
        let path = token.split(separator: "(").last.map { String($0.dropLast()) } ?? ""
        attachments.append(Attachment(name: name, path: path.removingPercentEncoding ?? path))
        stripped.removeSubrange(m)
    }
    return (stripped.trimmingCharacters(in: .whitespacesAndNewlines), attachments)
}

struct AttachmentImage: View {
    @Environment(APIClient.self) private var api
    let sessionId: String
    let attachment: Attachment
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .frame(maxWidth: 240, maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                Label(attachment.name, systemImage: "photo")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(10)
                    .background(Theme.toolBg, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .task {
            if let data = try? await api.attachment(sessionId: sessionId, path: attachment.path) {
                image = UIImage(data: data)
            }
        }
    }
}

struct MessageRow: View {
    let message: ChatMessage
    var sessionId: String?

    var body: some View {
        switch message.role {
        case "thinking":
            ThinkingRow(text: message.content)
        case "duration":
            Text(message.content)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textMuted)
                .padding(.top, -6)
        case "user":
            let parsed = parseAttachments(message.content)
            HStack {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 8) {
                    if let sessionId {
                        ForEach(parsed.attachments) { att in
                            if att.isImage {
                                AttachmentImage(sessionId: sessionId, attachment: att)
                            } else {
                                Label(att.name, systemImage: "doc")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }
                    if !parsed.text.isEmpty {
                        Text(parsed.text)
                            .font(.system(size: 14.5))
                            .foregroundStyle(Color(red: 0.93, green: 0.93, blue: 0.94))
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(
                                Color(red: 0.118, green: 0.118, blue: 0.14),
                                in: UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18,
                                                           bottomTrailingRadius: 5, topTrailingRadius: 18)
                            )
                            .copyable(parsed.text)
                    }
                }
            }
        case "tool":
            ToolRow(content: message.content)
        default:
            Text(LocalizedStringKey(message.content))
                .font(.system(size: 14.5))
                .foregroundStyle(Color(red: 0.84, green: 0.84, blue: 0.86))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .copyable(message.content)
        }
    }
}

extension View {
    // Long-press any message to copy it, like the desktop's copy button.
    func copyable(_ text: String) -> some View {
        contextMenu {
            Button { UIPasteboard.general.string = text } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }
}

struct ThinkingRow: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Thinking")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            }
            if expanded {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                    .lineSpacing(3)
                    .copyable(text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ToolRow: View {
    let content: String   // "ToolName arg-summary"

    private var tag: String { content.split(separator: " ").first.map(String.init) ?? "TOOL" }
    private var label: String { content.dropFirst(tag.count).trimmingCharacters(in: .whitespaces) }
    private var isEdit: Bool { ["Edit", "Write", "NotebookEdit"].contains(tag) }

    var body: some View {
        HStack(spacing: 9) {
            Text(tag.uppercased())
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .kerning(0.8)
                .foregroundStyle(isEdit ? Color(red: 0.66, green: 0.72, blue: 0.91) : Color(red: 0.58, green: 0.86, blue: 0.66))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(
                    (isEdit ? Theme.accent.opacity(0.12) : Theme.green.opacity(0.1)),
                    in: RoundedRectangle(cornerRadius: 5)
                )
            Text(label)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.toolBg, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
    }
}
