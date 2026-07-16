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

    // "opus-4-8-1m" → "Opus 4.8 1M", "grok-4.5" → "Grok 4.5", "gpt-5.6-sol" → "GPT-5.6 Sol"
    var modelLabel: String {
        guard var m = model else { return "Default" }
        if let last = m.split(separator: "/").last, m.contains(":") || m.contains("/") { m = String(last) }
        return m.split(separator: "-").map { part in
            let p = String(part)
            if p == "1m" { return "1M" }
            if p.lowercased().hasPrefix("gpt") { return p.uppercased() }
            if p.first?.isNumber == true { return p.replacingOccurrences(of: "-", with: ".") }
            return p.prefix(1).uppercased() + p.dropFirst()
        }
        .joined(separator: " ")
        .replacingOccurrences(of: "4 8", with: "4.8").replacingOccurrences(of: "4 7", with: "4.7")
        .replacingOccurrences(of: "4 6", with: "4.6").replacingOccurrences(of: "4 5", with: "4.5")
        .replacingOccurrences(of: "5 6", with: "5.6").replacingOccurrences(of: "5 5", with: "5.5")
        .replacingOccurrences(of: "2 5", with: "2.5")
    }
}

// Claude Code group as shown in Conductor desktop's model picker.
// Raw values are Claude Code CLI --model ids ("[1m]" = 1M context variant).
// "Default" (nil) keeps whatever the session already uses.
// ponytail: Codex/Cursor/OpenCode groups omitted — the server can only drive claude.
enum PickableModel: String, CaseIterable, Identifiable {
    case fable = "claude-fable-5"
    case opus48_1m = "claude-opus-4-8[1m]"
    case opus47_1m = "claude-opus-4-7[1m]"
    case opus46_1m = "claude-opus-4-6[1m]"
    case sonnet5_1m = "claude-sonnet-5[1m]"
    case sonnet46_1m = "claude-sonnet-4-6[1m]"
    case sonnet46 = "claude-sonnet-4-6"
    case haiku = "claude-haiku-4-5"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .fable: "Fable 5"
        case .opus48_1m: "Opus 4.8 1M"
        case .opus47_1m: "Opus 4.7 1M"
        case .opus46_1m: "Opus 4.6 1M"
        case .sonnet5_1m: "Sonnet 5 1M"
        case .sonnet46_1m: "Sonnet 4.6 1M"
        case .sonnet46: "Sonnet 4.6"
        case .haiku: "Haiku 4.5"
        }
    }
}

// Shown in the picker for parity with Conductor desktop, but not selectable:
// the companion server only drives the claude CLI. Enabling these is phase 3.
enum DesktopOnlyModels {
    static let groups: [(title: String, models: [String])] = [
        ("Codex", ["GPT-5.6 Sol", "GPT-5.6 Terra", "GPT-5.6 Luna", "GPT-5.5", "GPT-5.4"]),
        ("Cursor", ["Auto", "Composer 2.5", "Grok 4.5"]),
        ("OpenCode", ["openrouter/moonshotai/kimi-k2.7-code", "openrouter/z-ai/glm-5.2"]),
    ]
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
