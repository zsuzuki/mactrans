import Foundation

enum TranslationClientError: LocalizedError {
    case invalidURL(String)
    case badStatus(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            "Invalid LM Studio URL: \(value)"
        case .badStatus(let status, let body):
            "LM Studio returned HTTP \(status): \(body)"
        case .emptyResponse:
            "LM Studio returned an empty translation."
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
        guard let url = URL(string: baseURLString) else {
            throw TranslationClientError.invalidURL(baseURLString)
        }

        var request = URLRequest(url: url, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAPIKey.isEmpty {
            request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
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

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw TranslationClientError.badStatus(httpResponse.statusCode, bodyText)
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        let translation = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
