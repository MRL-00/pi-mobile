import SwiftUI

struct WorkspacesView: View {
    @Environment(APIClient.self) private var api
    let repo: Repo
    @State private var workspaces: [Workspace] = []
    @State private var loaded = false
    @State private var creating = false
    @State private var newWorkspace: Workspace?
    @State private var createError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                if loaded && workspaces.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(workspaces) { ws in
                            NavigationLink(value: ws) { WorkspaceRow(ws: ws) }
                                .contextMenu {
                                    Button("Remove from app", systemImage: "trash", role: .destructive) {
                                        Task {
                                            try? await api.deleteWorkspace(ws.id)
                                            workspaces.removeAll { $0.id == ws.id }
                                        }
                                    }
                                }
                            Divider().overlay(Color.white.opacity(0.05))
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .refreshable { await load() }
        }
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await createWorkspace() }
                } label: {
                    if creating {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "plus")
                    }
                }
                .disabled(creating)
            }
        }
        .navigationDestination(for: Workspace.self) { ChatView(workspace: $0) }
        .navigationDestination(item: $newWorkspace) { ChatView(workspace: $0) }
        .alert("Couldn't create workspace", isPresented: Binding(
            get: { createError != nil },
            set: { if !$0 { createError = nil } }
        )) {
            Button("OK", role: .cancel) { createError = nil }
        } message: {
            Text(createError ?? "")
        }
        .task {
            // Route all calls in this repo (and chats below it) to its owning Mac.
            api.activeMac = api.mac(withId: repo.macId)
            await load()
        }
        // Live status badges — poll quietly so send/finish doesn't require pull-to-refresh.
        .task(id: repo.id) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                await loadQuiet()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            GlyphTile(name: repo.name, size: 30)
            Text(repo.name)
                .font(.system(size: 21, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.text)
            Spacer()
            Text(workspaces.isEmpty ? "" : "\(workspaces.count) workspace\(workspaces.count == 1 ? "" : "s")")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider().overlay(Theme.separator) }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No active workspaces")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(red: 0.63, green: 0.63, blue: 0.67))
            Text("Run `pi` in a project folder on your Mac and it will show up here.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
        .padding(.top, 80)
    }

    // Creates a fresh worktree + session on the Mac and jumps straight into the chat.
    // The workspace shows a temporary "New Workspace" label until the first
    // message, when the companion server renames it from the task.
    private func createWorkspace() async {
        creating = true
        defer { creating = false }
        do {
            let ws = try await api.createWorkspace(repoId: repo.id)
            workspaces.insert(ws, at: 0)
            newWorkspace = ws
        } catch {
            createError = error.localizedDescription
        }
    }

    private func load() async {
        workspaces = (try? await api.workspaces(repoId: repo.id)) ?? []
        loaded = true
    }

    /// Background refresh for status badges; ignore failures so offline doesn't wipe the list.
    private func loadQuiet() async {
        guard let latest = try? await api.workspaces(repoId: repo.id) else { return }
        // Preserve order when ids match so the list doesn't jump during a poll.
        if latest.map({ $0.id }) == workspaces.map({ $0.id }) {
            for i in workspaces.indices {
                if let next = latest.first(where: { $0.id == workspaces[i].id }) {
                    workspaces[i] = next
                }
            }
        } else {
            workspaces = latest
        }
        loaded = true
    }
}

struct WorkspaceRow: View {
    let ws: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if ws.unread {
                    Circle().fill(Theme.accent).frame(width: 7, height: 7)
                }
                Text(ws.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer()
                Text(ws.updatedAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
            HStack(spacing: 8) {
                if let branch = ws.branch { BranchChip(branch: branch) }
                StatusBadge(status: ws.status)
                Spacer()
            }
            if let snippet = ws.lastMessageSnippet {
                Text(snippet)
                    .font(.system(size: 13))
                    .foregroundStyle(ws.unread ? Theme.textSecondary : Theme.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}
