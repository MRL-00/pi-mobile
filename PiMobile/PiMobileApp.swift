import SwiftUI

#if DEBUG
// Mirrors the real navigation shape: ChatView PUSHED onto a stack, not at root.
struct DebugChatPush: View {
    let workspace: Workspace
    @State private var path: [Workspace]

    init(workspace: Workspace) {
        self.workspace = workspace
        _path = State(initialValue: [workspace])
    }

    var body: some View {
        NavigationStack(path: $path) {
            Text("debug root")
                .navigationDestination(for: Workspace.self) { ChatView(workspace: $0) }
        }
    }
}
#endif

@main
struct PiMobileApp: App {
    @State private var api = APIClient()

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                // simctl launch ... --setenv DEBUG_WS=<workspace-id> jumps straight into a chat.
                if let wsId = ProcessInfo.processInfo.environment["DEBUG_WS"] {
                    DebugChatPush(workspace: Workspace(id: wsId, repositoryId: "", name: "debug",
                                                       branch: "debug/branch", status: "in-progress", unread: false,
                                                       lastMessageSnippet: nil, updatedAt: .now))
                } else {
                    ProjectsView()
                }
                #else
                ProjectsView()
                #endif
            }
            .environment(api)
            .preferredColorScheme(.dark)
            // pi-companion://pair?name=…&addr=…&token=… (QR printed by the server)
            .onOpenURL { url in
                guard url.scheme == "pi-companion", url.host() == "pair",
                      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                      let addr = items.first(where: { $0.name == "addr" })?.value,
                      let token = items.first(where: { $0.name == "token" })?.value else { return }
                let name = items.first(where: { $0.name == "name" })?.value ?? "My Mac"
                Task {
                    do {
                        let mac = try await api.pair(name: name, baseURL: addr, token: token)
                        api.pairingNotice = "\(mac.name) is online and ready."
                    } catch {
                        api.pairingNotice = error.localizedDescription
                    }
                }
            }
        }
    }
}
