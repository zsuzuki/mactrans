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

    func appendPendingReplacingRecentRevision(sourceText: String) -> UUID {
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = recentRevisionIndex(for: trimmed) {
            segments.remove(at: index)
        }
        return appendPending(sourceText: trimmed)
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

    private func recentRevisionIndex(for sourceText: String) -> Int? {
        guard !sourceText.isEmpty else { return nil }
        guard let index = segments.lastIndex(where: { $0.state != .partial }) else { return nil }

        let previous = segments[index]
        guard Date().timeIntervalSince(previous.createdAt) <= 12 else { return nil }
        guard isLikelyRevision(previous: previous.sourceText, current: sourceText) else { return nil }

        return index
    }

    private func isLikelyRevision(previous: String, current: String) -> Bool {
        let previousNormalized = normalizedForRevision(previous)
        let currentNormalized = normalizedForRevision(current)
        guard previousNormalized.count >= 18, currentNormalized.count >= 18 else { return false }

        let commonCount = commonPrefixCount(previousNormalized, currentNormalized)
        guard commonCount >= 18 else { return false }

        let previousCoverage = Double(commonCount) / Double(previousNormalized.count)
        let currentAddsMeaningfulTail = currentNormalized.count >= previousNormalized.count + 8
        return previousCoverage >= 0.55 && currentAddsMeaningfulTail
    }

    private func normalizedForRevision(_ value: String) -> String {
        value
            .lowercased()
            .filter { !$0.isPunctuation && !$0.isWhitespace }
    }

    private func commonPrefixCount(_ left: String, _ right: String) -> Int {
        var count = 0
        var leftIndex = left.startIndex
        var rightIndex = right.startIndex

        while leftIndex < left.endIndex, rightIndex < right.endIndex {
            guard left[leftIndex] == right[rightIndex] else { break }
            count += 1
            leftIndex = left.index(after: leftIndex)
            rightIndex = right.index(after: rightIndex)
        }

        return count
    }

    private static func makeSessionURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacTrans", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let filename = "transcript-\(formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")).txt"
        return directory.appendingPathComponent(filename)
    }
}
