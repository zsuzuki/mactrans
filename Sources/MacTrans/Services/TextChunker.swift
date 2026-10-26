import Foundation

/// Times are absolute sample offsets in the session's 16 kHz audio stream.
struct TimedWord: Equatable, Sendable {
    var text: String
    var startSample: Int64
    var endSample: Int64

    var normalized: String {
        text.lowercased().filter { !$0.isPunctuation && !$0.isWhitespace }
    }

    var midpoint: Int64 { startSample + (endSample - startSample) / 2 }
}

struct TranscriptionUpdate: Sendable {
    var committed: [String] = []
    var partialText: String = ""
}

/// Confirms only stable prefixes or a completed speech interval. Wall-clock
/// time never commits a hypothesis: all decisions use captured audio time.
struct TextChunker {
    enum Mode: String, Sendable {
        case fast, balanced, stable

        var confirmations: Int { self == .stable ? 3 : 2 }
        var silenceSeconds: Double {
            switch self {
            case .fast: 0.45
            case .balanced: 0.7
            case .stable: 1.0
            }
        }
        var timeoutMultiplier: Double { self == .stable ? 1.55 : (self == .fast ? 0.75 : 1) }
        var edgeSamples: Int64 { self == .stable ? 9_600 : 6_400 }
    }

    var timeoutSeconds: Double
    var maxCharacters: Int
    var mode: Mode
    private(set) var committedThrough: Int64 = 0
    private var previous: [TimedWord] = []
    private var confirmations: [Int] = []
    private var lastAudioEnd: Int64 = -1
    private var partialText = ""
    private var committedTail: [TimedWord] = []

    init(timeoutSeconds: Double, maxCharacters: Int, mode: Mode = .balanced) {
        self.timeoutSeconds = timeoutSeconds
        self.maxCharacters = maxCharacters
        self.mode = mode
    }

    mutating func accept(_ words: [TimedWord], audioEnd: Int64, isFinal: Bool,
                         forceBoundary: Bool = false) -> TranscriptionUpdate {
        guard audioEnd >= lastAudioEnd, audioEnd > committedThrough else {
            return TranscriptionUpdate(partialText: partialText)
        }
        // Re-decoding the same audio does not count as independent agreement.
        guard audioEnd > lastAudioEnd || isFinal else {
            return TranscriptionUpdate(partialText: partialText)
        }
        lastAudioEnd = audioEnd
        let candidates = words.dropFirst(confirmedPrefixCount(in: words)).filter {
            $0.endSample > committedThrough && $0.midpoint >= committedThrough &&
            $0.startSample >= 0 && $0.endSample >= $0.startSample && $0.endSample <= audioEnd
        }
        var counts = [Int](repeating: 1, count: candidates.count)
        for index in 0..<min(candidates.count, previous.count) {
            // Text agreement must refer to the same audio, not a later repetition.
            guard candidates[index].normalized == previous[index].normalized,
                  abs(candidates[index].midpoint - previous[index].midpoint) <= 8_000 else { break }
            counts[index] = confirmations[index] + 1
        }

        var commitCount = 0
        if isFinal {
            commitCount = candidates.count
        } else {
            var stableCount = 0
            // The newest word can still be incomplete, even when its text repeats.
            for index in candidates.indices {
                guard index < candidates.count - 1,
                      counts[index] >= mode.confirmations,
                      candidates[index].endSample <= audioEnd - mode.edgeSamples else { break }
                stableCount += 1
            }
            for index in 0..<stableCount where endsSentence(candidates[index].text) {
                commitCount = index + 1
            }
            let stable = Array(candidates.prefix(stableCount))
            let stableText = Self.text(stable)
            let age = candidates.first.map { Double(audioEnd - $0.startSample) / 16_000 } ?? 0
            // Long speech can advance at a stable word boundary, but a timeout
            // alone must never publish an unstable tail or a short fragment.
            if commitCount == 0 && (stableText.count >= maxCharacters ||
                (stableText.count >= max(60, maxCharacters * 2 / 3) &&
                 age >= timeoutSeconds * mode.timeoutMultiplier)) {
                commitCount = stableCount
            }
            if forceBoundary && commitCount == 0 {
                // Bounded audio buffer: leave the last 800 ms for the next decode.
                commitCount = candidates.prefix { $0.endSample <= audioEnd - 12_800 }.count
            }
        }

        let committedWords = Array(candidates.prefix(commitCount))
        let text = Self.text(committedWords)
        if let end = committedWords.last?.endSample {
            committedThrough = max(committedThrough, end)
            committedTail = Array((committedTail + committedWords).suffix(16))
        }
        previous = Array(candidates.dropFirst(commitCount))
        confirmations = Array(counts.dropFirst(commitCount))
        partialText = Self.text(previous)
        if isFinal {
            // Consume the entire completed interval, including silence. A future
            // utterance with identical wording is still a new audio interval.
            committedThrough = max(committedThrough, audioEnd)
            previous.removeAll()
            confirmations.removeAll()
            partialText = ""
        }
        return TranscriptionUpdate(committed: text.isEmpty ? [] : [text], partialText: partialText)
    }

    private static func text(_ words: [TimedWord]) -> String {
        words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func confirmedPrefixCount(in words: [TimedWord]) -> Int {
        // Word timestamps can move between decodes. Anchor a repeated suffix
        // of at least two confirmed words to the same audio interval before
        // applying the time cutoff. Never match speech starting after it.
        guard committedTail.count >= 2 else { return 0 }
        var bestCount = 0
        var bestLength = 1
        var bestDistance = Int64.max
        for end in words.indices {
            var length = 0
            var distance: Int64 = 0
            while length <= end && length < committedTail.count {
                let word = words[end - length]
                let confirmed = committedTail[committedTail.count - 1 - length]
                let delta = abs(word.midpoint - confirmed.midpoint)
                guard word.normalized == confirmed.normalized, delta <= 8_000 else { break }
                distance += delta
                length += 1
            }
            guard length >= 2, words[end - length + 1].startSample < committedThrough else { continue }
            if length > bestLength || (length == bestLength && distance < bestDistance) {
                bestLength = length
                bestDistance = distance
                bestCount = end + 1
            }
        }
        return bestCount
    }

    private func endsSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, ".?!。！？".contains(last) else { return false }
        let abbreviations: Set<String> = ["mr.", "mrs.", "ms.", "dr.", "prof.", "e.g.", "i.e."]
        return !abbreviations.contains(trimmed.lowercased())
    }
}
