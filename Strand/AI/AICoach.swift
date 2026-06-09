import Foundation
import Combine
import Security
import WhoopStore

// MARK: - AI Coach (the one networked feature — strictly opt-in, bring-your-own-key)
//
// NOOP is offline by design. This file is the single exception: when the user pastes their OWN
// API key for a provider they choose, NOOP can send a compact text summary of their metrics plus
// their question to that provider and surface coaching advice. Nothing leaves the device until a
// key is set AND a question is asked. We never embed our own key, never auto-send, and only ever
// transmit the small text context built in `buildContext()` + the running chat — no raw streams.
//
// Pure macOS: Foundation + URLSession + Security (Keychain). Compiles on macOS 13, Swift 5.

/// One-line privacy note the UI should display verbatim near the composer / settings.
public let aiCoachPrivacyNote =
    "Private by default: nothing is sent until you add your own key and ask a question — only a short text summary of your metrics goes to the provider you pick."

// MARK: - Provider

/// The remote provider the user opts into. Anonymous: only the provider's own name is shown; no
/// other vendor/author branding. Wire formats are pinned per provider in `AICoachEngine`.
enum AIProvider: String, CaseIterable, Identifiable {
    case chatGPTCodex
    case openAI
    case anthropic

    var id: String { rawValue }

    /// Plain provider name shown in the picker (no extra branding).
    var displayName: String {
        switch self {
        case .chatGPTCodex: return "ChatGPT / Codex"
        case .openAI:       return "OpenAI API"
        case .anthropic:    return "Anthropic"
        }
    }

    /// Model selected by default when this provider is first chosen.
    var defaultModel: String {
        switch self {
        case .chatGPTCodex: return "gpt-5.5"
        case .openAI:       return "gpt-5.4-mini"
        case .anthropic:    return "claude-sonnet-4-6"
        }
    }

    /// Whether this provider uses a pasted API key instead of Codex account auth.
    var usesAPIKey: Bool {
        switch self {
        case .chatGPTCodex: return false
        case .openAI, .anthropic: return true
        }
    }

    /// Models offered in the model picker for this provider. A free-text "Custom…" path in the UI
    /// lets the user pick any id beyond these, and `refreshModels()` can merge the provider's live list.
    var modelOptions: [String] {
        switch self {
        case .chatGPTCodex:
            return [
                "gpt-5.5",
                "gpt-5.4",
                "gpt-5.4-mini",
                "gpt-5.3-codex-spark"
            ]
        case .openAI:
            return [
                "gpt-5.5",
                "gpt-5.4",
                "gpt-5.4-mini",
                "gpt-5.4-nano",
                "chat-latest"
            ]
        case .anthropic:
            return [
                "claude-opus-4-8",
                "claude-sonnet-4-6",
                "claude-haiku-4-5-20251001",
                "claude-3-7-sonnet-latest",
                "claude-3-5-sonnet-latest",
                "claude-3-5-haiku-latest",
                "claude-3-opus-latest"
            ]
        }
    }

    /// The HTTPS endpoint this provider's chat request is POSTed to.
    var endpoint: URL {
        switch self {
        case .chatGPTCodex: return URL(string: "http://127.0.0.1")!
        case .openAI:       return URL(string: "https://api.openai.com/v1/chat/completions")!
        case .anthropic:    return URL(string: "https://api.anthropic.com/v1/messages")!
        }
    }

    /// The modern OpenAI text-generation endpoint. Kept separate because Anthropic still uses
    /// its provider-specific Messages API and OpenAI may fall back to Chat Completions for custom ids.
    var responsesEndpoint: URL? {
        switch self {
        case .chatGPTCodex: return nil
        case .openAI:       return URL(string: "https://api.openai.com/v1/responses")!
        case .anthropic:    return nil
        }
    }

    /// The HTTPS endpoint that lists the provider's available models (GET, authenticated).
    var modelsEndpoint: URL {
        switch self {
        case .chatGPTCodex: return URL(string: "http://127.0.0.1")!
        case .openAI:       return URL(string: "https://api.openai.com/v1/models")!
        case .anthropic:    return URL(string: "https://api.anthropic.com/v1/models")!
        }
    }
}

// MARK: - Chat model

/// One turn in the coaching conversation.
struct ChatMessage: Identifiable, Equatable {
    enum Role: String, Sendable { case user, assistant }
    let id: UUID
    let role: Role
    let text: String

    init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

// MARK: - Secure key storage (Keychain)

/// Keychain Services wrapper for the user's API key. Uses a generic-password item under a fixed
/// service so the key never lands in UserDefaults, a plist, or on disk in the clear.
enum AIKeyStore {
    private static let service = "com.noop.aicoach"
    private static let account = "api-key"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// Store (or replace) the API key. Empty/whitespace input is treated as a clear.
    static func save(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { clear(); return }
        guard let data = trimmed.data(using: .utf8) else { return }

        // Delete any existing item first so we always insert a single, fresh value.
        SecItemDelete(baseQuery as CFDictionary)

        var attrs = baseQuery
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
    }

    /// Read the stored API key, or nil if none is set.
    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8),
              !str.isEmpty else { return nil }
        return str
    }

    /// Remove any stored API key.
    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

// MARK: - Errors

/// User-facing failure reasons mapped to clear, non-crashing messages.
enum AICoachError: LocalizedError {
    case noKey
    case emptyQuestion
    case badKey
    case rateLimited
    case server(Int, String)
    case network(String)
    case decode
    case codexUnavailable(String)
    case codexLoginRequired

    var errorDescription: String? {
        switch self {
        case .noKey:
            return "Add your own API key first to use the coach."
        case .emptyQuestion:
            return "Type a question for the coach."
        case .badKey:
            return "That API key was rejected. Check the key and the provider you selected."
        case .rateLimited:
            return "The provider is rate-limiting requests right now. Wait a moment and try again."
        case .server(let code, let detail):
            let extra = detail.isEmpty ? "" : " — \(detail)"
            return "The provider returned an error (\(code))\(extra)."
        case .network(let detail):
            return "Network problem: \(detail). The coach is the only feature that needs the internet."
        case .decode:
            return "Couldn't read the provider's reply. Try again."
        case .codexUnavailable(let detail):
            return detail
        case .codexLoginRequired:
            return "Sign in with ChatGPT first to use the Codex-backed coach."
        }
    }
}

// MARK: - Engine

/// Drives the AI Coach: holds the chat, the chosen provider/model, the secure key, and performs the
/// networked request. `@MainActor` so all `@Published` mutations are main-thread; the actual HTTP
/// call hops off-main via `URLSession`'s async API and results are applied back on the main actor.
@MainActor
final class AICoachEngine: ObservableObject {

    // Published state the UI binds to.
    @Published var messages: [ChatMessage] = []
    @Published var sending = false
    @Published var errorText: String?
    @Published var provider: AIProvider {
        didSet {
            guard provider != oldValue else { return }
            UserDefaults.standard.set(provider.rawValue, forKey: Self.providerKey)
            // Reset the model list to the new provider's built-in options.
            availableModels = provider.modelOptions
            // Keep the model valid for the newly-selected provider.
            if !provider.modelOptions.contains(model) {
                model = provider.defaultModel
            }
            if provider == .chatGPTCodex {
                Task { await refreshCodexAccount() }
            }
        }
    }
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: Self.modelKey) }
    }
    /// The model ids offered in the picker. Seeded from `provider.modelOptions`, reset when the
    /// provider changes, and optionally extended by `refreshModels()` with the provider's live list.
    @Published var availableModels: [String] = []
    /// Signed-in ChatGPT/Codex account metadata, if this provider is connected.
    @Published var codexAccount: CodexAccount?
    /// ChatGPT/Codex account metadata detected from the user's existing Codex CLI login.
    @Published var codexDetectedAccount: CodexAccount?
    /// Whether NOOP is checking the local Codex CLI for an existing ChatGPT/Codex profile.
    @Published var checkingCodexAccount = false
    /// Explicit permission for the coach to read & transmit the user's biometric data. OFF by
    /// default — until this is true, NO metrics are included in any request (only the question).
    @Published var dataConsent: Bool {
        didSet { UserDefaults.standard.set(dataConsent, forKey: Self.consentKey) }
    }

    private let repo: Repository
    private let session: URLSession

    private static let providerKey = "ai.provider"
    private static let modelKey = "ai.model"
    private static let consentKey = "ai.dataConsent"

    /// The system prompt that frames every request. Anonymous — frames the assistant only as a coach.
    private let systemPrompt = """
    You are an elite, supportive recovery and performance coach with a real training methodology. \
    You may be given a summary of the user's own wearable data (recovery %, day strain 0–21, sleep, \
    HRV, resting heart rate) and recent workouts. Coach using autoregulation:
    • Readiness → prescription: recovery 67–100% = green light to build/push, higher strain is fine; \
    34–66% = maintain, quality over volume, keep it controlled; 0–33% = active recovery only \
    (Zone 2, mobility, extra sleep) and protect against accumulating strain debt.
    • Workout optimisation: progressive overload, polarised ~80/20 intensity, space hard sessions, \
    program deloads/periodisation, and treat sleep as the single biggest recovery lever.
    • Always cite the user's ACTUAL numbers, give a concrete plan (today and the week ahead), and \
    be specific, punchy and motivating — like a coach who knows them.
    If no data is provided, coach generally and invite them to turn on data access for personalised \
    advice. You are NOT a doctor — never diagnose; suggest a professional for genuine health concerns.
    """

    /// Used in place of the metrics context when the user has NOT granted data access.
    private let noConsentNote = """
    NOTE: The user has not granted access to their biometric data. Coach generally and encourage \
    them to enable "Let the coach use my data" for guidance tailored to their real numbers.
    """

    init(repo: Repository, session: URLSession = .shared) {
        self.repo = repo
        self.session = session

        // Restore persisted provider / model (falling back to sane defaults).
        let storedProvider = UserDefaults.standard.string(forKey: Self.providerKey)
            .flatMap(AIProvider.init(rawValue:)) ?? .openAI
        self.provider = storedProvider

        let storedModel = UserDefaults.standard.string(forKey: Self.modelKey)
        // A persisted custom id is honoured even if it's not in the built-in list.
        if let storedModel, !storedModel.isEmpty {
            self.model = storedModel
        } else {
            self.model = storedProvider.defaultModel
        }

        // Seed the picker with the provider's built-in options; include any persisted custom id.
        var seeded = storedProvider.modelOptions
        if let storedModel, !storedModel.isEmpty, !seeded.contains(storedModel) {
            seeded.insert(storedModel, at: 0)
        }
        self.availableModels = seeded

        self.dataConsent = UserDefaults.standard.bool(forKey: Self.consentKey)

        if storedProvider == .chatGPTCodex {
            Task { await refreshCodexAccount() }
        }
    }

    // MARK: Key management

    /// True when the selected provider is connected.
    var hasKey: Bool {
        provider.usesAPIKey ? AIKeyStore.read() != nil : codexAccount != nil
    }

    /// Store the user's pasted key securely. Clears any prior error.
    func setKey(_ key: String) {
        guard provider.usesAPIKey else { return }
        AIKeyStore.save(key)
        errorText = nil
        objectWillChange.send() // `hasKey` is computed; nudge SwiftUI to re-read it.
        // Pull the user's ACTUAL current models from the provider so the picker is never stale.
        Task { await refreshModels() }
    }

    /// Forget the stored key.
    func clearKey() {
        if provider.usesAPIKey {
            AIKeyStore.clear()
        } else {
            codexAccount = nil
        }
        errorText = nil
        objectWillChange.send()
    }

    /// Detects an existing local ChatGPT/Codex profile without connecting Coach automatically.
    func refreshCodexAccount() async {
        guard provider == .chatGPTCodex else { return }
        checkingCodexAccount = true
        defer { checkingCodexAccount = false }
        do {
            let account = try await CodexAppServer.readAccount()
            codexDetectedAccount = account
            if codexAccount != nil {
                codexAccount = account
            }
            errorText = nil
            objectWillChange.send()
            if codexAccount != nil {
                await refreshModels()
            }
        } catch let error as CodexAppServerError {
            codexDetectedAccount = nil
            codexAccount = nil
            errorText = error.errorDescription
        } catch {
            codexDetectedAccount = nil
            codexAccount = nil
            errorText = AICoachError.codexUnavailable(error.localizedDescription).errorDescription
        }
    }

    /// Connects Coach to the detected Codex profile, or starts ChatGPT sign-in when none exists.
    func signInWithCodex() async {
        guard provider == .chatGPTCodex else { return }
        errorText = nil
        sending = true
        defer { sending = false }
        do {
            var account = try await CodexAppServer.readAccount()
            if account == nil {
                account = try await CodexAppServer.signIn()
            }
            codexDetectedAccount = account
            codexAccount = account
            objectWillChange.send()
            if codexAccount != nil {
                await refreshModels()
            } else {
                errorText = AICoachError.codexLoginRequired.errorDescription
            }
        } catch let error as CodexAppServerError {
            errorText = error.errorDescription
        } catch {
            errorText = AICoachError.codexUnavailable(error.localizedDescription).errorDescription
        }
    }

    /// Logs out of the cached Codex profile and starts a fresh ChatGPT/Codex browser sign-in.
    func signInWithDifferentCodexAccount() async {
        guard provider == .chatGPTCodex else { return }
        errorText = nil
        sending = true
        defer { sending = false }
        do {
            try await CodexAppServer.signOut()
            codexDetectedAccount = nil
            codexAccount = nil
            let account = try await CodexAppServer.signIn()
            codexDetectedAccount = account
            codexAccount = account
            objectWillChange.send()
            if codexAccount != nil {
                await refreshModels()
            } else {
                errorText = AICoachError.codexLoginRequired.errorDescription
            }
        } catch let error as CodexAppServerError {
            errorText = error.errorDescription
        } catch {
            errorText = AICoachError.codexUnavailable(error.localizedDescription).errorDescription
        }
    }

    // MARK: Live model list

    /// Set a custom model id (any string). Adds it to the picker if it isn't already listed.
    func setCustomModel(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !availableModels.contains(trimmed) {
            availableModels.insert(trimmed, at: 0)
        }
        model = trimmed
    }

    /// Best-effort: GET the chosen provider's models endpoint with the saved key and merge the
    /// returned ids into `availableModels`. Never crashes; failures land in `errorText` and leave
    /// the existing list intact. Requires a saved key.
    func refreshModels() async {
        if provider == .chatGPTCodex {
            do {
                let discovered = try await CodexAppServer.listModels()
                let builtIn = provider.modelOptions
                let merged = builtIn + Set(discovered).subtracting(builtIn).sorted()
                availableModels = merged.contains(model) ? merged : [model] + merged
                errorText = nil
            } catch let error as CodexAppServerError {
                errorText = error.errorDescription
            } catch {
                errorText = AICoachError.codexUnavailable(error.localizedDescription).errorDescription
            }
            return
        }

        guard let key = AIKeyStore.read() else {
            errorText = AICoachError.noKey.errorDescription
            return
        }
        errorText = nil

        var req = URLRequest(url: provider.modelsEndpoint)
        req.httpMethod = "GET"
        switch provider {
        case .chatGPTCodex:
            return
        case .openAI:
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            errorText = AICoachError.network(error.localizedDescription).errorDescription
            return
        }

        guard let http = response as? HTTPURLResponse else {
            errorText = AICoachError.network("no HTTP response").errorDescription
            return
        }
        switch http.statusCode {
        case 200...299:
            break
        case 401, 403:
            errorText = AICoachError.badKey.errorDescription
            return
        case 429:
            errorText = AICoachError.rateLimited.errorDescription
            return
        default:
            errorText = AICoachError.server(http.statusCode, providerErrorMessage(from: data)).errorDescription
            return
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else {
            errorText = AICoachError.decode.errorDescription
            return
        }

        // Pull ids, applying a light per-provider filter so the list stays relevant.
        let ids: [String] = list.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            switch provider {
            case .chatGPTCodex:
                return id
            case .openAI:
                return (id.hasPrefix("gpt") || id.hasPrefix("o") || id.hasPrefix("chat")) ? id : nil
            case .anthropic:
                return id
            }
        }
        guard !ids.isEmpty else {
            errorText = AICoachError.decode.errorDescription
            return
        }

        // Merge: keep the built-in options on top, append any newly-discovered ids (sorted), and
        // preserve a current custom selection if it isn't otherwise present.
        let builtIn = provider.modelOptions
        let discovered = Set(ids).subtracting(builtIn).sorted()
        var merged = builtIn + discovered
        if !merged.contains(model) {
            merged.insert(model, at: 0)
        }
        availableModels = merged
    }

    // MARK: Sending

    /// Send a question: append it, build the metrics context, call the chosen provider with the
    /// system prompt + context + running history, parse the reply, append it. Never throws/crashes;
    /// failures land in `errorText`.
    func send(_ userText: String) async {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorText = AICoachError.emptyQuestion.errorDescription; return }
        let key = AIKeyStore.read()
        if provider.usesAPIKey, key == nil {
            errorText = AICoachError.noKey.errorDescription
            return
        }
        if provider == .chatGPTCodex, codexAccount == nil {
            errorText = AICoachError.codexLoginRequired.errorDescription
            return
        }

        errorText = nil
        messages.append(ChatMessage(role: .user, text: trimmed))
        sending = true
        defer { sending = false }

        // Build the data context once and prepend it to the FIRST user turn we send. We send the
        // full running history so follow-ups stay coherent; the context only needs to ride the
        // earliest user message.
        // Include the user's data ONLY with explicit consent; otherwise send a note instead of numbers.
        let context = dataConsent ? await buildFullContext() : noConsentNote
        let wire = wireMessages(context: context)

        do {
            let reply = try await callProvider(key: key, messages: wire)
            let clean = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            messages.append(ChatMessage(role: .assistant, text: clean.isEmpty ? "(no reply)" : clean))
        } catch let e as AICoachError {
            errorText = e.errorDescription
        } catch {
            errorText = AICoachError.network(error.localizedDescription).errorDescription
        }
    }

    /// Proactively generate "Today's brief" the first time the Coach opens — readiness + a training
    /// prescription + one recovery tip — without the user typing. Requires a key + data consent.
    func startBriefIfNeeded() async {
        guard hasKey, dataConsent, messages.isEmpty, !sending else { return }
        let key = AIKeyStore.read()
        guard !provider.usesAPIKey || key != nil else { return }
        errorText = nil
        sending = true
        defer { sending = false }

        let context = await buildFullContext()
        let instruction = """
        Based on the data above, give me TODAY'S coaching brief in three short parts: \
        (1) my readiness in one line, citing recovery, HRV and sleep; \
        (2) exactly what training to do today and what to avoid; \
        (3) one specific thing to improve my recovery. Be punchy and motivating.
        """
        let wire: [(role: ChatMessage.Role, content: String)] = [(.user, context + "\n\n---\n\n" + instruction)]
        do {
            let reply = try await callProvider(key: key, messages: wire)
            let clean = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                messages.append(ChatMessage(role: .assistant, text: "Today's brief\n\n" + clean))
            }
        } catch let e as AICoachError {
            errorText = e.errorDescription
        } catch {
            errorText = AICoachError.network(error.localizedDescription).errorDescription
        }
    }

    /// Full data context = the metrics summary + recent workouts. Used when the user has consented.
    func buildFullContext() async -> String {
        var ctx = buildContext()
        ctx += "\n\n" + (await recentWorkoutsBlock())
        return ctx
    }

    /// Dispatch to the user's chosen provider.
    private func callProvider(key: String?,
                              messages: [(role: ChatMessage.Role, content: String)]) async throws -> String {
        switch provider {
        case .chatGPTCodex:
            return try await CodexAppServer.complete(model: model, systemPrompt: systemPrompt, messages: messages)
        case .openAI:
            guard let key else { throw AICoachError.noKey }
            return try await sendOpenAI(key: key, messages: messages)
        case .anthropic:
            guard let key else { throw AICoachError.noKey }
            return try await sendAnthropic(key: key, messages: messages)
        }
    }

    /// The chat as `(role, content)` pairs, with the metrics context prepended to the first user turn.
    private func wireMessages(context: String) -> [(role: ChatMessage.Role, content: String)] {
        var out: [(role: ChatMessage.Role, content: String)] = []
        var contextInjected = false
        for m in messages {
            if m.role == .user && !contextInjected {
                contextInjected = true
                out.append((.user, context + "\n\n---\n\nQuestion: " + m.text))
            } else {
                out.append((m.role, m.text))
            }
        }
        return out
    }

    // MARK: Provider calls

    /// OpenAI Responses API. System prompt is sent as top-level instructions. If a custom/legacy
    /// model rejects Responses, retry once with Chat Completions for compatibility.
    private func sendOpenAI(key: String,
                            messages: [(role: ChatMessage.Role, content: String)]) async throws -> String {
        let input = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        do {
            return try await openAIResponses(key: key, input: input)
        } catch let AICoachError.server(code, detail) where code == 400 || code == 404 {
            let d = detail.lowercased()
            if d.contains("responses") || d.contains("unsupported") || d.contains("model")
                || d.contains("not found") {
                var wire: [[String: Any]] = [["role": "system", "content": systemPrompt]]
                wire.append(contentsOf: input.map { $0 as [String: Any] })
                return try await openAIChat(key: key, wire: wire, modernParams: true)
            }
            throw AICoachError.server(code, detail)
        }
    }

    /// One OpenAI Responses request. This is the preferred API for current reasoning/frontier
    /// models and returns every output_text chunk aggregated into one assistant reply.
    private func openAIResponses(key: String, input: [[String: String]]) async throws -> String {
        guard let endpoint = AIProvider.openAI.responsesEndpoint else { throw AICoachError.decode }
        let body: [String: Any] = [
            "model": model,
            "instructions": systemPrompt,
            "input": input,
            "max_output_tokens": 900
        ]

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await perform(req)
        if let text = json["output_text"] as? String, !text.isEmpty {
            return text
        }

        let chunks = (json["output"] as? [[String: Any]] ?? []).flatMap { item -> [String] in
            guard item["type"] as? String == "message",
                  let content = item["content"] as? [[String: Any]] else { return [] }
            return content.compactMap { part in
                guard part["type"] as? String == "output_text" else { return nil }
                return part["text"] as? String
            }
        }
        guard !chunks.isEmpty else { throw AICoachError.decode }
        return chunks.joined(separator: "\n")
    }

    /// One OpenAI chat request. `modernParams` uses `max_completion_tokens` and drops the custom
    /// temperature — what newer/reasoning models require.
    private func openAIChat(key: String, wire: [[String: Any]], modernParams: Bool) async throws -> String {
        var body: [String: Any] = ["model": model, "messages": wire]
        if modernParams {
            body["max_completion_tokens"] = 900
        } else {
            body["temperature"] = 0.6
            body["max_tokens"] = 900
        }

        var req = URLRequest(url: AIProvider.openAI.endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await perform(req)
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AICoachError.decode
        }
        return content
    }

    /// Anthropic Messages. No system role inside `messages` — the system prompt is a top-level field
    /// and messages strictly alternate user/assistant.
    private func sendAnthropic(key: String,
                               messages: [(role: ChatMessage.Role, content: String)]) async throws -> String {
        var wire: [[String: Any]] = []
        for m in messages { wire.append(["role": m.role.rawValue, "content": m.content]) }

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

        let json = try await perform(req)
        guard let content = json["content"] as? [[String: Any]],
              let first = content.first,
              let text = first["text"] as? String else {
            throw AICoachError.decode
        }
        return text
    }

    /// Shared HTTP execution + status mapping. Returns the decoded top-level JSON object on success.
    private func perform(_ req: URLRequest) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw AICoachError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AICoachError.network("no HTTP response")
        }

        switch http.statusCode {
        case 200...299:
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AICoachError.decode
            }
            return obj
        case 401, 403:
            throw AICoachError.badKey
        case 429:
            throw AICoachError.rateLimited
        default:
            throw AICoachError.server(http.statusCode, providerErrorMessage(from: data))
        }
    }

    /// Best-effort extraction of a human message from a provider error body (shape differs per provider).
    private func providerErrorMessage(from data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
        if let msg = obj["message"] as? String { return msg }
        return ""
    }

    // MARK: - Context builder

    /// Build a compact plain-text summary of the user's recent data: last ~14 days of
    /// recovery/strain/sleep-hours/HRV/restingHR where present, plus 30-day averages, plus a few
    /// recent workouts. Kept well under ~1500 tokens. If there's no data, it says so.
    func buildContext() -> String {
        let days = repo.days // oldest → newest
        var lines: [String] = ["USER BIOMETRIC SUMMARY (the user's own wearable data):"]

        guard !days.isEmpty else {
            return """
            USER BIOMETRIC SUMMARY:
            No wearable data is available yet. Acknowledge this and give general, encouraging guidance \
            while inviting the user to sync their device so future advice can reference real numbers.
            """
        }

        // Last ~14 days, newest first for readability.
        let recent = Array(days.suffix(14)).reversed()
        lines.append("")
        lines.append("Recent days (newest first) — recovery%, strain(0-21), sleep(h), HRV(ms), RHR(bpm):")
        for d in recent {
            lines.append("  " + dayLine(d))
        }

        // 30-day averages.
        let last30 = Array(days.suffix(30))
        lines.append("")
        lines.append("30-day averages:")
        lines.append("  recovery: \(avgInt(last30.compactMap { $0.recovery }))%"
                     + ", strain: \(avgOne(last30.compactMap { $0.strain }))"
                     + ", sleep: \(avgSleepHours(last30))h"
                     + ", HRV: \(avgInt(last30.compactMap { $0.avgHrv })) ms"
                     + ", RHR: \(avgInt(last30.compactMap { $0.restingHr.map(Double.init) })) bpm")

        return lines.joined(separator: "\n")
    }

    /// Append recent workouts to an existing context string. Async (workouts are read from the store),
    /// so callers that want workouts in the context can await this and feed the result to `send`'s
    /// flow via the chat — kept separate so `buildContext()` stays synchronous per the spec.
    func recentWorkoutsBlock(limit: Int = 6) async -> String {
        let rows = await repo.workoutRows(days: 30) // newest first
        guard !rows.isEmpty else { return "Recent workouts: none recorded in the last 30 days." }
        var lines = ["Recent workouts (newest first):"]
        for w in rows.prefix(limit) {
            var parts = ["  \(dateString(w.startTs)) \(w.sport)"]
            if let dur = w.durationS { parts.append("\(Int((dur / 60).rounded())) min") }
            if let s = w.strain { parts.append("strain \(String(format: "%.1f", s))") }
            if let hr = w.avgHr { parts.append("avg HR \(hr)") }
            if let kcal = w.energyKcal { parts.append("\(Int(kcal.rounded())) kcal") }
            if let dist = w.distanceM { parts.append("\(String(format: "%.1f", dist / 1000)) km") }
            lines.append(parts.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Formatting helpers

    private func dayLine(_ d: DailyMetric) -> String {
        var parts: [String] = [d.day + ":"]
        parts.append("rec " + (d.recovery.map { "\(Int($0.rounded()))%" } ?? "—"))
        parts.append("strain " + (d.strain.map { String(format: "%.1f", $0) } ?? "—"))
        parts.append("sleep " + (d.totalSleepMin.map { String(format: "%.1fh", $0 / 60) } ?? "—"))
        parts.append("HRV " + (d.avgHrv.map { "\(Int($0.rounded()))ms" } ?? "—"))
        parts.append("RHR " + (d.restingHr.map { "\($0)bpm" } ?? "—"))
        return parts.joined(separator: ", ")
    }

    private func avgOne(_ xs: [Double]) -> String {
        guard !xs.isEmpty else { return "—" }
        return String(format: "%.1f", xs.reduce(0, +) / Double(xs.count))
    }

    private func avgInt(_ xs: [Double]) -> String {
        guard !xs.isEmpty else { return "—" }
        return "\(Int((xs.reduce(0, +) / Double(xs.count)).rounded()))"
    }

    private func avgSleepHours(_ days: [DailyMetric]) -> String {
        let mins = days.compactMap { $0.totalSleepMin }
        guard !mins.isEmpty else { return "—" }
        return String(format: "%.1f", (mins.reduce(0, +) / Double(mins.count)) / 60)
    }

    private func dateString(_ ts: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}
