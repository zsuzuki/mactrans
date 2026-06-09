import Foundation

enum TranscriptSegmentState: String, Codable {
    case partial
    case transcribing
    case translating
    case translated
    case failed
}

struct TranscriptSegment: Identifiable, Codable, Equatable {
    let id: UUID
    var sourceText: String
    var translatedText: String
    var state: TranscriptSegmentState
    var errorMessage: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        sourceText: String,
        translatedText: String = "",
        state: TranscriptSegmentState,
        errorMessage: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.state = state
        self.errorMessage = errorMessage
        self.createdAt = createdAt
    }
}
