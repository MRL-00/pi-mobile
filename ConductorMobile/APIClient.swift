import Foundation
import Observation

struct MacServer: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var baseURL: String
    var token: String
}

@Observable
final class APIClient {
    var macs: [MacServer] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(macs), forKey: "macs") }
    }
    // The Mac owning whatever repo the user is currently inside. Navigation is a
    // single flow, so one active Mac at a time is enough.
    var activeMac: MacServer?
    // repo id → mac id, filled while listing projects
    var macForRepo: [String: UUID] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: "macs"),
           let saved = try? JSONDecoder().decode([MacServer].self, from: data), !saved.isEmpty {
            macs = saved
        } else {
            // Migrate the single-server settings from earlier versions.
            let url = UserDefaults.standard.string(forKey: "baseURL") ?? "http://127.0.0.1:8940"
            let token = UserDefaults.standard.string(forKey: "token") ?? ""
            macs = [MacServer(name: "My Mac", baseURL: url, token: token)]
        }
        activeMac = macs.first
    }

    func mac(withId id: UUID?) -> MacServer? { macs.first { $0.id == id } ?? macs.first }

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

    func createSession(workspaceId: String) async throws -> ChatSession {
        try decoder.decode(ChatSession.self, from: try await post("/workspaces/\(workspaceId)/sessions"))
    }

    func attachment(sessionId: String, path: String) async throws -> Data {
        guard let mac = activeMac else { throw URLError(.badURL) }
        var comps = URLComponents(string: mac.baseURL + "/sessions/\(sessionId)/attachments")!
        comps.queryItems = [URLQueryItem(name: "path", value: path)]
        var request = URLRequest(url: comps.url!)
        request.setValue("Bearer \(mac.token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }
}
