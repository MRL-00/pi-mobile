import SwiftUI

struct ProjectsView: View {
    @Environment(APIClient.self) private var api
    @Environment(\.scenePhase) private var scenePhase
    @State private var allRepos: [Repo] = []
    @State private var onlineMacs: Set<UUID> = []
    @State private var isCheckingMacs = true
    @State private var activeLoadID = UUID()
    @State private var showSettings = false
    @State private var showAddProject = false
    @State private var addProjectError: String?
    @State private var resolvedInitialMac = false

    private var selectedMac: MacServer? {
        guard let id = api.activeMac?.id else { return api.macs.first }
        return api.macs.first { $0.id == id } ?? api.macs.first
    }

    private var connected: Bool {
        selectedMac.map { onlineMacs.contains($0.id) } ?? false
    }

    private var repos: [Repo] {
        guard let id = selectedMac?.id else { return [] }
        return allRepos.filter { $0.macId == id }
    }

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
                .refreshable { await load(maxAttempts: 1) }
            }
            .background(Theme.bg)
            .navigationDestination(for: Repo.self) { WorkspacesView(repo: $0) }
            .sheet(isPresented: $showSettings, onDismiss: { Task { await load(maxAttempts: 1) } }) { SettingsView() }
            .sheet(isPresented: $showAddProject) {
                FolderPickerView { path in
                    Task { await addProject(path) }
                }
            }
            .alert("Mac pairing", isPresented: Binding(
                get: { api.pairingNotice != nil },
                set: { if !$0 {
                    api.pairingNotice = nil
                    Task { await load(maxAttempts: 1) }
                } }
            )) {
                Button("OK", role: .cancel) { api.pairingNotice = nil }
            } message: {
                Text(api.pairingNotice ?? "")
            }
            .alert("Couldn't Add Project", isPresented: Binding(
                get: { addProjectError != nil },
                set: { if !$0 { addProjectError = nil } }
            )) {
                Button("OK", role: .cancel) { addProjectError = nil }
            } message: {
                Text(addProjectError ?? "")
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await load(maxAttempts: 3)
            }
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
                .disabled(!connected)
                .accessibilityLabel("Add a project on \(selectedMac?.name ?? "the selected Mac")")
                Menu {
                    Section("Connect to") {
                        ForEach(api.macs) { mac in
                            Button { api.activeMac = mac } label: {
                                Label(
                                    "\(mac.name) · \(macStatusLabel(mac))",
                                    systemImage: mac.id == selectedMac?.id ? "checkmark.circle.fill" : "circle"
                                )
                            }
                        }
                    }
                    Divider()
                    Button { showSettings = true } label: {
                        Label("Manage Macs", systemImage: "gearshape")
                    }
                } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(connected ? Theme.accent : Theme.textMuted)
                            .frame(width: 7, height: 7)
                            .shadow(color: connected ? Theme.accent : .clear, radius: 4)
                        Text(macPillLabel)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
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
        guard let selectedMac else { return "Choose a Mac" }
        return "\(selectedMac.name) · \(macStatusLabel(selectedMac))"
    }

    private func macStatusLabel(_ mac: MacServer) -> String {
        onlineMacs.contains(mac.id) ? "online" : (isCheckingMacs ? "checking…" : "offline")
    }

    private var subtitle: String {
        if connected {
            return "\(repos.count) projects · \(repos.reduce(0) { $0 + $1.activeWorkspaceCount }) active workspaces"
        }
        if isCheckingMacs {
            return "Checking \(selectedMac?.name ?? "your Mac")…"
        }
        return "\(selectedMac?.name ?? "This Mac") is offline. Choose another Mac or check its settings."
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

    private func load(maxAttempts: Int) async {
        let loadID = UUID()
        activeLoadID = loadID
        isCheckingMacs = true
        var all: [Repo] = []
        var online: Set<UUID> = []
        for mac in api.macs {
            if let macRepos = await reposWithRetry(on: mac, maxAttempts: maxAttempts) {
                online.insert(mac.id)
                for var r in macRepos {
                    r.macId = mac.id
                    all.append(r)
                }
            }
        }
        // A later foreground/manual refresh supersedes this result. This also
        // prevents a slow initial probe from overwriting a completed pull refresh.
        guard activeLoadID == loadID else { return }
        if let activeID = api.activeMac?.id,
           !api.macs.contains(where: { $0.id == activeID }) {
            api.activeMac = api.macs.first
        }
        if !resolvedInitialMac {
            if let selectedMac, !online.contains(selectedMac.id),
               let firstOnline = api.macs.first(where: { online.contains($0.id) }) {
                api.activeMac = firstOnline
            }
            resolvedInitialMac = true
        }
        allRepos = all
        onlineMacs = online
        isCheckingMacs = false
    }

    private func addProject(_ path: String) async {
        do {
            try await api.addProject(path: path)
            await load(maxAttempts: 1)
        } catch {
            addProjectError = error.localizedDescription
        }
    }

    /// A freshly foregrounded phone can briefly have no LAN/Tailscale route.
    /// Retry transient failures here so opening Manage Macs is not what wakes
    /// the connection and makes the same server suddenly appear online.
    private func reposWithRetry(on mac: MacServer, maxAttempts: Int) async -> [Repo]? {
        for attempt in 0..<maxAttempts {
            if Task.isCancelled { return nil }
            // Manual refresh gets one bounded attempt; startup gets a few short
            // attempts to allow the LAN/Tailscale route to wake up.
            let timeout: TimeInterval = maxAttempts == 1 ? 6 : 4
            if let repos = try? await api.repos(on: mac, timeoutInterval: timeout) { return repos }
            guard attempt < maxAttempts - 1 else { break }
            try? await Task.sleep(for: .milliseconds(500 * (attempt + 1)))
        }
        return nil
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
    @State private var browseError: String?
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            List {
                if isLoading && listing == nil {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                } else if let browseError {
                    if listing == nil {
                        ContentUnavailableView(
                            "Couldn't Load Folders",
                            systemImage: "folder.badge.questionmark",
                            description: Text(browseError)
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        Label(browseError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .listRowBackground(Color.clear)
                    }
                }
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
                    .disabled(listing == nil || isLoading)
                }
            }
            .task { await open(nil) }
        }
        .tint(Theme.accent)
    }

    private func open(_ path: String?) async {
        browseError = nil
        isLoading = true
        defer { isLoading = false }
        do {
            listing = try await api.browse(path: path)
        } catch {
            browseError = error.localizedDescription
        }
    }
}
