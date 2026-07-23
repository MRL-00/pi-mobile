import SwiftUI

struct SettingsView: View {
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var statuses: [UUID: Bool] = [:]
    @State private var piVersions: [UUID: PiVersionInfo] = [:]

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
                                HStack {
                                    Text(item.info.updateCommand)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(Theme.accent)
                                        .textSelection(.enabled)
                                    Spacer()
                                    Button {
                                        UIPasteboard.general.string = item.info.updateCommand
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(10)
                                .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text("Update Pi")
                    } footer: {
                        Text("Run this in Terminal on that Mac — Pi updates there, not in this app.")
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
                        api.macs.append(MacServer(name: "New Mac", baseURL: "http://my-mac.tailnet:8940", token: ""))
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
}

struct MacEditView: View {
    @Environment(APIClient.self) private var api
    let mac: MacServer
    @State private var name: String = ""
    @State private var baseURL: String = ""
    @State private var token: String = ""

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
                SecureField("Auth token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section {
                Text("The token is printed when the companion server starts, and stored in ~/.pi-companion/token on that Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(name.isEmpty ? "Mac" : name)
        .onAppear {
            name = mac.name
            baseURL = mac.baseURL
            token = mac.token
        }
        .onDisappear {
            guard let i = api.macs.firstIndex(where: { $0.id == mac.id }) else { return }
            api.macs[i].name = name
            api.macs[i].baseURL = baseURL.trimmingCharacters(in: .whitespaces)
            api.macs[i].token = token.trimmingCharacters(in: .whitespaces)
        }
    }
}
