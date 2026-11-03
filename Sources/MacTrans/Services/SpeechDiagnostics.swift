import Foundation
import OSLog

// Only fixed categories and numeric codes cross the logging boundary. Never log
// localizedDescription, userInfo, URLs, headers, model/voice names or API bodies.
struct SpeechFailure {
    enum Category: String, Encodable { case http, network, configuration, invalidAudio, inputTooLarge, queueFull, cancelled, other }
    let category: Category
    var code: Int?
    var retryAfter: Double?
    var retryable = false

    init(_ error: Error) {
        if let error = error as? SpeechError {
            switch error {
            case .httpStatus(let status, let retryAfter):
                category = .http
                code = status
                self.retryAfter = retryAfter
                retryable = [408, 429, 500, 502, 503, 504].contains(status)
            case .missingAPIKey, .missingModel, .missingVoice: category = .configuration
            case .invalidAudio: category = .invalidAudio
            case .inputTooLarge: category = .inputTooLarge
            case .queueFull: category = .queueFull
            }
        } else if error is CancellationError {
            category = .cancelled
        } else if let error = error as? URLError {
            category = error.code == .cancelled ? .cancelled : .network
            code = error.code.rawValue
            retryable = [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                         .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code)
        } else {
            category = .other
            code = (error as NSError).code
        }
    }
}

struct SpeechRetryPolicy {
    var maximumAttempts = 3

    func delay(after attempt: Int, failure: SpeechFailure) -> Double? {
        guard failure.retryable, attempt < maximumAttempts else { return nil }
        let serverDelay = failure.retryAfter ?? 0
        // Do not retry earlier than Retry-After or wait indefinitely on a quota.
        guard serverDelay.isFinite, serverDelay >= 0, serverDelay <= 60 else { return nil }
        return max(serverDelay, min(30, pow(2, Double(attempt))))
    }
}

@MainActor
final class SpeechDiagnostics: ObservableObject {
    static let shared = SpeechDiagnostics(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MacTrans", isDirectory: true))
    static let disabled = SpeechDiagnostics(directory: nil)

    enum Event: String, Encodable {
        case started, queued, queueRejected, requestStarted, requestFailed, retryScheduled
        case generated, generationFailed, playbackStarted, playbackEnded, playbackFailed, stopped
        case cooldownStarted, cooldownRestored, cooldownEnded
    }

    private struct Entry: Encodable {
        var timestamp: String
        var run: UUID
        var session: UUID
        var event: Event
        var chunk: Int?
        var attempt: Int?
        var pending: Int
        var category: SpeechFailure.Category?
        var code: Int?
        var retryable: Bool?
        var retryAfterSeconds: Double?
        var elapsedSeconds: Double?
        var retryDelaySeconds: Double?
        var resumeAt: String?
    }

    let directory: URL?
    @Published private(set) var writeError: String?
    private let maximumBytes: Int
    private let archiveCount: Int
    private let run = UUID()
    private let formatter = ISO8601DateFormatter()
    private let logger = Logger(subsystem: "dev.local.MacTrans", category: "Speech")

    init(directory: URL?, maximumBytes: Int = 1_048_576, archiveCount: Int = 3) {
        self.directory = directory
        self.maximumBytes = maximumBytes
        self.archiveCount = max(1, archiveCount)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    // Recover Retry-After recorded by earlier builds, without another API call.
    func pendingCooldown(after now: Date) -> Date? {
        struct FailureRecord: Decodable {
            let timestamp: String
            let event: String
            let category: String?
            let code: Int?
            let retryAfterSeconds: Double?
        }
        guard let directory else { return nil }
        var deadline: Date?
        for index in 0...archiveCount {
            let name = index == 0 ? "speech.jsonl" : "speech.\(index).jsonl"
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { continue }
            for line in data.split(separator: 0x0a) {
                guard let record = try? JSONDecoder().decode(FailureRecord.self, from: Data(line)),
                      record.event == "requestFailed", record.category == "http",
                      let code = record.code, [408, 429, 500, 502, 503, 504].contains(code),
                      let delay = record.retryAfterSeconds, delay.isFinite, delay > 60,
                      let time = formatter.date(from: record.timestamp) else { continue }
                let candidate = time.addingTimeInterval(delay)
                if candidate > now { deadline = max(deadline ?? candidate, candidate) }
            }
        }
        return deadline
    }

    func record(_ event: Event, session: UUID, chunk: Int? = nil, attempt: Int? = nil,
                pending: Int, failure: SpeechFailure? = nil, elapsed: Double? = nil, delay: Double? = nil,
                resumeAt: Date? = nil) {
        guard let directory else { return }
        let entry = Entry(timestamp: formatter.string(from: Date()), run: run, session: session,
            event: event, chunk: chunk, attempt: attempt, pending: pending,
            category: failure?.category, code: failure?.code, retryable: failure?.retryable,
            retryAfterSeconds: failure?.retryAfter.flatMap { $0.isFinite ? $0 : nil },
            elapsedSeconds: elapsed, retryDelaySeconds: delay,
            resumeAt: resumeAt.map { formatter.string(from: $0) })
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("speech.jsonl")
            var line = try JSONEncoder().encode(entry)
            line.append(0x0a)
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            if size > 0, size + line.count > maximumBytes {
                let oldest = directory.appendingPathComponent("speech.\(archiveCount).jsonl")
                if fm.fileExists(atPath: oldest.path) { try fm.removeItem(at: oldest) }
                if archiveCount > 1 {
                    for index in stride(from: archiveCount - 1, through: 1, by: -1) {
                        let source = directory.appendingPathComponent("speech.\(index).jsonl")
                        if fm.fileExists(atPath: source.path) {
                            try fm.moveItem(at: source, to: directory.appendingPathComponent("speech.\(index + 1).jsonl"))
                        }
                    }
                }
                try fm.moveItem(at: url, to: directory.appendingPathComponent("speech.1.jsonl"))
            }
            if !fm.fileExists(atPath: url.path) {
                guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            writeError = nil
        } catch {
            writeError = "Could not write speech diagnostics (file error \((error as NSError).code))."
            logger.error("Speech diagnostics write failed: code=\((error as NSError).code)")
        }
    }
}
