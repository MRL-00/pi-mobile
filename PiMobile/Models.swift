import Foundation

// Shapes mirror the companion server's JSON API over Pi's session files.

struct Repo: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let defaultBranch: String?
    let activeWorkspaceCount: Int
    // Set client-side after fetching: repo ids are only unique per Mac, so the
    // owning Mac is part of a repo's identity when lists are merged.
    var macId: UUID? = nil
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

    var modelLabel: String { prettyModel(model) }
}

// One picker section per Pi provider; ids are "provider/model" and pass
// straight through to `pi --model`.
struct ModelGroup: Codable, Hashable {
    let title: String
    let models: [String]
}

// The live groups come from the server's /models (Pi's own model catalog).
// This static list is only the fallback before the fetch lands.
enum HarnessModels {
    static let fallback: [ModelGroup] = [
        ModelGroup(title: "anthropic", models: ["anthropic/claude-fable-5", "anthropic/claude-opus-4-8",
                                                "anthropic/claude-sonnet-5", "anthropic/claude-haiku-4-5"]),
        ModelGroup(title: "openai-codex", models: ["openai-codex/gpt-5.6-sol", "openai-codex/gpt-5.5", "openai-codex/gpt-5.4"]),
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

struct FolderListing: Codable {
    let path: String
    let parent: String?
    let dirs: [String]
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
