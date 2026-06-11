import Foundation

struct AnthropicClient: AIProviderClient {
    
    func send(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession
    ) async throws -> String {
        var wire: [[String: Any]] = []
        for m in messages { wire.append(["role": m.role.rawValue, "content": m.content]) }
        
        // Anthropic: system prompt is a top-level field, not a message role.
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 900,
            "system": systemPrompt,
            "messages": wire
        ]
        
        var req = URLRequest(url: AIProvider.anthropic.endpoint)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let json = try await performRequest(req, session: session)
        guard let content = json["content"] as? [[String: Any]],
              let first = content.first,
              let text = first["text"] as? String else {
            throw AICoachError.decode
        }
        return text
    }
    
    func fetchModels(key: String, session: URLSession) async throws -> [String] {
        var req = URLRequest(url: AIProvider.anthropic.modelsEndpoint)
        req.httpMethod = "GET"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        
        let json = try await performRequest(req, session: session)
        guard let list = json["data"] as? [[String: Any]] else { throw AICoachError.decode }
        return list.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return id
        }
    }
}
