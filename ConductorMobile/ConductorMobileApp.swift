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
struct ConductorMobileApp: App {
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
        }
    }
}
