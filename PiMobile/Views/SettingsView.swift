import SwiftUI

struct SettingsView: View {
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var statuses: [UUID: Bool] = [:]
    @State private var piVersions: [UUID: PiVersionInfo] = [:]
    @State private var piUpdatesInFlight: Set<UUID> = []
    @State private var piUpdateErrors: [UUID: String] = [:]
    @State private var showAddMac = false

    private var macsNeedingPiUpdate: [(mac: MacServer, info: PiVersionInfo)] {
        api.macs.compactMap { mac in
            guard let info = piVersions[mac.id], info.updateAvailable else { return nil }
            return (mac, info)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !macsNeedingPiUpdate.isEmpty {
                    Section {
                        ForEach(macsNeedingPiUpdate, id: \.mac.id) { item in
                            VStack(alignment: .leading, spacing: 10) {
                                Text("\(item.mac.name) is on Pi \(item.info.current ?? "?"); \(item.info.latest ?? "?") is available.")
                                    .font(.subheadline)
                                Button {
                                    Task { await updatePi(on: item.mac) }
                                } label: {
                                    HStack(spacing: 8) {
                                        if piUpdatesInFlight.contains(item.mac.id) {
                                            ProgressView()
                                                .controlSize(.small)
                                            Text("Updating…")
                                        } else {
                                            Image(systemName: "arrow.down.circle")
                                                .symbolRenderingMode(.monochrome)
                                            Text(piUpdateErrors[item.mac.id] == nil ? "Update Pi" : "Try Again")
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                    .foregroundStyle(.white)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(piUpdatesInFlight.contains(item.mac.id))
                                .accessibilityLabel(
                                    piUpdatesInFlight.contains(item.mac.id)
                                        ? "Updating Pi on \(item.mac.name)"
                                        : "Update Pi on \(item.mac.name)"
                                )

                                if let error = piUpdateErrors[item.mac.id] {
                                    Label(error, systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                        .accessibilityLabel("Pi update failed: \(error)")
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text("Update Pi")
                    } footer: {
                        Text("Pi Companion updates Pi directly on that Mac. Finish any running Pi turn first.")
                    }
                }

                Section("Macs") {
                    ForEach(api.macs) { mac in
                        NavigationLink {
                            MacEditView(mac: mac)
                        } label: {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(statuses[mac.id] == true ? Theme.accent : Theme.textMuted)
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mac.name)
                                    Text(mac.baseURL)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if piVersions[mac.id]?.updateAvailable == true {
                                    Text("Update Pi")
                                        .font(.caption)
                                        .foregroundStyle(Theme.champagne)
                                } else {
                                    Text(statuses[mac.id] == true ? "Online" : "Offline")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onDelete { api.macs.remove(atOffsets: $0) }
                    Button {
                        showAddMac = true
                    } label: {
                        Label("Add a Mac", systemImage: "plus")
                            .foregroundStyle(Theme.accent)
                    }
                }

                Section("Set up a Mac") {
                    VStack(alignment: .leading, spacing: 12) {
                        setupStep(1, "Install [Pi](https://pi.dev) and [Bun](https://bun.sh) on your Mac, and run at least one `pi` session in a project folder.")
                        setupStep(2, "In Terminal on the Mac, run:")
                        HStack {
                            Text(Self.installCommand)
                                .font(.caption2.monospaced())
                                .foregroundStyle(Theme.accent)
                                .textSelection(.enabled)
                            Spacer()
                            Button {
                                UIPasteboard.general.string = Self.installCommand
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(10)
                        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        setupStep(3, "It installs the companion server (auto-starts at login) and shows a QR code — scan it with this iPhone's Camera app and the Mac appears here, paired.")
                        setupStep(4, "Away from home? Install [Tailscale](https://tailscale.com) on both devices, then set the Mac's address here to its Tailscale hostname.")
                    }
                    .padding(.vertical, 4)
                }

                Section("Follow") {
                    Link(destination: URL(string: "https://x.com/codermatt")!) {
                        Label("Follow @codermatt on X", systemImage: "bird")
                            .foregroundStyle(Theme.accent)
                    }
                }

                Section {
                    Link("Pi Mobile on GitHub", destination: URL(string: "https://github.com/MRL-00/pi-mobile")!)
                        .foregroundStyle(.secondary)

                    DisclosureGroup("Changelog") {
                        changelogEntry("0.2.0 (17)", "Adding a Mac now checks that it's online first — you see Online/Offline before it joins the list, and offline Macs can't be added.")
                        changelogEntry("0.2.0 (10)", "The app is now Pi Companion: works with the Pi coding agent (pi.dev) — browse Pi sessions, send messages, switch between 15+ providers' models, add projects with a folder browser, and delete chats and workspaces.")
                        changelogEntry("0.1.0 (8)", "Model choices now come from Conductor on your Mac, including your configured OpenCode models.")
                        changelogEntry("0.1.0 (7)", "Moved the new-workspace button into the navigation bar.")
                        changelogEntry("0.1.0 (6)", "Added workspace creation from your iPhone.")
                        changelogEntry("0.1.0 (5)", "Added Tailscale and private-network support, plus the privacy policy.")
                        changelogEntry("0.1.0 (3)", "Added QR pairing and in-app Mac setup instructions.")
                        changelogEntry("0.1.0 (1)", "Initial release with agent chats, model switching, git diffs, image viewing, and support for multiple Macs.")
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
            .sheet(isPresented: $showAddMac) {
                AddMacView { mac in
                    statuses[mac.id] = true
                }
            }
            .task { await checkStatuses() }
        }
        .tint(Theme.accent)
    }

    static let installCommand = "curl -fsSL https://raw.githubusercontent.com/MRL-00/pi-mobile/main/server/install.sh | bash"

    private func setupStep(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.caption.bold())
                .frame(width: 20, height: 20)
                .background(Theme.accent.opacity(0.15), in: Circle())
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(.subheadline)
        }
    }

    private func changelogEntry(_ version: String, _ details: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(version)
                .font(.subheadline.bold())
            Text(details)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func checkStatuses() async {
        for mac in api.macs {
            statuses[mac.id] = (try? await api.repos(on: mac)) != nil
            // Older companions won't have /pi-version; treat that as "no prompt".
            if let info = try? await api.piVersion(on: mac) {
                piVersions[mac.id] = info
            }
        }
    }

    private func updatePi(on mac: MacServer) async {
        piUpdateErrors[mac.id] = nil
        piUpdatesInFlight.insert(mac.id)
        defer { piUpdatesInFlight.remove(mac.id) }

        do {
            let info = try await api.updatePi(on: mac)
            withAnimation(.easeOut(duration: 0.2)) {
                piVersions[mac.id] = info
            }
        } catch {
            piUpdateErrors[mac.id] = error.localizedDescription
        }
    }
}

/// Connection probe result shown while adding or editing a Mac.
private enum MacConnectionState: Equatable {
    case idle
    case checking
    case online
    case offline

    var label: String {
        switch self {
        case .idle: return "Not checked yet"
        case .checking: return "Checking…"
        case .online: return "Online"
        case .offline: return "Offline"
        }
    }
}

struct AddMacView: View {
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss
    /// Called with the saved Mac after a successful online add.
    var onAdded: ((MacServer) -> Void)?

    @State private var name = ""
    @State private var baseURL = "http://my-mac.tailnet:8940"
    @State private var token = ""
    @State private var connection: MacConnectionState = .idle
    @State private var errorMessage: String?
    @State private var adding = false

    private var trimmedURL: String { baseURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canCheck: Bool {
        !trimmedURL.isEmpty && !trimmedToken.isEmpty && connection != .checking && !adding
    }
    private var canAdd: Bool { connection == .online && !adding }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("MacBook Pro", text: $name)
                        .onChange(of: name) { _, _ in resetCheckIfNeeded() }
                }
                Section("Companion server") {
                    TextField("http://my-mac.tailnet:8940", text: $baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: baseURL) { _, _ in resetCheckIfNeeded() }
                    SecureField("Auth token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: token) { _, _ in resetCheckIfNeeded() }
                }
                Section {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(connectionDotColor)
                            .frame(width: 8, height: 8)
                        if connection == .checking {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(connection.label)
                            .foregroundStyle(connection == .offline ? .red : .primary)
                        Spacer()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Connection status: \(connection.label)")

                    Button {
                        Task { await checkConnection() }
                    } label: {
                        Label("Check Connection", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(!canCheck)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text("The Mac must be online before you can add it. The token is printed when the companion server starts, and stored in ~/.pi-companion/token on that Mac.")
                }
            }
            .navigationTitle("Add a Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task { await addMac() }
                    }
                    .disabled(!canAdd)
                }
            }
        }
        .tint(Theme.accent)
    }

    private var connectionDotColor: Color {
        switch connection {
        case .online: return Theme.accent
        case .offline: return .red
        case .checking, .idle: return Theme.textMuted
        }
    }

    private func resetCheckIfNeeded() {
        if connection == .online || connection == .offline {
            connection = .idle
            errorMessage = nil
        }
    }

    private func checkConnection() async {
        errorMessage = nil
        connection = .checking
        let candidate = MacServer(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "My Mac" : name.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: trimmedURL,
            token: trimmedToken
        )
        let online = await api.isOnline(candidate)
        connection = online ? .online : .offline
        if !online {
            errorMessage = APIError.macOffline.errorDescription
        }
    }

    private func addMac() async {
        adding = true
        defer { adding = false }
        errorMessage = nil
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "My Mac" : name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let mac = try await api.pair(name: displayName, baseURL: trimmedURL, token: trimmedToken)
            onAdded?(mac)
            dismiss()
        } catch {
            connection = .offline
            errorMessage = error.localizedDescription
        }
    }
}

struct MacEditView: View {
    @Environment(APIClient.self) private var api
    let mac: MacServer
    @State private var name: String = ""
    @State private var baseURL: String = ""
    @State private var token: String = ""
    @State private var connection: MacConnectionState = .idle
    @State private var errorMessage: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    private var trimmedURL: String { baseURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var connectionDetailsChanged: Bool {
        trimmedURL != mac.baseURL || trimmedToken != mac.token
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("MacBook Pro", text: $name)
            }
            Section("Companion server") {
                TextField("http://my-mac.tailnet:8940", text: $baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: baseURL) { _, _ in resetCheckIfNeeded() }
                SecureField("Auth token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: token) { _, _ in resetCheckIfNeeded() }
            }
            Section {
                HStack(spacing: 10) {
                    Circle()
                        .fill(connectionDotColor)
                        .frame(width: 8, height: 8)
                    if connection == .checking {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(connection.label)
                        .foregroundStyle(connection == .offline ? .red : .primary)
                    Spacer()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Connection status: \(connection.label)")

                Button {
                    Task { await checkConnection() }
                } label: {
                    Label("Check Connection", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(trimmedURL.isEmpty || trimmedToken.isEmpty || connection == .checking || saving)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("Changing the address or token requires the Mac to be online. The token is printed when the companion server starts, and stored in ~/.pi-companion/token on that Mac.")
            }
        }
        .navigationTitle(name.isEmpty ? "Mac" : name)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await save() }
                }
                .disabled(saving || (connectionDetailsChanged && connection != .online))
            }
        }
        .onAppear {
            name = mac.name
            baseURL = mac.baseURL
            token = mac.token
            Task { await checkConnection() }
        }
    }

    private var connectionDotColor: Color {
        switch connection {
        case .online: return Theme.accent
        case .offline: return .red
        case .checking, .idle: return Theme.textMuted
        }
    }

    private func resetCheckIfNeeded() {
        if connection == .online || connection == .offline {
            connection = .idle
            errorMessage = nil
        }
    }

    private func checkConnection() async {
        errorMessage = nil
        connection = .checking
        let candidate = MacServer(id: mac.id, name: name, baseURL: trimmedURL, token: trimmedToken)
        let online = await api.isOnline(candidate)
        connection = online ? .online : .offline
        if !online {
            errorMessage = APIError.macOffline.errorDescription
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        errorMessage = nil

        // Name-only edits are fine offline; address/token changes must reach the Mac.
        if connectionDetailsChanged {
            connection = .checking
            let candidate = MacServer(id: mac.id, name: name, baseURL: trimmedURL, token: trimmedToken)
            let online = await api.isOnline(candidate)
            connection = online ? .online : .offline
            guard online else {
                errorMessage = APIError.macOffline.errorDescription
                return
            }
        }

        guard let i = api.macs.firstIndex(where: { $0.id == mac.id }) else { return }
        api.macs[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? mac.name : name.trimmingCharacters(in: .whitespacesAndNewlines)
        api.macs[i].baseURL = trimmedURL
        api.macs[i].token = trimmedToken
        if api.activeMac?.id == mac.id {
            api.activeMac = api.macs[i]
        }
        dismiss()
    }
}
