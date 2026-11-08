import Foundation

/// PFN recommends raw PFML3 via Completions for application integrations.
/// https://huggingface.co/pfnet/plamo-3-translate-31b-MLX-4bit#pfml3-prompt-format
enum PLaMoTranslation {
    static let stopTokens = ["<|plamo:tag|>", "<|plamo:bos|>"]

    static func matches(_ model: String) -> Bool {
        model.trimmingCharacters(in: .whitespacesAndNewlines).range(
            of: #"(^|/)plamo-3-translate($|[-_.:])"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    static func prompt(text: String, source: String, target: String) throws -> String {
        let sourceCode = try languageCode(source, allowsAuto: true)
        let targetCode = try languageCode(target, allowsAuto: false)!
        let sourceAttribute = sourceCode.map { "<|plamo:key|>lang<|plamo:val|>\($0)" } ?? ""
        // No BOS: the runtime adds it. Do not apply a chat template to this prompt.
        return "<|plamo:tag|>dataset<|plamo:msg|>translation"
            + "<|plamo:tag|>input\(sourceAttribute)<|plamo:msg|>\(text)"
            + "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>\(targetCode)<|plamo:msg|>"
    }

    static func translationBody(_ output: String) -> String {
        let end = stopTokens.compactMap { output.range(of: $0)?.lowerBound }.min() ?? output.endIndex
        return String(output[..<end])
    }

    private static func languageCode(_ language: String, allowsAuto: Bool) throws -> String? {
        let value = language.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().replacingOccurrences(of: "_", with: "-")
        if allowsAuto, ["", "auto", "automatic", "自動"].contains(value) { return nil }
        if let code = aliases[value] { return code }
        if languages[value] != nil { return value }
        if let code = languages.first(where: { $0.value == value })?.key { return code }
        throw TranslationClientError.unsupportedPLaMoLanguage(language)
    }

    // Model-card language codes; Chinese variants must remain distinct.
    private static let languages = [
        "ja": "japanese", "en": "english", "zh-hans": "chinese (simplified)",
        "zh-hant": "chinese (traditional)", "ko": "korean", "ar": "arabic",
        "az": "azerbaijani", "be": "belarusian", "bg": "bulgarian", "bn": "bengali",
        "ca": "catalan", "ceb": "cebuano", "de": "german", "es": "spanish",
        "et": "estonian", "eu": "basque", "fa": "persian", "fr": "french",
        "gu": "gujarati", "he": "hebrew", "hi": "hindi", "hr": "croatian",
        "hu": "hungarian", "hy": "armenian", "id": "indonesian", "it": "italian",
        "jv": "javanese", "ka": "georgian", "kk": "kazakh", "km": "khmer",
        "lt": "lithuanian", "lv": "latvian", "ml": "malayalam", "mr": "marathi",
        "ms": "malay", "my": "burmese", "ne": "nepali", "nl": "dutch",
        "pa": "punjabi", "pl": "polish", "ru": "russian", "si": "sinhala",
        "sk": "slovak", "sl": "slovenian", "sr": "serbian", "sw": "swahili",
        "ta": "tamil", "te": "telugu", "th": "thai", "tl": "tagalog",
        "ur": "urdu", "uz": "uzbek", "vi": "vietnamese"
    ]

    private static let aliases = [
        "日本語": "ja", "英語": "en", "韓国語": "ko", "中国語": "zh-hans",
        "chinese": "zh-hans", "zh": "zh-hans", "zh-cn": "zh-hans", "zh-sg": "zh-hans",
        "simplified chinese": "zh-hans", "簡体字": "zh-hans", "中国語（簡体字）": "zh-hans",
        "zh-tw": "zh-hant", "zh-hk": "zh-hant", "traditional chinese": "zh-hant",
        "繁体字": "zh-hant", "中国語（繁体字）": "zh-hant",
        "ja-jp": "ja", "en-us": "en", "en-gb": "en", "ko-kr": "ko"
    ]
}

struct PLaMoCompletionRequest: Encodable {
    var model: String
    var prompt: String
    var maxTokens: Int
    let temperature = 0.0
    let stream = false
    let stop = PLaMoTranslation.stopTokens

    enum CodingKeys: String, CodingKey {
        case model, prompt, temperature, stream, stop
        case maxTokens = "max_tokens"
    }
}

struct PLaMoCompletionResponse: Decodable {
    var choices: [Choice]

    struct Choice: Decodable {
        var text: String
        var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case text
            case finishReason = "finish_reason"
        }
    }
}
