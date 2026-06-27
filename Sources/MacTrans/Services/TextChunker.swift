import Foundation

struct TextChunker {
    enum Mode: String {
        case fast
        case balanced
        case stable

        var stableCandidateThreshold: Int {
            switch self {
            case .fast: 1
            case .balanced: 2
            case .stable: 3
            }
        }

        var timeoutMultiplier: Double {
            switch self {
            case .fast: 0.75
            case .balanced: 1.0
            case .stable: 1.55
            }
        }

        var punctuationMinimumAge: Double {
            switch self {
            case .fast: 0.35
            case .balanced: 0.9
            case .stable: 1.4
            }
        }
    }

    var timeoutSeconds: Double
    var maxCharacters: Int
    var mode: Mode

    private var pendingText = ""
    private var pendingFirstSeen = Date()
    private var committedText = ""
    private var lastCandidateText = ""
    private var stableCandidateCount = 0
    private var lastUpdate = Date()
    private var lastCommittedShortText = ""
    private var repeatedShortCommitCount = 0

    init(timeoutSeconds: Double, maxCharacters: Int, mode: Mode = .balanced) {
        self.timeoutSeconds = timeoutSeconds
        self.maxCharacters = maxCharacters
        self.mode = mode
    }

    mutating func accept(_ text: String, isFinal: Bool) -> String? {
        let trimmed = uncommittedText(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return nil }

        let previousPending = pendingText
        if pendingText.isEmpty {
            pendingFirstSeen = Date()
        }
        lastUpdate = Date()

        if let stablePrefix = stableCommitPrefix(previous: previousPending, current: trimmed) {
            let remainder = String(trimmed.dropFirst(stablePrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            pendingText = remainder
            pendingFirstSeen = Date()
            lastCandidateText = remainder
            stableCandidateCount = remainder.isEmpty ? 0 : 1
            if let chunk = commit(stablePrefix) {
                return chunk
            }
        }

        pendingText = trimmed
        if trimmed == lastCandidateText {
            stableCandidateCount += 1
        } else {
            lastCandidateText = trimmed
            stableCandidateCount = 1
        }

        if isFinal || shouldFlush(trimmed) {
            guard isFinal || isStableEnough(trimmed) else {
                return nil
            }
            return completePending()
        }
        return nil
    }

    mutating func flushIfTimedOut(now: Date = Date()) -> String? {
        guard !pendingText.isEmpty else { return nil }
        guard now.timeIntervalSince(pendingFirstSeen) >= timeoutSeconds * mode.timeoutMultiplier else { return nil }
        return flush()
    }

    mutating func clear() {
        pendingText = ""
        pendingFirstSeen = Date()
        committedText = ""
        lastCandidateText = ""
        stableCandidateCount = 0
        lastUpdate = Date()
        lastCommittedShortText = ""
        repeatedShortCommitCount = 0
    }

    private mutating func completePending() -> String? {
        let candidate = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingText = ""
        guard !candidate.isEmpty else { return nil }
        return commit(candidate)
    }

    private mutating func flush() -> String? {
        let output = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingText = ""
        pendingFirstSeen = Date()
        lastCandidateText = ""
        stableCandidateCount = 0
        return commit(output)
    }

    private func shouldFlush(_ text: String) -> Bool {
        if text.count >= maxCharacters {
            return true
        }

        let punctuation = CharacterSet(charactersIn: ".?!。！？")
        guard let lastScalar = text.unicodeScalars.last else { return false }
        return punctuation.contains(lastScalar) && Date().timeIntervalSince(pendingFirstSeen) >= mode.punctuationMinimumAge
    }

    private func stableCommitPrefix(previous: String, current: String) -> String? {
        guard !previous.isEmpty else { return nil }
        guard Date().timeIntervalSince(pendingFirstSeen) >= mode.punctuationMinimumAge else { return nil }

        let common = commonPrefix(previous, current)
        guard common.count >= 12 else { return nil }

        if let sentence = lastPrefixEndingWithSentencePunctuation(in: common) {
            let remainder = String(current.dropFirst(sentence.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainder.isEmpty {
                return sentence
            }
        }

        if common.count >= max(80, maxChunkSoftBoundary) {
            return lastPrefixEndingAtWordBoundary(in: common)
        }

        return nil
    }

    private var maxChunkSoftBoundary: Int {
        max(60, Int(Double(maxCharacters) * 0.65))
    }

    private func commonPrefix(_ left: String, _ right: String) -> String {
        var leftIndex = left.startIndex
        var rightIndex = right.startIndex

        while leftIndex < left.endIndex, rightIndex < right.endIndex {
            guard left[leftIndex] == right[rightIndex] else { break }
            leftIndex = left.index(after: leftIndex)
            rightIndex = right.index(after: rightIndex)
        }

        return String(left[..<leftIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func lastPrefixEndingWithSentencePunctuation(in text: String) -> String? {
        let punctuation: Set<Character> = [".", "?", "!", "。", "？", "！"]
        var bestEnd: String.Index?

        for index in text.indices where punctuation.contains(text[index]) {
            bestEnd = text.index(after: index)
        }

        guard let bestEnd else { return nil }
        let prefix = String(text[..<bestEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.count >= 12 ? prefix : nil
    }

    private func lastPrefixEndingAtWordBoundary(in text: String) -> String? {
        var bestEnd: String.Index?
        var index = text.startIndex

        while index < text.endIndex {
            if text[index].isWhitespace {
                bestEnd = index
            }
            index = text.index(after: index)
        }

        guard let bestEnd else { return nil }
        let prefix = String(text[..<bestEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.count >= maxChunkSoftBoundary ? prefix : nil
    }

    private func isStableEnough(_ text: String) -> Bool {
        if text.count >= maxCharacters {
            return true
        }
        if stableCandidateCount >= mode.stableCandidateThreshold {
            return true
        }
        return Date().timeIntervalSince(pendingFirstSeen) >= max(1.2, timeoutSeconds * mode.timeoutMultiplier)
    }

    private func uncommittedText(from text: String) -> String {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCommitted = committedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCommitted.isEmpty else { return candidate }

        if candidate.hasPrefix(normalizedCommitted) {
            return String(candidate.dropFirst(normalizedCommitted.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let overlap = suffixPrefixOverlap(committed: normalizedCommitted, candidate: candidate)
        if overlap > 0 {
            return String(candidate.dropFirst(overlap))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return candidate
    }

    private mutating func commit(_ output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard shouldPublish(trimmed) else { return nil }

        committedText = [committedText, trimmed]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed
    }

    private func suffixPrefixOverlap(committed: String, candidate: String) -> Int {
        let maxLength = min(committed.count, candidate.count)
        guard maxLength >= 12 else { return 0 }

        for length in stride(from: maxLength, through: 12, by: -1) {
            let committedSuffix = String(committed.suffix(length))
            let candidatePrefix = String(candidate.prefix(length))
            if normalizedForOverlap(committedSuffix) == normalizedForOverlap(candidatePrefix) {
                return length
            }
        }
        return 0
    }

    private func normalizedForOverlap(_ value: String) -> String {
        value
            .lowercased()
            .filter { !$0.isPunctuation && !$0.isWhitespace }
    }

    private func isPublishable(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    private mutating func shouldPublish(_ text: String) -> Bool {
        guard isPublishable(text) else { return false }

        if isVeryShort(text) {
            let normalized = normalizedForOverlap(text)
            if normalized == lastCommittedShortText {
                repeatedShortCommitCount += 1
            } else {
                lastCommittedShortText = normalized
                repeatedShortCommitCount = 1
            }
            return repeatedShortCommitCount <= 2
        }

        lastCommittedShortText = ""
        repeatedShortCommitCount = 0
        return true
    }

    private func isVeryShort(_ text: String) -> Bool {
        let words = text
            .split { $0.isWhitespace || $0.isPunctuation }
            .filter { !$0.isEmpty }
        return words.count <= 1 && text.count <= 12
    }
}
