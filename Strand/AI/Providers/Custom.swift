import Foundation

/// A generic OpenAI-compatible provider pointed at a user-set base URL — e.g. a local LLM server such
/// as Ollama, LM Studio or llama.cpp (`http://localhost:11434/v1`), or any self-hosted gateway. Speaks
/// the OpenAI chat-completions wire format against `AIProvider.custom` endpoints. The API key is
/// optional — local servers usually need none — so the `Authorization` header is sent only when set.
struct CustomClient: AIProviderClient {

    func send(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession
    ) async throws -> String {
        var wire: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for m in messages { wire.append(["role": m.role.rawValue, "content": m.content]) }

        // Standard params first. Some OpenAI-compatible servers (reasoning models behind a gateway)
        // reject `temperature`/`max_tokens` and want `max_completion_tokens`; retry on that 400.
        do {
            return try await chat(key: key, model: model, wire: wire, modernParams: false, session: session)
        } catch let AICoachError.server(code, detail) where code == 400 {
            let d = detail.lowercased()
            if d.contains("max_completion_tokens") || d.contains("max_tokens")
                || d.contains("temperature") || d.contains("unsupported") {
                return try await chat(key: key, model: model, wire: wire, modernParams: true, session: session)
            }
            throw AICoachError.server(code, detail)
        }
    }

    /// Appended to a reply when the server stopped early because it ran out of context window.
    /// Local OpenAI-compatible servers (notably Ollama, which defaults to a 2048-token window and
    /// IGNORES `num_ctx` on the `/v1` endpoint) truncate silently — no error, the text just stops
    /// mid-sentence. We can't raise the window over the OpenAI wire format, so we make the cutoff
    /// visible and tell the user exactly how to fix it.
    static let truncationNote = "\n\n---\n*Reply cut off: the model hit its context-window limit. "
        + "On a local server like Ollama (default 2048 tokens), raise it — create a Modelfile with "
        + "`PARAMETER num_ctx 8192` and select that model, or set `OLLAMA_CONTEXT_LENGTH=8192` and "
        + "relaunch Ollama — then ask again.*"

    /// Pure: unwrap an OpenAI-compatible chat-completions body into the assistant text. Appends
    /// `truncationNote` when the server stopped early (`finish_reason == "length"`) so a context-
    /// window cutoff is never silent. No network — unit-tested.
    func parseChatContent(_ json: [String: Any]) throws -> String {
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AICoachError.decode
        }
        if (first["finish_reason"] as? String)?.lowercased() == "length" {
            return content + Self.truncationNote
        }
        return content
    }

    func fetchModels(key: String, session: URLSession) async throws -> [String] {
        var req = URLRequest(url: AIProvider.custom.modelsEndpoint)
        req.httpMethod = "GET"
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }

        return parseModels(try await performRequest(req, session: session))
    }

    /// Pure: unwrap an OpenAI-compatible `/models` body into ids. Unlike OpenAI we keep *all* ids —
    /// a local server names models freely (`llama3.1`, `qwen2.5`, …). No network — unit-tested.
    func parseModels(_ json: [String: Any]) -> [String] {
        guard let list = json["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return id
        }
    }

    // MARK: Private

    /// `modernParams`: use `max_completion_tokens`, drop `temperature` — for gateways fronting
    /// reasoning models. The `Authorization` header is omitted when `key` is empty (local servers).
    private func chat(
        key: String,
        model: String,
        wire: [[String: Any]],
        modernParams: Bool,
        session: URLSession
    ) async throws -> String {
        var body: [String: Any] = ["model": model, "messages": wire]
        if modernParams {
            body["max_completion_tokens"] = 900
        } else {
            body["temperature"] = 0.6
            body["max_tokens"] = 900
        }

        var req = URLRequest(url: AIProvider.custom.endpoint)
        req.httpMethod = "POST"
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await performRequest(req, session: session)
        return try parseChatContent(json)
    }
}
