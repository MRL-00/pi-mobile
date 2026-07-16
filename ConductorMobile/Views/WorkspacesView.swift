import SwiftUI

struct WorkspacesView: View {
    @Environment(APIClient.self) private var api
    let repo: Repo
    @State private var workspaces: [Workspace] = []
    @State private var loaded = false

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
        .navigationDestination(for: Workspace.self) { ChatView(workspace: $0) }
        .task {
            // Route all calls in this repo (and chats below it) to its owning Mac.
            api.activeMac = api.mac(withId: api.macForRepo[repo.id])
            await load()
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
            Text("Start an agent from Conductor on your Mac and it will show up here.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
        .padding(.top, 80)
    }

    private func load() async {
        workspaces = (try? await api.workspaces(repoId: repo.id)) ?? []
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
