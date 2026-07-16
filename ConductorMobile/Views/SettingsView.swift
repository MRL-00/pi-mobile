import SwiftUI

struct SettingsView: View {
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss
    @AppStorage("twitterHandle") private var twitterHandle = ""
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

                Section("Follow") {
                    TextField("Your X / Twitter handle", text: $twitterHandle)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !cleanHandle.isEmpty, let url = URL(string: "https://x.com/\(cleanHandle)") {
                        Link(destination: url) {
                            Label("Follow @\(cleanHandle) on X", systemImage: "bird")
                                .foregroundStyle(Theme.accent)
                        }
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

    private var cleanHandle: String {
        twitterHandle.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "@", with: "")
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
