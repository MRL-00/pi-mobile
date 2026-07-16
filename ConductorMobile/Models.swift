import Foundation

// Shapes mirror the companion server's JSON API, which mirrors conductor.db.

struct Repo: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let defaultBranch: String?
    let activeWorkspaceCount: Int
}

struct Workspace: Identifiable, Codable, Hashable {
    let id: String
    let repositoryId: String
    let name: String
    let branch: String?
    let status: String      // in-progress | waiting | done etc. (derived_status)
    let unread: Bool
    let lastMessageSnippet: String?
    let updatedAt: Date
}

struct ChatSession: Identifiable, Codable, Hashable {
    let id: String
    let workspaceId: String
    let title: String
    let model: String?
    let agentType: String?
    let updatedAt: Date

    var isClaude: Bool { agentType == nil || agentType == "claude" }
    var modelLabel: String { prettyModel(model) }
}

// All model groups, as Conductor model ids (matching the desktop picker).
// Picking a model from a different harness switches the chat's agent, like the desktop.
enum HarnessModels {
    static let groups: [(title: String, models: [String])] = [
        ("Claude Code", ["fable-5", "opus-4-8-1m", "opus-4-7-1m", "opus-4-6-1m",
                         "sonnet-5-1m", "sonnet-4-6-1m", "sonnet-4-6", "haiku-4-5"]),
        ("Codex", ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4"]),
        ("Cursor", ["auto", "composer-2.5", "grok-4.5"]),
        ("OpenCode", ["opencode:openrouter/moonshotai/kimi-k2.7-code", "opencode:openrouter/z-ai/glm-5.2"]),
    ]
}

func prettyModel(_ model: String?) -> String {
    guard var m = model else { return "Default" }
    if m.contains(":") || m.contains("/"), let last = m.split(separator: "/").last { m = String(last) }
    return m.split(separator: "-").map { part in
        let p = String(part)
        if p == "1m" { return "1M" }
        if p.lowercased().hasPrefix("gpt") { return p.uppercased() }
        return p.prefix(1).uppercased() + p.dropFirst()
    }
    .joined(separator: " ")
    .replacingOccurrences(of: "4 8", with: "4.8").replacingOccurrences(of: "4 7", with: "4.7")
    .replacingOccurrences(of: "4 6", with: "4.6").replacingOccurrences(of: "4 5", with: "4.5")
    .replacingOccurrences(of: "5 6", with: "5.6").replacingOccurrences(of: "5 5", with: "5.5")
    .replacingOccurrences(of: "5 4", with: "5.4").replacingOccurrences(of: "2 5", with: "2.5")
}

struct DiffStat: Codable {
    let insertions: Int
    let deletions: Int

    var isEmpty: Bool { insertions == 0 && deletions == 0 }
}

// 1470 → "1.4k"
func compactCount(_ n: Int) -> String {
    n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : String(n)
}

struct WorkspaceDiff: Codable {
    let base: String
    let stat: String
    let diff: String
}

struct AgentStatus: Codable {
    let running: Bool
    let activity: String
}

struct ChatMessage: Identifiable, Codable, Hashable {
    let id: String
    let role: String        // user | assistant | tool
    let content: String
    let createdAt: Date
}
