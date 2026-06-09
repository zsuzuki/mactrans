import Foundation

@MainActor
final class TranscriptStore: ObservableObject {
    @Published private(set) var segments: [TranscriptSegment] = []

    private(set) var sessionURL: URL

    init() {
        sessionURL = Self.makeSessionURL()
        writeSnapshot()
    }

    func resetSession() {
        segments.removeAll()
        sessionURL = Self.makeSessionURL()
        writeSnapshot()
    }

    func appendPending(sourceText: String) -> UUID {
        let segment = TranscriptSegment(sourceText: sourceText, translatedText: "...", state: .translating)
        segments.append(segment)
        writeSnapshot()
        return segment.id
    }

    func updatePartial(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            removePartial()
            return
        }

        if let index = segments.firstIndex(where: { $0.state == .partial }) {
            segments[index].sourceText = trimmed
            segments[index].translatedText = "..."
        } else {
            segments.append(TranscriptSegment(sourceText: trimmed, translatedText: "...", state: .partial))
        }
        writeSnapshot()
    }

    func removePartial() {
        segments.removeAll { $0.state == .partial }
        writeSnapshot()
    }

    func markTranslated(id: UUID, translatedText: String) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].translatedText = translatedText
        segments[index].state = .translated
        segments[index].errorMessage = nil
        writeSnapshot()
    }

    func markFailed(id: UUID, message: String) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].translatedText = "..."
        segments[index].state = .failed
        segments[index].errorMessage = message
        writeSnapshot()
    }

    func exportText() -> String {
        segments
            .filter { $0.state != .partial }
            .map { segment in
                let translated = segment.state == .translated ? segment.translatedText : "..."
                return "\(segment.sourceText)\n\(translated)"
            }
            .joined(separator: "\n\n")
    }

    func writeSnapshot() {
        try? exportText().write(to: sessionURL, atomically: true, encoding: .utf8)
    }

    private static func makeSessionURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacTrans", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let filename = "transcript-\(formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")).txt"
        return directory.appendingPathComponent(filename)
    }
}
