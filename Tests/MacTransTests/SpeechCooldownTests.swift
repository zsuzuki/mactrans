import Foundation
import XCTest
@testable import MacTrans

@MainActor
final class SpeechCooldownTests: XCTestCase {
    private let config = SpeechConfiguration(apiKey: "test", voiceName: "test")

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out")
    }

    func testLongRetryAfterBlocksNewTranslationsAndSurvivesStopAndRelaunch() async throws {
        let suite = "SpeechCooldownTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        let initial = date
        var requests = 0
        var played: [String] = []
        let service = SpeechService(synthesize: { _, _ in
            requests += 1
            throw SpeechError.httpStatus(429, retryAfter: 81760)
        }, play: { _ in XCTFail("No audio expected") }, stopPlayback: {},
           wallNow: { date }, cooldownDefaults: defaults,
           retrySleep: { _ in XCTFail("Long waits must not retry") })
        service.enqueue("first", configuration: config)
        try await waitUntil { service.resumeAt != nil }
        XCTAssertEqual(service.resumeAt, initial.addingTimeInterval(81760))
        XCTAssertFalse(service.isBusy)
        XCTAssertNil(service.lastError)
        service.stop()
        for _ in 0..<50 { service.enqueue("skip", configuration: config) }
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(service.pendingCount, 0)

        let restored = SpeechService(synthesize: { text, _ in requests += 1; return Data(text.utf8) },
            play: { played.append(String(decoding: $0, as: UTF8.self)) }, stopPlayback: {},
            wallNow: { date }, cooldownDefaults: defaults)
        XCTAssertEqual(restored.resumeAt, service.resumeAt)
        date = initial.addingTimeInterval(81759)
        restored.enqueue("too early", configuration: config)
        XCTAssertEqual(requests, 1)
        date = initial.addingTimeInterval(81760)
        restored.enqueue("new", configuration: config)
        try await waitUntil { !restored.isBusy }
        XCTAssertNil(restored.resumeAt)
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(played, ["new"])
        let expired = SpeechService(play: { _ in }, stopPlayback: {}, wallNow: { date }, cooldownDefaults: defaults)
        XCTAssertNil(expired.resumeAt)
    }

    func testCooldownPreservesCurrentPlaybackAndDiscardsLatePrefetchAndBacklog() async throws {
        var date = Date()
        var finish: CheckedContinuation<Void, Never>?
        var late: CheckedContinuation<Data, Never>?
        var fail: CheckedContinuation<Void, Never>?
        var requests: [String] = []
        var played: [String] = []
        var stops = 0
        let service = SpeechService(synthesize: { text, _ in
            requests.append(text)
            if text == "B" {
                await withCheckedContinuation { fail = $0 }
                throw SpeechError.httpStatus(503, retryAfter: 120)
            }
            if text == "C" { return await withCheckedContinuation { late = $0 } }
            return Data(text.utf8)
        }, play: { data in
            let text = String(decoding: data, as: UTF8.self)
            played.append(text)
            if text == "A" { await withCheckedContinuation { finish = $0 } }
        }, stopPlayback: { stops += 1 }, wallNow: { date })
        for text in ["A", "B", "C", "D"] { service.enqueue(text, configuration: config) }
        try await waitUntil { finish != nil && late != nil && fail != nil }
        fail?.resume()
        try await waitUntil { service.resumeAt != nil }
        XCTAssertEqual(stops, 0)
        XCTAssertEqual(service.pendingCount, 1)
        XCTAssertEqual(service.generatingCount, 0)
        XCTAssertEqual(service.readyCount, 0)
        late?.resume(returning: Data("C".utf8))
        service.enqueue("skip", configuration: config)
        finish?.resume()
        try await waitUntil { !service.isBusy }
        XCTAssertEqual(played, ["A"])
        XCTAssertEqual(requests, ["A", "B", "C"])
        date = date.addingTimeInterval(121)
        service.enqueue("E", configuration: config)
        try await waitUntil { !service.isBusy }
        XCTAssertEqual(played, ["A", "E"])
        XCTAssertNil(service.lastError)
    }

    func testCooldownDuringSplitTranslationFinishesPendingCountCorrectly() async throws {
        var finish: CheckedContinuation<Void, Never>?
        var fail: CheckedContinuation<Void, Never>?
        var attempts = 0
        let service = SpeechService(synthesize: { _, _ in
            attempts += 1
            if attempts == 2 {
                await withCheckedContinuation { fail = $0 }
                throw SpeechError.httpStatus(429, retryAfter: 100)
            }
            return Data([1])
        }, play: { _ in await withCheckedContinuation { finish = $0 } }, stopPlayback: {})
        service.enqueue(String(repeating: "a", count: 6000), configuration: config)
        try await waitUntil { finish != nil && fail != nil }
        fail?.resume()
        try await waitUntil { service.resumeAt != nil }
        finish?.resume()
        try await waitUntil { !service.isBusy }
        XCTAssertEqual(service.pendingCount, 0)
    }

    func testCooldownLifecycleIsLoggedWithDeadline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var date = Date()
        let service = SpeechService(synthesize: { _, _ in throw SpeechError.httpStatus(429, retryAfter: 90) },
            play: { _ in }, stopPlayback: {}, diagnostics: SpeechDiagnostics(directory: directory), wallNow: { date })
        service.enqueue("private text", configuration: config)
        try await waitUntil { service.resumeAt != nil }
        date = date.addingTimeInterval(91)
        service.refreshCooldown()
        XCTAssertNil(service.resumeAt)
        let raw = try String(contentsOf: directory.appendingPathComponent("speech.jsonl"), encoding: .utf8)
        let entries = try raw.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        let started = try XCTUnwrap(entries.first { $0["event"] as? String == "cooldownStarted" })
        XCTAssertNotNil(started["resumeAt"])
        XCTAssertEqual(started["code"] as? Int, 429)
        XCTAssertEqual(entries.last?["event"] as? String, "cooldownEnded")
        XCTAssertFalse(raw.contains("private text"))
    }

    func testEarlierBuildLogsRestoreOnlyFutureTransientRetryAfter() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = SpeechDiagnostics(directory: directory)
        diagnostics.record(.requestFailed, session: UUID(), pending: 1,
                           failure: SpeechFailure(SpeechError.httpStatus(429, retryAfter: 81760)))
        // A long wait on a permanent error must not extend the cooldown.
        diagnostics.record(.requestFailed, session: UUID(), pending: 1,
                           failure: SpeechFailure(SpeechError.httpStatus(403, retryAfter: 90000)))
        let now = Date()
        let deadline = try XCTUnwrap(diagnostics.pendingCooldown(after: now))
        XCTAssertEqual(deadline.timeIntervalSince(now), 81760, accuracy: 2)
        let service = SpeechService(synthesize: { _, _ in XCTFail("No request during restored cooldown"); return Data() },
            play: { _ in }, stopPlayback: {}, diagnostics: diagnostics)
        XCTAssertEqual(service.resumeAt, deadline)
        service.enqueue("skip", configuration: config)
        XCTAssertFalse(service.isBusy)
        XCTAssertNil(diagnostics.pendingCooldown(after: now.addingTimeInterval(81761)))
    }
}
