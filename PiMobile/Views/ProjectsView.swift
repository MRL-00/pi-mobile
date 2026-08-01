import SwiftUI

struct ProjectsView: View {
    @Environment(APIClient.self) private var api
    @State private var repos: [Repo] = []
    @State private var onlineMacs: Set<UUID> = []
    @State private var showSettings = false
    @State private var showAddProject = false

    private var connected: Bool { !onlineMacs.isEmpty }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if repos.isEmpty && connected {
                            Text("No projects yet. Tap + to pick a folder on your Mac to run Pi in.")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textMuted)
                                .padding(.horizontal, 6)
                        }
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
            .sheet(isPresented: $showAddProject) {
                FolderPickerView { path in
                    Task { try? await api.addProject(path: path); await load() }
                }
            }
            .alert("Mac pairing", isPresented: Binding(
                get: { api.pairingNotice != nil },
                set: { if !$0 {
                    api.pairingNotice = nil
                    Task { await load() }
                } }
            )) {
                Button("OK", role: .cancel) { api.pairingNotice = nil }
            } message: {
                Text(api.pairingNotice ?? "")
            }
            .task { await load() }
        }
        .tint(Theme.accent)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    PiLogo()
                        .fill(Theme.text, style: FillStyle(eoFill: true))
                        .frame(width: 30, height: 30)
                    Text("Companion")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .kerning(2)
                        .textCase(.uppercase)
                }
                Spacer()
                Button { showAddProject = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(8)
                        .background(Color(red: 0.47, green: 0.47, blue: 0.5).opacity(0.16), in: Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.13), lineWidth: 0.5))
                }
                Button { showSettings = true } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(connected ? Theme.accent : Theme.textMuted)
                            .frame(width: 7, height: 7)
                            .shadow(color: connected ? Theme.accent : .clear, radius: 4)
                        Text(macPillLabel)
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

    private var macPillLabel: String {
        if api.macs.count <= 1 {
            let name = api.macs.first?.name ?? "Mac"
            return "\(name) · \(connected ? "online" : "offline")"
        }
        return "\(onlineMacs.count) of \(api.macs.count) Macs online"
    }

    private var subtitle: String {
        connected
            ? "\(repos.count) projects · \(repos.reduce(0) { $0 + $1.activeWorkspaceCount }) active workspaces"
            : "Check your Macs in settings."
    }

    private var repoCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(repos.enumerated()), id: \.element) { i, repo in
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
        var all: [Repo] = []
        var online: Set<UUID> = []
        for mac in api.macs {
            if let macRepos = try? await api.repos(on: mac) {
                online.insert(mac.id)
                for var r in macRepos {
                    r.macId = mac.id
                    all.append(r)
                }
            }
        }
        repos = all
        onlineMacs = online
    }
}

// The Pi mark from pi.dev/press-kit (logo.svg), drawn natively — it's all
// rectangles on an 800×800 grid, so no asset needed.
struct PiLogo: Shape {
    func path(in rect: CGRect) -> Path {
        // The svg's marks span 165.29…634.72 on its 800 canvas; normalize to the
        // frame so the glyph's left edge sits flush with whatever it aligns to.
        let s = min(rect.width, rect.height) / 469.43
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + (x - 165.29) * s, y: rect.minY + (y - 165.29) * s) }
        var p = Path()
        // P: outer boundary…
        p.move(to: pt(165.29, 165.29))
        p.addLine(to: pt(517.36, 165.29))
        p.addLine(to: pt(517.36, 400))
        p.addLine(to: pt(400, 400))
        p.addLine(to: pt(400, 517.36))
        p.addLine(to: pt(282.65, 517.36))
        p.addLine(to: pt(282.65, 634.72))
        p.addLine(to: pt(165.29, 634.72))
        p.closeSubpath()
        // …with its counter hole (even-odd fill)
        p.addRect(CGRect(origin: pt(282.65, 282.65), size: CGSize(width: 117.35 * s, height: 117.35 * s)))
        // i dot
        p.addRect(CGRect(origin: pt(517.36, 400), size: CGSize(width: 117.36 * s, height: 234.72 * s)))
        return p
    }
}

// Browse the Mac's folders (via the server's /browse) and pick a project root.
struct FolderPickerView: View {
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss
    let onPick: (String) -> Void

    @State private var listing: FolderListing?

    var body: some View {
        NavigationStack {
            List {
                if let parent = listing?.parent {
                    Button { Task { await open(parent) } } label: {
                        Label("..", systemImage: "arrow.turn.left.up")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                ForEach(listing?.dirs ?? [], id: \.self) { dir in
                    Button { Task { await open("\(listing?.path ?? "")/\(dir)") } } label: {
                        Label(dir, systemImage: "folder")
                            .foregroundStyle(Theme.text)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle(listing.map { ($0.path as NSString).lastPathComponent } ?? "Browse")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add This Folder") {
                        if let path = listing?.path { onPick(path); dismiss() }
                    }
                    .disabled(listing == nil)
                }
            }
            .task { await open(nil) }
        }
        .tint(Theme.accent)
    }

    private func open(_ path: String?) async {
        if let l = try? await api.browse(path: path) { listing = l }
    }
}
