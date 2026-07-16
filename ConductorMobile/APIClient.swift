import Foundation
import Observation

@Observable
final class APIClient {
    // Mac companion server address (e.g. Tailscale hostname). Editable in Settings.
    var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: "baseURL") }
    }
    var token: String {
        didSet { UserDefaults.standard.set(token, forKey: "token") }
    }

    init() {
        baseURL = UserDefaults.standard.string(forKey: "baseURL") ?? "http://127.0.0.1:8940"
        token = UserDefaults.standard.string(forKey: "token") ?? ""
    }

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func get<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: baseURL + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try decoder.decode(T.self, from: data)
    }

    private func post(_ path: String, body: [String: String] = [:]) async throws {
        guard let url = URL(string: baseURL + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }

    func repos() async throws -> [Repo] { try await get("/repos") }
    func workspaces(repoId: String) async throws -> [Workspace] { try await get("/repos/\(repoId)/workspaces") }
    func sessions(workspaceId: String) async throws -> [ChatSession] { try await get("/workspaces/\(workspaceId)/sessions") }
    func messages(sessionId: String) async throws -> [ChatMessage] { try await get("/sessions/\(sessionId)/messages") }
    func createSession(workspaceId: String) async throws -> ChatSession {
        guard let url = URL(string: baseURL + "/workspaces/\(workspaceId)/sessions") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try decoder.decode(ChatSession.self, from: data)
    }

    func diff(workspaceId: String) async throws -> WorkspaceDiff { try await get("/workspaces/\(workspaceId)/diff") }
    func diffStat(workspaceId: String) async throws -> DiffStat { try await get("/workspaces/\(workspaceId)/diffstat") }

    func send(sessionId: String, text: String, model: String? = nil) async throws {
        var body = ["text": text]
        if let model { body["model"] = model }
        try await post("/sessions/\(sessionId)/send", body: body)
    }
    func stop(sessionId: String) async throws { try await post("/sessions/\(sessionId)/stop") }
    func status(sessionId: String) async throws -> AgentStatus { try await get("/sessions/\(sessionId)/status") }

    func attachment(sessionId: String, path: String) async throws -> Data {
        var comps = URLComponents(string: baseURL + "/sessions/\(sessionId)/attachments")!
        comps.queryItems = [URLQueryItem(name: "path", value: path)]
        var request = URLRequest(url: comps.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }
}
