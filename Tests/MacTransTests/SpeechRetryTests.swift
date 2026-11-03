import Foundation
import XCTest
@testable import MacTrans

@MainActor
final class SpeechRetryTests: XCTestCase {
    private let config = SpeechConfiguration(apiKey: "secret-key", model: "secret-model", voiceName: "secret-voice")

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func entries(_ directory: URL) throws -> [[String: Any]] {
        try String(contentsOf: directory.appendingPathComponent("speech.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }

    func testRetryClassificationAndServerBackoff() {
        let policy = SpeechRetryPolicy()
        for status in [408, 429, 500, 502, 503, 504] {
            let failure = SpeechFailure(SpeechError.httpStatus(status))
            XCTAssertEqual(policy.delay(after: 1, failure: failure), 2)
            XCTAssertEqual(policy.delay(after: 2, failure: failure), 4)
            XCTAssertNil(policy.delay(after: 3, failure: failure))
        }
        for code: URLError.Code in [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet] {
            XCTAssertNotNil(policy.delay(after: 1, failure: SpeechFailure(URLError(code))))
        }
        let permanent: [Error] = [SpeechError.httpStatus(400), SpeechError.httpStatus(401), SpeechError.httpStatus(403),
            SpeechError.httpStatus(404), SpeechError.httpStatus(501), SpeechError.invalidAudio,
            SpeechError.missingAPIKey, URLError(.secureConnectionFailed), URLError(.serverCertificateUntrusted),
            URLError(.cancelled), CancellationError()]
        for error in permanent { XCTAssertNil(policy.delay(after: 1, failure: SpeechFailure(error))) }
        XCTAssertEqual(policy.delay(after: 1, failure: SpeechFailure(SpeechError.httpStatus(429, retryAfter: 9))), 9)
        XCTAssertNil(policy.delay(after: 1, failure: SpeechFailure(SpeechError.httpStatus(429, retryAfter: 3600))))
        XCTAssertNil(policy.delay(after: 1, failure: SpeechFailure(SpeechError.httpStatus(429, retryAfter: .infinity))))
    }

    func testRetryAfterSecondsAndHTTPDate() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(GeminiTTSClient.retryAfter(" 7 "), 7)
        XCTAssertEqual(GeminiTTSClient.retryAfter("Thu, 01 Jan 1970 00:00:12 GMT", now: now), 12)
        XCTAssertEqual(GeminiTTSClient.retryAfter("Thu, 01 Jan 1970 00:00:00 GMT", now: now.addingTimeInterval(20)), 0)
        for invalid in [nil, "-1", "NaN", "Infinity", "secret-header"] as [String?] {
            XCTAssertNil(GeminiTTSClient.retryAfter(invalid))
        }
    }

    func testTimeoutAndServerFailureRecoverWithoutDuplicatePlaybackAndPersistHistory() async throws {
        let directory = try temporaryDirectory()
        let diagnostics = SpeechDiagnostics(directory: directory)
        var attempts = 0
        var delays: [Double] = []
        var played: [String] = []
        let service = SpeechService(synthesize: { text, _ in
            attempts += 1
            if attempts == 1 { throw URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "secret-response"]) }
            if attempts == 2 { throw SpeechError.httpStatus(503, retryAfter: 8) }
            return Data(text.utf8)
        }, play: { played.append(String(decoding: $0, as: UTF8.self)) }, stopPlayback: {},
           diagnostics: diagnostics, retrySleep: { delays.append($0) })
        service.enqueue("secret-transcript", configuration: config)
        try await waitUntil { !service.isBusy }
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(delays, [2, 8])
        XCTAssertEqual(played, ["secret-transcript"])
        XCTAssertEqual(service.retryingCount, 0)
        XCTAssertNil(service.lastError)
        let records = try entries(directory)
        XCTAssertEqual(records.filter { $0["event"] as? String == "requestFailed" }.compactMap { $0["code"] as? Int }, [-1001, 503])
        XCTAssertEqual(records.filter { $0["event"] as? String == "requestStarted" }.compactMap { $0["attempt"] as? Int }, [1, 2, 3])
        XCTAssertEqual(records.filter { $0["event"] as? String == "retryScheduled" }.count, 2)
        XCTAssertEqual(records.last?["event"] as? String, "playbackEnded")
        let raw = try String(contentsOf: directory.appendingPathComponent("speech.jsonl"), encoding: .utf8)
        for secret in ["secret-key", "secret-model", "secret-voice", "secret-transcript", "secret-response"] {
            XCTAssertFalse(raw.contains(secret))
        }
        // A new logger instance retains earlier records across app launches.
        let reopened = SpeechDiagnostics(directory: directory)
        reopened.record(.started, session: UUID(), pending: 0)
        XCTAssertEqual(try entries(directory).count, records.count + 1)
        XCTAssertNotEqual(records[0]["run"] as? String, try entries(directory).last?["run"] as? String)
    }

    func testRetryExhaustionStopsAfterThreeAttemptsAndLogsFinalFailure() async throws {
        let directory = try temporaryDirectory()
        var attempts = 0
        var delays: [Double] = []
        let service = SpeechService(synthesize: { _, _ in attempts += 1; throw SpeechError.httpStatus(503) },
            play: { _ in XCTFail("Must not play") }, stopPlayback: {},
            diagnostics: SpeechDiagnostics(directory: directory), retrySleep: { delays.append($0) })
        service.enqueue("A", configuration: config)
        try await waitUntil { !service.isBusy }
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(delays, [2, 4])
        XCTAssertTrue(try XCTUnwrap(service.lastError).contains("503"))
        XCTAssertEqual(service.pendingCount, 0)
        let records = try entries(directory)
        XCTAssertEqual(records.filter { $0["event"] as? String == "generationFailed" }.count, 1)
        XCTAssertEqual(records.last?["event"] as? String, "stopped")
    }

    func testStopDuringBackoffCannotRestartOldJobOrAffectNewQueue() async throws {
        var resume: CheckedContinuation<Void, Never>?
        var requested: [String] = []
        var played: [String] = []
        let service = SpeechService(synthesize: { text, _ in
            requested.append(text)
            if text == "old" { throw URLError(.timedOut) }
            return Data(text.utf8)
        }, play: { played.append(String(decoding: $0, as: UTF8.self)) }, stopPlayback: {},
           retrySleep: { _ in await withCheckedContinuation { resume = $0 } })
        service.enqueue("old", configuration: config)
        try await waitUntil { resume != nil }
        XCTAssertEqual(service.retryingCount, 1)
        service.stop()
        service.enqueue("new", configuration: config)
        resume?.resume()
        try await waitUntil { !service.isBusy }
        XCTAssertEqual(requested, ["old", "new"])
        XCTAssertEqual(played, ["new"])
        XCTAssertEqual(service.retryingCount, 0)
        XCTAssertNil(service.lastError)
    }

    func testRetryKeepsReadySuccessorBufferedAndFIFO() async throws {
        var resume: CheckedContinuation<Void, Never>?
        var firstAttempts = 0
        var played: [String] = []
        let service = SpeechService(synthesize: { text, _ in
            if text == "A" {
                firstAttempts += 1
                if firstAttempts == 1 { throw SpeechError.httpStatus(500) }
            }
            return Data(text.utf8)
        }, play: { played.append(String(decoding: $0, as: UTF8.self)) }, stopPlayback: {},
           retrySleep: { _ in await withCheckedContinuation { resume = $0 } })
        service.enqueue("A", configuration: config)
        service.enqueue("B", configuration: config)
        try await waitUntil { resume != nil && service.readyCount == 1 }
        XCTAssertTrue(played.isEmpty)
        resume?.resume()
        try await waitUntil { !service.isBusy }
        XCTAssertEqual(played, ["A", "B"])
        XCTAssertEqual(firstAttempts, 2)
    }

    func testLogsRotateWithBoundedRetentionAndDoNotExposeUnknownErrors() throws {
        let directory = try temporaryDirectory()
        let diagnostics = SpeechDiagnostics(directory: directory, maximumBytes: 1400, archiveCount: 2)
        let session = UUID()
        let error = NSError(domain: "secret-domain", code: 42, userInfo: [NSLocalizedDescriptionKey: "secret-message"])
        for chunk in 0..<40 {
            diagnostics.record(.requestFailed, session: session, chunk: chunk, attempt: 1,
                               pending: 1, failure: SpeechFailure(error))
        }
        XCTAssertNil(diagnostics.writeError)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), Set(["speech.jsonl", "speech.1.jsonl", "speech.2.jsonl"]))
        for file in files {
            let data = try Data(contentsOf: file)
            XCTAssertLessThanOrEqual(data.count, 1400)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret"))
            for line in data.split(separator: 0x0a) { XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line))) }
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600)
        }
        XCTAssertEqual(try entries(directory).last?["chunk"] as? Int, 39)
    }

    func testLoggingFailureIsVisible() throws {
        let directory = try temporaryDirectory().appendingPathComponent("file")
        try Data().write(to: directory)
        let diagnostics = SpeechDiagnostics(directory: directory)
        diagnostics.record(.started, session: UUID(), pending: 0)
        XCTAssertNotNil(diagnostics.writeError)
    }
}
