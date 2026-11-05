import Foundation

struct SpeechVoice: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String?
    let type: String?
    let languageCode: String?

    enum CodingKeys: String, CodingKey {
        case id, type
        case displayName = "display_name", languageCode = "language_code"
    }

    var title: String {
        let name = displayName.flatMap { $0.isEmpty ? nil : $0 } ?? id
        return [name, languageCode, type].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    func matches(_ search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || "\(title) \(id)".localizedStandardContains(query)
    }
}

enum SpeechVoiceCatalogError: LocalizedError {
    case invalidResponse, pagination

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The voice list response could not be read. Try refreshing the list."
        case .pagination: "The voice list could not be completed. Try refreshing the list."
        }
    }
}

struct SpeechVoiceClient: Sendable {
    private static let liveSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config, delegate: NoSpeechRedirects(), delegateQueue: nil)
    }()
    var session: URLSession = liveSession

    static func request(apiKey: String, pageToken: String? = nil) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.allSatisfy({ (33...126).contains($0) }) else { throw SpeechError.missingAPIKey }
        var url = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/voices")!
        // No type or language filter: include both custom and prebuilt voices.
        url.queryItems = [URLQueryItem(name: "page_size", value: "100")]
        if let pageToken { url.queryItems?.append(URLQueryItem(name: "page_token", value: pageToken)) }
        var request = URLRequest(url: url.url!, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func list(apiKey: String) async throws -> [SpeechVoice] {
        struct Page: Decodable {
            var voices: [SpeechVoice]?
            var next_page_token: String?
        }
        var voices: [SpeechVoice] = []
        var ids = Set<String>()
        var tokens = Set<String>()
        var token: String?
        for _ in 0..<100 {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: Self.request(apiKey: apiKey, pageToken: token))
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw SpeechVoiceCatalogError.invalidResponse }
            guard (200..<300).contains(response.statusCode) else {
                throw SpeechError.httpStatus(response.statusCode,
                    retryAfter: GeminiTTSClient.retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
            }
            guard let page = try? JSONDecoder().decode(Page.self, from: data) else { throw SpeechVoiceCatalogError.invalidResponse }
            for voice in page.voices ?? [] {
                guard !voice.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SpeechVoiceCatalogError.invalidResponse }
                if ids.insert(voice.id).inserted { voices.append(voice) }
            }
            guard let next = page.next_page_token, !next.isEmpty else { return voices }
            guard tokens.insert(next).inserted else { throw SpeechVoiceCatalogError.pagination }
            token = next
        }
        throw SpeechVoiceCatalogError.pagination
    }
}

@MainActor
final class SpeechVoiceCatalog: ObservableObject {
    @Published private(set) var voices: [SpeechVoice] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let fetch: (String) async throws -> [SpeechVoice]

    init(fetch: @escaping (String) async throws -> [SpeechVoice] = { try await SpeechVoiceClient().list(apiKey: $0) }) {
        self.fetch = fetch
    }

    func load(apiKey: String) {
        cancel()
        let current = generation
        isLoading = true
        error = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let fetched = try await fetch(apiKey)
                try Task.checkCancellation()
                guard current == generation else { return }
                voices = fetched
                hasLoaded = true
            } catch {
                guard current == generation, !Task.isCancelled else { return }
                // Never display arbitrary response bodies, URLs or credentials.
                if let safe = error as? SpeechError { self.error = safe.localizedDescription }
                else if let safe = error as? SpeechVoiceCatalogError { self.error = safe.localizedDescription }
                else { self.error = "Could not load voices. Check the connection and try again (code \((error as NSError).code))." }
            }
            guard current == generation else { return }
            isLoading = false
            task = nil
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        isLoading = false
    }

    func invalidate() {
        cancel()
        voices = []
        hasLoaded = false
        error = nil
    }
}
