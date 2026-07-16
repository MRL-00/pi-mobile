import SwiftUI

struct SettingsView: View {
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var statuses: [UUID: Bool] = [:]

    var body: some View {
        NavigationStack {
            Form {
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
                                Text(statuses[mac.id] == true ? "Online" : "Offline")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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
                        setupStep(1, "Install [Conductor](https://www.conductor.build) and [Bun](https://bun.sh) on your Mac, and run at least one agent session in it.")
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
                    Link("Conductor Mobile on GitHub", destination: URL(string: "https://github.com/MRL-00/conductor-mobile")!)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
            .task { await checkStatuses() }
        }
        .tint(Theme.accent)
    }

    static let installCommand = "curl -fsSL https://raw.githubusercontent.com/MRL-00/conductor-mobile/main/server/install.sh | bash"

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

    private func checkStatuses() async {
        for mac in api.macs {
            statuses[mac.id] = (try? await api.repos(on: mac)) != nil
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
                Text("The token is printed when the companion server starts, and stored in ~/.conductor-companion/token on that Mac.")
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
