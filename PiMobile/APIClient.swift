import Foundation
import Observation
import Security

struct MacServer: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var baseURL: String
    var token: String

    // Tokens live in the Keychain, not the UserDefaults blob. Decoding still
    // reads `token` if present so pre-Keychain saves migrate cleanly.
    private enum CodingKeys: String, CodingKey { case id, name, baseURL, token }

    init(id: UUID = UUID(), name: String, baseURL: String, token: String) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.token = token
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(baseURL, forKey: .baseURL)
    }
}

enum TokenStore {
    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "pi-mobile.mac-token",
         kSecAttrAccount as String: id.uuidString]
    }

    static func set(_ token: String, for id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
        guard !token.isEmpty else { return }
        var attrs = query(id)
        attrs[kSecValueData as String] = Data(token.utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func get(for id: UUID) -> String? {
        var attrs = query(id)
        attrs[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(attrs as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum APIError: LocalizedError {
    case badURL
    case server(status: Int, message: String)
    case macOffline

    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid server URL"
        case .server(_, let message): return message
        case .macOffline:
            return "Couldn't reach that Mac. Make sure the companion server is running and you're on the same network (or Tailscale)."
        }
    }
}

@Observable
final class APIClient {
    private static let activeMacIDKey = "activeMacID"

    var macs: [MacServer] {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(macs), forKey: "macs")
            for mac in macs { TokenStore.set(mac.token, for: mac.id) }
        }
    }
    // The Mac owning whatever repo the user is currently inside. Navigation is a
    // single flow, so one active Mac at a time is enough.
    var activeMac: MacServer? {
        didSet {
            if oldValue?.id != activeMac?.id {
                modelGroups = nil
                skills = []
            }
            if let activeMac {
                UserDefaults.standard.set(activeMac.id.uuidString, forKey: Self.activeMacIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.activeMacIDKey)
            }
        }
    }
    // Picker groups from the active Mac's /models; nil until fetched (views fall
    // back to HarnessModels.fallback). Cleared on Mac switch so one Mac's models
    // never show for another.
    var modelGroups: [ModelGroup]?
    // Installed skills from the active Mac's pi (`/skills`); empty until fetched.
    var skills: [SkillInfo] = []

    /// Set after a QR pair attempt so the home screen can show success or failure.
    var pairingNotice: String?

    /// Last model the user picked on this phone — reused for new sessions.
    var lastUsedModel: String? {
        get { UserDefaults.standard.string(forKey: "lastUsedModel") }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: "lastUsedModel")
            } else {
                UserDefaults.standard.removeObject(forKey: "lastUsedModel")
            }
        }
    }

    /// Optional last thinking level paired with lastUsedModel.
    var lastUsedThinking: String? {
        get { UserDefaults.standard.string(forKey: "lastUsedThinking") }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: "lastUsedThinking")
            } else {
                UserDefaults.standard.removeObject(forKey: "lastUsedThinking")
            }
        }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: "macs"),
           var saved = try? JSONDecoder().decode([MacServer].self, from: data), !saved.isEmpty {
            for i in saved.indices {
                // Keychain wins; a decoded token means a pre-Keychain save to migrate.
                if let token = TokenStore.get(for: saved[i].id) {
                    saved[i].token = token
                } else if !saved[i].token.isEmpty {
                    TokenStore.set(saved[i].token, for: saved[i].id)
                }
            }
            macs = saved
            // Re-save so any legacy plaintext token is dropped from UserDefaults.
            UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: "macs")
        } else {
            // Migrate the single-server settings from earlier versions.
            let url = UserDefaults.standard.string(forKey: "baseURL") ?? "http://127.0.0.1:8940"
            let token = UserDefaults.standard.string(forKey: "token") ?? ""
            let mac = MacServer(name: "My Mac", baseURL: url, token: token)
            TokenStore.set(token, for: mac.id)
            UserDefaults.standard.removeObject(forKey: "token")
            UserDefaults.standard.set(try? JSONEncoder().encode([mac]), forKey: "macs")
            macs = [mac]
        }
        let savedActiveMacID = UserDefaults.standard.string(forKey: Self.activeMacIDKey).flatMap(UUID.init)
        activeMac = macs.first { $0.id == savedActiveMacID } ?? macs.first
    }

    func mac(withId id: UUID?) -> MacServer? { macs.first { $0.id == id } ?? macs.first }

    /// True when the companion answers `GET /repos` with this Mac's address + token.
    func isOnline(_ mac: MacServer) async -> Bool {
        (try? await repos(on: mac)) != nil
    }

    // From the pairing QR the server prints (or the Add Mac form): probe the
    // companion first, then update the Mac with this address (or a
    // placeholder-token one), else add a new entry. Offline Macs are refused.
    @discardableResult
    func pair(name: String, baseURL: String, token: String) async throws -> MacServer {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let probe = MacServer(name: name, baseURL: trimmedURL, token: trimmedToken)
        guard await isOnline(probe) else { throw APIError.macOffline }

        if let i = macs.firstIndex(where: { $0.baseURL == trimmedURL }) {
            macs[i].name = name
            macs[i].token = trimmedToken
            activeMac = macs[i]
            return macs[i]
        } else {
            macs.append(probe)
            activeMac = probe
            return probe
        }
    }

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func get<T: Decodable>(_ path: String, on mac: MacServer? = nil) async throws -> T {
        guard let mac = mac ?? activeMac, let url = URL(string: mac.baseURL + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(mac.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try decoder.decode(T.self, from: data)
    }

    private func post(
        _ path: String,
        on requestedMac: MacServer? = nil,
        body: some Encodable,
        timeoutInterval: TimeInterval = 60
    ) async throws -> Data {
        guard let mac = requestedMac ?? activeMac,
              let url = URL(string: mac.baseURL + path) else { throw APIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutInterval
        request.setValue("Bearer \(mac.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Request bodies stay camelCase to match the companion server's JSON.
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
                ?? String(data: data, encoding: .utf8)
                ?? "Request failed (\(http.statusCode))"
            throw APIError.server(status: http.statusCode, message: message)
        }
        return data
    }

    private func post(_ path: String) async throws -> Data {
        try await post(path, body: [String: String]())
    }

    func repos(on mac: MacServer) async throws -> [Repo] { try await get("/repos", on: mac) }
    func piVersion(on mac: MacServer) async throws -> PiVersionInfo { try await get("/pi-version", on: mac) }
    func updatePi(on mac: MacServer) async throws -> PiVersionInfo {
        let data = try await post(
            "/pi-update",
            on: mac,
            body: [String: String](),
            timeoutInterval: 180
        )
        return try decoder.decode(PiVersionInfo.self, from: data)
    }

    func loadModelGroups() async {
        // Keep the last good list on failure (older server without /models, offline).
        guard let mac = activeMac else { return }
        if let groups: [ModelGroup] = try? await get("/models", on: mac), !groups.isEmpty,
           activeMac?.id == mac.id {
            modelGroups = groups
        }
    }

    func loadSkills() async {
        guard let mac = activeMac else { return }
        if let list: [SkillInfo] = try? await get("/skills", on: mac),
           activeMac?.id == mac.id {
            skills = list
        }
    }

    func rememberModel(_ model: String?, thinking: String?) {
        if let model, !model.isEmpty { lastUsedModel = model }
        lastUsedThinking = thinking
    }

    func workspaces(repoId: String) async throws -> [Workspace] { try await get("/repos/\(repoId)/workspaces") }
    func workspace(_ id: String) async throws -> Workspace { try await get("/workspaces/\(id)") }
    func sessions(workspaceId: String) async throws -> [ChatSession] { try await get("/workspaces/\(workspaceId)/sessions") }
    func messages(sessionId: String) async throws -> [ChatMessage] { try await get("/sessions/\(sessionId)/messages") }
    func status(sessionId: String) async throws -> AgentStatus { try await get("/sessions/\(sessionId)/status") }
    func diff(workspaceId: String) async throws -> WorkspaceDiff { try await get("/workspaces/\(workspaceId)/diff") }
    func diffStat(workspaceId: String) async throws -> DiffStat { try await get("/workspaces/\(workspaceId)/diffstat") }

    struct SendBody: Encodable {
        var text: String
        var model: String?
        var thinking: String?
        var approvalMode: String?
        var images: [PromptImage]?
    }

    func send(
        sessionId: String,
        text: String,
        model: String? = nil,
        thinking: String? = nil,
        approvalMode: String? = nil,
        images: [PromptImage]? = nil
    ) async throws {
        let body = SendBody(
            text: text,
            model: model,
            thinking: thinking,
            approvalMode: approvalMode,
            images: images?.isEmpty == false ? images : nil
        )
        _ = try await post("/sessions/\(sessionId)/send", body: body)
    }

    func stop(sessionId: String) async throws { _ = try await post("/sessions/\(sessionId)/stop") }

    struct UIResponseBody: Encodable {
        var id: String
        var confirmed: Bool?
        var value: String?
        var cancelled: Bool?
    }

    func respondUI(sessionId: String, id: String, confirmed: Bool? = nil, value: String? = nil, cancelled: Bool? = nil) async throws {
        _ = try await post(
            "/sessions/\(sessionId)/ui-response",
            body: UIResponseBody(id: id, confirmed: confirmed, value: value, cancelled: cancelled)
        )
    }

    struct ApprovalExtensionStatus: Codable {
        let installed: Bool
    }

    func approvalExtensionStatus() async throws -> ApprovalExtensionStatus {
        try await get("/approval-extension")
    }

    func installApprovalExtension() async throws {
        _ = try await post("/approval-extension/install")
    }

    private func delete(_ path: String) async throws {
        guard let mac = activeMac, let url = URL(string: mac.baseURL + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(mac.token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }

    func deleteSession(_ id: String) async throws { try await delete("/sessions/\(id)") }
    func deleteWorkspace(_ id: String) async throws { try await delete("/workspaces/\(id)") }

    func addProject(path: String) async throws {
        _ = try await post("/projects", body: ["path": path])
    }

    func browse(path: String?) async throws -> FolderListing {
        var p = "/browse"
        if let path, let enc = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            p += "?path=\(enc)"
        }
        return try await get(p)
    }

    func createWorkspace(repoId: String) async throws -> Workspace {
        try decoder.decode(Workspace.self, from: try await post("/repos/\(repoId)/workspaces"))
    }

    func createSession(workspaceId: String) async throws -> ChatSession {
        try decoder.decode(ChatSession.self, from: try await post("/workspaces/\(workspaceId)/sessions"))
    }

    func attachment(sessionId: String, path: String) async throws -> Data {
        guard let mac = activeMac,
              var comps = URLComponents(string: mac.baseURL + "/sessions/\(sessionId)/attachments") else { throw URLError(.badURL) }
        comps.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = comps.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(mac.token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }
}
