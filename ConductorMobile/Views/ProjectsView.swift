import SwiftUI

struct ProjectsView: View {
    @Environment(APIClient.self) private var api
    @State private var repos: [Repo] = []
    @State private var connected = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        repoCard
                        Text("Workspaces run on your Mac. This phone is a remote — closing the app won't stop your agents.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(red: 0.29, green: 0.29, blue: 0.33))
                            .padding(.horizontal, 6)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 40)
                }
                .refreshable { await load() }
            }
            .background(Theme.bg)
            .navigationDestination(for: Repo.self) { WorkspacesView(repo: $0) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .task { await load() }
        }
        .tint(Theme.accent)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Conductor")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button { showSettings = true } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(connected ? Theme.green : Theme.textMuted)
                            .frame(width: 7, height: 7)
                            .shadow(color: connected ? Theme.green : .clear, radius: 4)
                        Text(connected ? "Mac · online" : "Mac · offline")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color(red: 0.47, green: 0.47, blue: 0.5).opacity(0.16), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.13), lineWidth: 0.5))
                }
            }
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textMuted)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 14)
    }

    private var subtitle: String {
        connected
            ? "\(repos.count) projects · \(repos.reduce(0) { $0 + $1.activeWorkspaceCount }) active workspaces"
            : "Check the server address and token in settings."
    }

    private var repoCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(repos.enumerated()), id: \.element.id) { i, repo in
                NavigationLink(value: repo) {
                    HStack(spacing: 12) {
                        GlyphTile(name: repo.name)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(repo.name)
                                .font(.system(size: 15, weight: .medium, design: .monospaced))
                                .foregroundStyle(Theme.text)
                            Text(repo.activeWorkspaceCount > 0 ? "\(repo.activeWorkspaceCount) active" : "no active workspaces")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.textMuted)
                        }
                        Spacer()
                        if repo.activeWorkspaceCount > 0 {
                            HStack(spacing: 6) {
                                Circle().fill(Theme.accent).frame(width: 6, height: 6)
                                Text("\(repo.activeWorkspaceCount)")
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Color.white.opacity(0.06), in: Capsule())
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary.opacity(0.5))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                }
                if i < repos.count - 1 {
                    Divider().overlay(Theme.separator).padding(.leading, 66)
                }
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Theme.border, lineWidth: 0.5))
    }

    private func load() async {
        do {
            repos = try await api.repos()
            connected = true
        } catch {
            connected = false
        }
    }
}
