import Foundation

/// Talks to the local NOOP Codex bridge. The bridge is a loopback OpenAI-compatible shim that
/// invokes the logged-in Codex CLI outside the app sandbox, so NOOP never stores an API key.
struct CodexLocalClient: AIProviderClient {

    func send(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession
    ) async throws -> String {
        var wire: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for m in messages { wire.append(["role": m.role.rawValue, "content": m.content]) }

        let body: [String: Any] = [
            "model": model.isEmpty ? AIProvider.codexLocal.defaultModel : model,
            "messages": wire,
            "max_tokens": 900,
        ]

        var req = URLRequest(url: AIProvider.codexLocal.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await performRequest(req, session: session)
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AICoachError.decode
        }
        return content
    }

    func fetchModels(key: String, session: URLSession) async throws -> [String] {
        var req = URLRequest(url: AIProvider.codexLocal.modelsEndpoint)
        req.httpMethod = "GET"

        let json = try await performRequest(req, session: session)
        guard let list = json["data"] as? [[String: Any]] else {
            return AIProvider.codexLocal.modelOptions
        }
        let ids = list.compactMap { row -> String? in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return id
        }
        return ids.isEmpty ? AIProvider.codexLocal.modelOptions : ids
    }
}
