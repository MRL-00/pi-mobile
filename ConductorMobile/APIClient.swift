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
         kSecAttrService as String: "conductor-mobile.mac-token",
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

@Observable
final class APIClient {
    var macs: [MacServer] {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(macs), forKey: "macs")
            for mac in macs { TokenStore.set(mac.token, for: mac.id) }
        }
    }
    // The Mac owning whatever repo the user is currently inside. Navigation is a
    // single flow, so one active Mac at a time is enough.
    var activeMac: MacServer?
    // Picker groups from the active Mac's /models; nil until fetched (views fall
    // back to HarnessModels.fallback).
    var modelGroups: [ModelGroup]?

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
        activeMac = macs.first
    }

    func mac(withId id: UUID?) -> MacServer? { macs.first { $0.id == id } ?? macs.first }

    // From the pairing QR the server prints: update the Mac with this address
    // (or a placeholder-token one), else add a new entry.
    func pair(name: String, baseURL: String, token: String) {
        if let i = macs.firstIndex(where: { $0.baseURL == baseURL }) {
            macs[i].name = name
            macs[i].token = token
        } else {
            macs.append(MacServer(name: name, baseURL: baseURL, token: token))
        }
        activeMac = macs.first { $0.baseURL == baseURL }
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

    private func post(_ path: String, body: [String: String] = [:]) async throws -> Data {
        guard let mac = activeMac, let url = URL(string: mac.baseURL + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(mac.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    func repos(on mac: MacServer) async throws -> [Repo] { try await get("/repos", on: mac) }

    func loadModelGroups() async {
        // Keep the last good list on failure (older server without /models, offline).
        if let groups: [ModelGroup] = try? await get("/models"), !groups.isEmpty {
            modelGroups = groups
        }
    }

    func workspaces(repoId: String) async throws -> [Workspace] { try await get("/repos/\(repoId)/workspaces") }
    func sessions(workspaceId: String) async throws -> [ChatSession] { try await get("/workspaces/\(workspaceId)/sessions") }
    func messages(sessionId: String) async throws -> [ChatMessage] { try await get("/sessions/\(sessionId)/messages") }
    func status(sessionId: String) async throws -> AgentStatus { try await get("/sessions/\(sessionId)/status") }
    func diff(workspaceId: String) async throws -> WorkspaceDiff { try await get("/workspaces/\(workspaceId)/diff") }
    func diffStat(workspaceId: String) async throws -> DiffStat { try await get("/workspaces/\(workspaceId)/diffstat") }

    func send(sessionId: String, text: String, model: String? = nil) async throws {
        var body = ["text": text]
        if let model { body["model"] = model }
        _ = try await post("/sessions/\(sessionId)/send", body: body)
    }

    func stop(sessionId: String) async throws { _ = try await post("/sessions/\(sessionId)/stop") }

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
