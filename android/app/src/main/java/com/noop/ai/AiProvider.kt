package com.noop.ai

/**
 * AI Coach providers. The user brings their own API key for one of these and the app
 * sends a compact text summary of their metrics + their question to the chosen provider.
 *
 * Provider names are the only branding shown — there is no app-author / model-vendor
 * branding beyond the provider name the user picks.
 *
 * Wire formats are encoded in [AiCoach]; this enum only carries the display name, the
 * default model, the curated list of selectable models, the chat HTTPS endpoint, and the
 * models-list endpoint used to fetch the provider's live catalogue.
 *
 * The [models] list is a sensible, curated starting point — the user can also fetch the
 * provider's live list (merged in at runtime) or type any model id via "Custom…", so the
 * app never has to ship an exhaustive or up-to-date catalogue.
 */
enum class AiProvider(
    val displayName: String,
    val defaultModel: String,
    val models: List<String>,
    val endpoint: String,
    val modelsEndpoint: String,
) {
    OPENAI(
        displayName = "OpenAI",
        defaultModel = "gpt-4o-mini",
        models = listOf(
            "gpt-4o",
            "gpt-4o-mini",
            "gpt-4.1",
            "gpt-4.1-mini",
            "gpt-4.1-nano",
        ),
        endpoint = "https://api.openai.com/v1/chat/completions",
        modelsEndpoint = "https://api.openai.com/v1/models",
    ),
    ANTHROPIC(
        displayName = "Anthropic",
        defaultModel = "claude-sonnet-4-6",
        models = listOf(
            "claude-opus-4-8",
            "claude-sonnet-4-6",
            "claude-haiku-4-5-20251001",
            "claude-3-7-sonnet-latest",
            "claude-3-5-sonnet-latest",
            "claude-3-5-haiku-latest",
            "claude-3-opus-latest",
        ),
        endpoint = "https://api.anthropic.com/v1/messages",
        modelsEndpoint = "https://api.anthropic.com/v1/models",
    ),
    GEMINI(
        displayName = "Google Gemini",
        defaultModel = "gemini-2.5-flash",
        models = listOf(
            "gemini-2.5-pro",
            "gemini-2.5-flash",
            "gemini-2.5-flash-lite",
            "gemini-2.0-flash",
        ),
        // Gemini's chat URL is per-model: AiCoach appends "/{model}:generateContent" at
        // request time, so this is the models BASE, not a complete chat endpoint.
        endpoint = "https://generativelanguage.googleapis.com/v1beta/models",
        modelsEndpoint = "https://generativelanguage.googleapis.com/v1beta/models",
    );

    companion object {
        /** Resolve a provider by its persisted [name], falling back to [OPENAI]. */
        fun fromName(name: String?): AiProvider =
            entries.firstOrNull { it.name == name } ?: OPENAI
    }
}
