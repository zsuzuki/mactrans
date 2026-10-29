import Foundation

struct SpeechConfiguration: Sendable {
    var apiKey: String
    var model: String = "gemini-3.8-flash-tts"
    var voiceName: String
}

enum SpeechError: LocalizedError {
    case missingAPIKey, missingModel, missingVoice, invalidAudio, inputTooLarge, queueFull
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Gemini TTS: enter a valid Gemini API key in Settings."
        case .missingModel: "Gemini TTS: enter a model in Settings."
        case .missingVoice: "Gemini TTS: enter a voice ID or name in Settings."
        case .invalidAudio: "Gemini TTS did not return valid WAV audio."
        case .inputTooLarge: "Gemini TTS: a text character exceeds the app's speech chunk size."
        case .queueFull: "Speech queue is full. The newest translation was not queued; use Stop Speech to clear the backlog."
        case .httpStatus(let code):
            switch code {
            case 400: "Gemini TTS: invalid request (HTTP 400). Check the model, voice and text."
            case 401, 403: "Gemini TTS: access denied (HTTP \(code)). Check the Gemini API key and project permissions."
            case 404: "Gemini TTS: model or voice not found (HTTP 404). Check the model, voice ID and project."
            case 429: "Gemini TTS: quota exceeded (HTTP 429). Try again later."
            default: "Gemini TTS returned HTTP \(code)."
            }
        }
    }
}

struct GeminiTTSClient: Sendable {
    private static let liveSession = URLSession(configuration: .ephemeral, delegate: NoSpeechRedirects(), delegateQueue: nil)
    var session: URLSession = liveSession

    func synthesize(_ text: String, configuration: SpeechConfiguration) async throws -> Data {
        let request = try Self.request(text, configuration: configuration)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw SpeechError.invalidAudio }
        guard (200..<300).contains(response.statusCode) else {
            // Do not surface response bodies that may echo the key or translated text.
            throw SpeechError.httpStatus(response.statusCode)
        }
        return try Self.decodeAudio(data)
    }

    static func decodeAudio(_ data: Data) throws -> Data {
        guard let result = try? JSONDecoder().decode(Response.self, from: data),
              let block = result.steps.filter({ $0.type == "model_output" })
                .flatMap({ $0.content ?? [] }).last(where: { $0.type == "audio" }),
              block.mime_type == nil || block.mime_type == "audio/wav" || block.mime_type == "audio/x-wav",
              let encoded = block.data, let audio = Data(base64Encoded: encoded),
              audio.count >= 44,
              audio.prefix(4) == Data("RIFF".utf8),
              audio[8..<12] == Data("WAVE".utf8) else {
            throw SpeechError.invalidAudio
        }
        return audio
    }

    static func request(_ text: String, configuration: SpeechConfiguration) throws -> URLRequest {
        let key = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = configuration.voiceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.allSatisfy({ (33...126).contains($0) }) else { throw SpeechError.missingAPIKey }
        guard !model.isEmpty else { throw SpeechError.missingModel }
        guard !voice.isEmpty else { throw SpeechError.missingVoice }
        guard text.utf8.count <= 5_000 else { throw SpeechError.inputTooLarge }
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        // Match gemini_tts.py: verbatim text, explicit WAV, no stored interaction.
        request.httpBody = try JSONEncoder().encode(Request(
            model: model,
            input: [.init(content: [.init(text: text)])],
            generation_config: .init(speech_config: [.init(voice: voice)])
        ))
        return request
    }

    // App-side bound for long translations; not a claim about Gemini's API limit.
    static func chunks(_ text: String, byteLimit: Int = 5_000) throws -> [String] {
        var result: [String] = []
        var chunk = ""
        var byteCount = 0
        for character in text {
            let count = String(character).utf8.count
            guard count <= byteLimit else { throw SpeechError.inputTooLarge }
            if byteCount + count > byteLimit {
                result.append(chunk)
                chunk = ""
                byteCount = 0
            }
            chunk.append(character)
            byteCount += count
        }
        if !chunk.isEmpty { result.append(chunk) }
        return result
    }

    private struct Request: Encodable {
        struct Content: Encodable { var type = "text"; var text: String }
        struct Input: Encodable { var type = "user_input"; var content: [Content] }
        struct Voice: Encodable { var voice: String }
        struct GenerationConfig: Encodable { var speech_config: [Voice] }
        struct ResponseFormat: Encodable { var type = "audio"; var mime_type = "audio/wav" }
        var model: String
        var input: [Input]
        var response_format = ResponseFormat()
        var generation_config: GenerationConfig
        var store = false
        var stream = false
    }
    private struct Response: Decodable {
        struct Content: Decodable { var type: String; var data: String?; var mime_type: String? }
        struct Step: Decodable { var type: String; var content: [Content]? }
        var steps: [Step]
    }
}

private final class NoSpeechRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
