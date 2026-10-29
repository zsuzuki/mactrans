import Foundation

@MainActor
final class AppPreferences: ObservableObject {
    @Published var audioInputSource: AudioInputSource {
        didSet { defaults.set(audioInputSource.rawValue, forKey: Keys.audioInputSource) }
    }

    @Published var sourceLanguage: String {
        didSet { defaults.set(sourceLanguage, forKey: Keys.sourceLanguage) }
    }

    @Published var targetLanguage: String {
        didSet { defaults.set(targetLanguage, forKey: Keys.targetLanguage) }
    }

    @Published var lmStudioBaseURL: String {
        didSet { defaults.set(lmStudioBaseURL, forKey: Keys.lmStudioBaseURL) }
    }

    @Published var lmStudioModel: String {
        didSet { defaults.set(lmStudioModel, forKey: Keys.lmStudioModel) }
    }

    @Published var lmStudioAPIKey: String {
        didSet { KeychainService.save(lmStudioAPIKey, account: KeychainAccounts.lmStudioAPIKey) }
    }

    @Published var lmStudioReasoningEffort: String {
        didSet { defaults.set(lmStudioReasoningEffort, forKey: Keys.lmStudioReasoningEffort) }
    }

    @Published var whisperModelPath: String {
        didSet { defaults.set(whisperModelPath, forKey: Keys.whisperModelPath) }
    }

    @Published var chunkTimeoutSeconds: Double {
        didSet { defaults.set(chunkTimeoutSeconds, forKey: Keys.chunkTimeoutSeconds) }
    }

    @Published var maxChunkCharacters: Int {
        didSet { defaults.set(maxChunkCharacters, forKey: Keys.maxChunkCharacters) }
    }

    @Published var chunkingMode: String {
        didSet { defaults.set(chunkingMode, forKey: Keys.chunkingMode) }
    }

    @Published var speechEnabled: Bool {
        didSet { defaults.set(speechEnabled, forKey: Keys.speechEnabled) }
    }

    @Published var googleTTSAPIKey: String {
        didSet { KeychainService.save(googleTTSAPIKey, account: "googleTTSAPIKey") }
    }

    @Published var speechModel: String {
        didSet { defaults.set(speechModel, forKey: Keys.speechModel) }
    }

    @Published var speechVoiceName: String {
        didSet { defaults.set(speechVoiceName, forKey: Keys.speechVoiceName) }
    }

    var speechConfiguration: SpeechConfiguration {
        SpeechConfiguration(apiKey: googleTTSAPIKey, model: speechModel, voiceName: speechVoiceName)
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        audioInputSource = AudioInputSource(rawValue: defaults.string(forKey: Keys.audioInputSource) ?? "") ?? .microphone
        sourceLanguage = defaults.string(forKey: Keys.sourceLanguage) ?? "English"
        targetLanguage = defaults.string(forKey: Keys.targetLanguage) ?? "Japanese"
        lmStudioBaseURL = defaults.string(forKey: Keys.lmStudioBaseURL) ?? "http://127.0.0.1:1234/v1/chat/completions"
        lmStudioModel = defaults.string(forKey: Keys.lmStudioModel) ?? "google/gemma-4-26b-a4b-qat"
        lmStudioAPIKey = Self.loadAPIKey(defaults: defaults)
        lmStudioReasoningEffort = defaults.string(forKey: Keys.lmStudioReasoningEffort) ?? "none"
        whisperModelPath = defaults.string(forKey: Keys.whisperModelPath) ?? ""

        let savedTimeout = defaults.double(forKey: Keys.chunkTimeoutSeconds)
        chunkTimeoutSeconds = savedTimeout > 0 ? savedTimeout : 2.8

        let savedMaxCharacters = defaults.integer(forKey: Keys.maxChunkCharacters)
        maxChunkCharacters = savedMaxCharacters > 0 ? savedMaxCharacters : 220

        chunkingMode = defaults.string(forKey: Keys.chunkingMode) ?? "balanced"
        speechEnabled = defaults.bool(forKey: Keys.speechEnabled)
        // Keep the original account name so the entered key survives the API fix.
        googleTTSAPIKey = KeychainService.read(account: "googleTTSAPIKey")
        speechModel = defaults.string(forKey: Keys.speechModel) ?? "gemini-3.8-flash-tts"
        speechVoiceName = defaults.string(forKey: Keys.speechVoiceName) ?? "Kore"
    }

    private enum Keys {
        static let audioInputSource = "audioInputSource"
        static let sourceLanguage = "sourceLanguage"
        static let targetLanguage = "targetLanguage"
        static let lmStudioBaseURL = "lmStudioBaseURL"
        static let lmStudioModel = "lmStudioModel"
        static let lmStudioAPIKey = "lmStudioAPIKey"
        static let lmStudioReasoningEffort = "lmStudioReasoningEffort"
        static let whisperModelPath = "whisperModelPath"
        static let chunkTimeoutSeconds = "chunkTimeoutSeconds"
        static let maxChunkCharacters = "maxChunkCharacters"
        static let chunkingMode = "chunkingMode"
        static let speechEnabled = "speechEnabled"
        static let speechModel = "speechModel"
        static let speechVoiceName = "speechVoiceName"
    }

    private enum KeychainAccounts {
        static let lmStudioAPIKey = "lmStudioAPIKey"
    }

    private static func loadAPIKey(defaults: UserDefaults) -> String {
        let keychainValue = KeychainService.read(account: KeychainAccounts.lmStudioAPIKey)
        if !keychainValue.isEmpty {
            return keychainValue
        }

        let legacyValue = defaults.string(forKey: Keys.lmStudioAPIKey) ?? ""
        if !legacyValue.isEmpty {
            KeychainService.save(legacyValue, account: KeychainAccounts.lmStudioAPIKey)
            defaults.removeObject(forKey: Keys.lmStudioAPIKey)
        }
        return legacyValue
    }
}
