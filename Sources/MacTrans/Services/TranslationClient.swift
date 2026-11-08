import Foundation

enum TranslationClientError: LocalizedError {
    case invalidURL(String)
    case badStatus(Int, String)
    case emptyResponse
    case unsupportedPLaMoLanguage(String)
    case truncatedTranslation

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            "Invalid LM Studio URL: \(value)"
        case .badStatus(let status, let body):
            "LM Studio returned HTTP \(status): \(body)"
        case .emptyResponse:
            "LM Studio returned an empty translation."
        case .unsupportedPLaMoLanguage(let value):
            "Unsupported PLaMo language: \(value). Use a supported language name or code (for example English/en or Japanese/ja)."
        case .truncatedTranslation:
            "PLaMo translation reached the output token limit. Reduce Max characters in Chunking."
        }
    }
}

struct TranslationClient {
    var baseURLString: String
    var model: String
    var apiKey: String
    var reasoningEffort: String
    var sourceLanguage: String
    var targetLanguage: String

    func translate(_ text: String) async throws -> String {
        let request = try makeRequest(text)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw TranslationClientError.badStatus(httpResponse.statusCode, bodyText)
        }
        return try decodeTranslation(data)
    }

    func makeRequest(_ text: String) throws -> URLRequest {
        guard var components = URLComponents(string: baseURLString),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty else {
            throw TranslationClientError.invalidURL(baseURLString)
        }
        if usesPLaMo {
            let path = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
            if path.hasSuffix("/chat/completions") {
                components.path = String(path.dropLast("/chat/completions".count)) + "/completions"
            } else if path.hasSuffix("/completions") {
                components.path = path
            } else {
                throw TranslationClientError.invalidURL(baseURLString)
            }
        }
        guard let url = components.url else {
            throw TranslationClientError.invalidURL(baseURLString)
        }

        var request = URLRequest(url: url, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAPIKey.isEmpty {
            request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        }

        if usesPLaMo {
            request.httpBody = try JSONEncoder().encode(PLaMoCompletionRequest(
                model: model,
                prompt: PLaMoTranslation.prompt(text: text, source: sourceLanguage, target: targetLanguage),
                // Live transcription chunks are short, but allow expansion into token-heavy languages.
                maxTokens: max(512, min(4096, text.utf8.count * 2))
            ))
            return request
        }

        let body = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: text)
            ],
            temperature: 0.1,
            reasoningEffort: normalizedReasoningEffort,
            reasoningTokens: normalizedReasoningEffort == "none" ? 0 : nil,
            stream: false
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private var usesPLaMo: Bool { PLaMoTranslation.matches(model) }

    func decodeTranslation(_ data: Data) throws -> String {
        let content: String
        if usesPLaMo {
            let choice = try JSONDecoder().decode(PLaMoCompletionResponse.self, from: data).choices.first
            guard choice?.finishReason != "length" else { throw TranslationClientError.truncatedTranslation }
            content = PLaMoTranslation.translationBody(choice?.text ?? "")
        } else {
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            content = decoded.choices.first?.message.content ?? ""
        }
        let translation = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translation.isEmpty else {
            throw TranslationClientError.emptyResponse
        }
        return translation
    }

    private var systemPrompt: String {
        """
        Translate the user's text from \(sourceLanguage) to \(targetLanguage).
        Output only the translation. Do not add explanations, labels, markdown, quotes, or alternatives.
        Preserve meaning, names, numbers, and tone. If the source is fragmented, translate only what is present.
        """
    }

    private var normalizedReasoningEffort: String? {
        let value = reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, value != "default" else { return nil }
        return value
    }
}

private struct ChatRequest: Encodable {
    var model: String
    var messages: [ChatMessage]
    var temperature: Double
    var reasoningEffort: String?
    var reasoningTokens: Int?
    var stream: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case reasoningEffort = "reasoning_effort"
        case reasoningTokens = "reasoning_tokens"
        case stream
    }
}

private struct ChatMessage: Codable {
    var role: String
    var content: String
}

private struct ChatResponse: Decodable {
    var choices: [Choice]

    struct Choice: Decodable {
        var message: ChatMessage
    }
}
