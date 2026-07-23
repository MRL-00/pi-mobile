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
    var status: String      // not-started | in-progress | done (derived live on server + client)
    let unread: Bool
    let lastMessageSnippet: String?
    let updatedAt: Date
}

struct SkillInfo: Identifiable, Codable, Hashable {
    let name: String
    let description: String
    let command: String     // "/skill:name" for Pi RPC prompt expansion

    var id: String { name }
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
struct ModelInfo: Codable, Hashable, Identifiable {
    let id: String
    let thinking: Bool
    let images: Bool
    /// Pi thinking levels this model actually accepts (empty → hide thinking UI).
    let thinkingLevels: [String]

    var supportsThinking: Bool { thinking && !thinkingLevels.isEmpty }

    init(id: String, thinking: Bool = false, images: Bool = true, thinkingLevels: [String] = []) {
        self.id = id
        self.thinking = thinking
        self.images = images
        self.thinkingLevels = thinkingLevels
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        images = try c.decodeIfPresent(Bool.self, forKey: .images) ?? true
        let levels = try c.decodeIfPresent([String].self, forKey: .thinkingLevels) ?? []
        if !levels.isEmpty {
            thinkingLevels = levels
            thinking = try c.decodeIfPresent(Bool.self, forKey: .thinking) ?? true
        } else {
            // Legacy servers only sent a boolean — don't invent a full level list.
            thinking = try c.decodeIfPresent(Bool.self, forKey: .thinking) ?? false
            thinkingLevels = thinking ? ["off", "minimal", "low", "medium", "high"] : []
        }
    }
}

struct ModelGroup: Codable, Hashable {
    let title: String
    let models: [ModelInfo]

    init(title: String, models: [ModelInfo]) {
        self.title = title
        self.models = models
    }

    // Accept both the new [{id,thinking,images}] shape and the legacy [string] shape
    // so an older companion server still populates the full catalog.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        if let infos = try? c.decode([ModelInfo].self, forKey: .models) {
            models = infos
        } else if let ids = try? c.decode([String].self, forKey: .models) {
            models = ids.map { ModelInfo(id: $0) }
        } else {
            models = []
        }
    }
}

enum ThinkingLevel: String, CaseIterable, Identifiable {
    case off, minimal, low, medium, high, xhigh, max
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "XHigh"
        case .max: return "Max"
        }
    }
}

enum ApprovalMode: String, CaseIterable, Identifiable {
    case auto, ask
    var id: String { rawValue }
    var label: String { self == .auto ? "Auto" : "Ask" }
}

// The live groups come from the server's /models (Pi's own model catalog).
// This static list is only the fallback before the fetch lands.
enum HarnessModels {
    static let fallback: [ModelGroup] = [
        ModelGroup(title: "anthropic", models: [
            ModelInfo(id: "anthropic/claude-fable-5", thinking: true,
                      thinkingLevels: ["minimal", "low", "medium", "high", "xhigh", "max"]),
            ModelInfo(id: "anthropic/claude-opus-4-8", thinking: true,
                      thinkingLevels: ["off", "minimal", "low", "medium", "high", "max"]),
            ModelInfo(id: "anthropic/claude-sonnet-5", thinking: true,
                      thinkingLevels: ["off", "minimal", "low", "medium", "high", "xhigh", "max"]),
            ModelInfo(id: "anthropic/claude-haiku-4-5", thinking: true,
                      thinkingLevels: ["off", "minimal", "low", "medium", "high"]),
        ]),
        ModelGroup(title: "openai-codex", models: [
            ModelInfo(id: "openai-codex/gpt-5.6-sol", thinking: true,
                      thinkingLevels: ["off", "low", "medium", "high", "xhigh", "max"]),
            ModelInfo(id: "openai-codex/gpt-5.5", thinking: true,
                      thinkingLevels: ["off", "low", "medium", "high", "xhigh"]),
            ModelInfo(id: "openai-codex/gpt-5.4", thinking: true,
                      thinkingLevels: ["off", "low", "medium", "high", "xhigh"]),
        ]),
    ]

    static func info(for id: String?, in groups: [ModelGroup]?) -> ModelInfo? {
        guard let id else { return nil }
        for g in groups ?? fallback {
            if let m = g.models.first(where: { $0.id == id }) { return m }
        }
        return nil
    }
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

struct PendingUI: Codable, Hashable {
    let id: String
    let method: String
    let title: String?
    let message: String?
    let options: [String]?
}

struct AgentStatus: Codable {
    let running: Bool
    let activity: String
    var pendingUI: PendingUI? = nil
}

struct PromptImage: Codable, Hashable {
    let data: String      // base64
    let mimeType: String
}

// From the companion's /pi-version — compares `pi --version` to pi.dev.
struct PiVersionInfo: Codable, Hashable {
    let current: String?
    let latest: String?
    let updateAvailable: Bool
    let updateCommand: String
}

struct ChatMessage: Identifiable, Codable, Hashable {
    let id: String
    let role: String        // user | assistant | tool
    let content: String
    let createdAt: Date
}
