import AVFoundation
import Foundation
import XCTest
@testable import MacTrans

final class GeminiTTSClientTests: XCTestCase {
    private let configuration = SpeechConfiguration(apiKey: " test-key ", voiceName: "voice_test_custom")

    func testRequestMatchesCLIInteractionsContract() throws {
        let config = SpeechConfiguration(apiKey: " test-key ", model: "custom-tts-model", voiceName: "voice_test_custom")
        let request = try GeminiTTSClient.request("翻訳結果", configuration: config)
        XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/interactions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 120)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? NSDictionary)
        let expected: NSDictionary = [
            "model": "custom-tts-model",
            "input": [["type": "user_input", "content": [["type": "text", "text": "翻訳結果"]]]],
            "response_format": ["type": "audio", "mime_type": "audio/wav"],
            "generation_config": ["speech_config": [["voice": "voice_test_custom"]]],
            "store": false, "stream": false
        ]
        XCTAssertEqual(body, expected)
        XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("test-key"))
    }

    func testMissingConfigurationFailsLocally() throws {
        XCTAssertThrowsError(try GeminiTTSClient.request("hello", configuration: .init(apiKey: " ", voiceName: "Kore")))
        XCTAssertThrowsError(try GeminiTTSClient.request("hello", configuration: .init(apiKey: "key", model: " ", voiceName: "Kore")))
        XCTAssertThrowsError(try GeminiTTSClient.request("hello", configuration: .init(apiKey: "key", voiceName: " ")))
        XCTAssertThrowsError(try GeminiTTSClient.request("hello", configuration: .init(apiKey: "key\nheader", voiceName: "Kore")))
    }

    func testMultibyteChunkingPreservesTextAndRespectsByteLimit() throws {
        let text = String(repeating: "日本語👨‍👩‍👧‍👦e\u{301}。", count: 600)
        let chunks = try GeminiTTSClient.chunks(text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.utf8.count <= 5_000 })
        XCTAssertThrowsError(try GeminiTTSClient.request(text, configuration: configuration))
        XCTAssertEqual(try GeminiTTSClient.chunks(""), [])
    }

    func testResponseDecodingAndHTTPErrorRedaction() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SpeechStubProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = GeminiTTSClient(session: session)
        let audio = try await client.synthesize("valid", configuration: configuration)
        XCTAssertEqual(audio, SpeechStubProtocol.wav)
        XCTAssertGreaterThan(try AVAudioPlayer(data: audio).duration, 0)
        for text in ["denied", "invalid", "empty", "wrong-mime", "not-wav", "truncated", "legacy"] {
            do {
                _ = try await client.synthesize(text, configuration: configuration)
                XCTFail("Expected failure for \(text)")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("secret-key"))
                if text == "denied" { XCTAssertTrue(error.localizedDescription.contains("403")) }
            }
        }
    }
}

private final class SpeechStubProtocol: URLProtocol, @unchecked Sendable {
    static let wav = Data(base64Encoded: "UklGRgQCAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YeABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let body = String(decoding: data, as: UTF8.self)
        let denied = body.contains("denied")
        let response = HTTPURLResponse(url: request.url!, statusCode: denied ? 403 : 200, httpVersion: nil, headerFields: nil)!
        let result: Data
        if denied { result = Data("secret-key".utf8) }
        else if body.contains("legacy") { result = Data("{\"audioContent\":\"AQID\"}".utf8) }
        else {
            var encoded = Self.wav.base64EncodedString()
            if body.contains("invalid") { encoded = "not-base64!" }
            if body.contains("empty") { encoded = "" }
            if body.contains("not-wav") { encoded = Data(repeating: 0, count: 64).base64EncodedString() }
            if body.contains("truncated") { encoded = Self.wav.prefix(20).base64EncodedString() }
            result = try! JSONSerialization.data(withJSONObject: ["steps": [
                ["type": "user_input", "content": [["type": "audio", "data": "ignored"]]],
                ["type": "model_output", "content": [
                    ["type": "text", "text": "ignored"],
                    ["type": "audio", "data": "earlier-invalid-block"],
                    ["type": "audio", "mime_type": body.contains("wrong-mime") ? "audio/mp3" : "audio/wav", "data": encoded]
                ]]
            ]])
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class SpeechServiceTests: XCTestCase {
    private let config = SpeechConfiguration(apiKey: "test", voiceName: "")

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out")
    }

    func testSpeechIsFIFOAndDoesNotDeduplicateRepeatedUtterances() async throws {
        var events: [String] = []
        let service = SpeechService(synthesize: { text, _ in
            events.append("request:\(text)")
            return Data(text.utf8)
        }, play: { data in
            let text = String(decoding: data, as: UTF8.self)
            events.append("start:\(text)")
            try await Task.sleep(for: .milliseconds(10))
            events.append("end:\(text)")
        }, stopPlayback: {})
        service.enqueue("A", configuration: config)
        service.enqueue("B", configuration: config)
        service.enqueue("A", configuration: config)
        try await waitUntil { !service.isBusy }
        XCTAssertEqual(events.filter { !$0.hasPrefix("request:") }, ["start:A", "end:A", "start:B", "end:B", "start:A", "end:A"])
        XCTAssertEqual(events.filter { $0.hasPrefix("request:") }, ["request:A", "request:B", "request:A"])
        XCTAssertEqual(service.pendingCount, 0)
    }

    func testStopDiscardsLateResponseAndDoesNotStopNewWorker() async throws {
        var suspended: CheckedContinuation<Data, Never>?
        var played: [String] = []
        let service = SpeechService(synthesize: { text, _ in
            if text == "old" { return await withCheckedContinuation { suspended = $0 } }
            return Data(text.utf8)
        }, play: { played.append(String(decoding: $0, as: UTF8.self)) }, stopPlayback: {})
        service.enqueue("old", configuration: config)
        service.enqueue("discard", configuration: config)
        try await waitUntil { suspended != nil }
        service.stop()
        XCTAssertFalse(service.isBusy)
        XCTAssertEqual(service.pendingCount, 0)
        service.enqueue("new", configuration: config)
        suspended?.resume(returning: Data("old".utf8))
        try await waitUntil { !service.isBusy }
        XCTAssertEqual(played, ["new"])
        XCTAssertNil(service.lastError)
    }

    func testStopDuringPlaybackCancelsQueuedAudio() async throws {
        var played: [String] = []
        var stops = 0
        let service = SpeechService(synthesize: { text, _ in Data(text.utf8) }, play: {
            played.append(String(decoding: $0, as: UTF8.self))
            try await Task.sleep(for: .seconds(10))
        }, stopPlayback: { stops += 1 })
        service.enqueue("first", configuration: config)
        service.enqueue("second", configuration: config)
        try await waitUntil { !played.isEmpty }
        service.stop()
        await Task.yield()
        XCTAssertEqual(played, ["first"])
        XCTAssertEqual(stops, 1)
        XCTAssertFalse(service.isBusy)
        XCTAssertNil(service.lastError)
    }

    func testFailureClearsBacklogAndAllowsNextRequest() async throws {
        var played: [String] = []
        let service = SpeechService(synthesize: { text, _ in
            if text == "fail" { throw SpeechError.httpStatus(429) }
            return Data(text.utf8)
        }, play: { played.append(String(decoding: $0, as: UTF8.self)) }, stopPlayback: {})
        service.enqueue("fail", configuration: config)
        service.enqueue("discard", configuration: config)
        try await waitUntil { !service.isBusy }
        XCTAssertTrue(try XCTUnwrap(service.lastError).contains("429"))
        XCTAssertTrue(played.isEmpty)
        service.enqueue("next", configuration: config)
        try await waitUntil { !service.isBusy }
        XCTAssertEqual(played, ["next"])
        XCTAssertNil(service.lastError)
    }

    func testBacklogIsBoundedAndReportsSkippedTranslation() async throws {
        var played: [String] = []
        let service = SpeechService(maximumPending: 2, synthesize: { text, _ in Data(text.utf8) },
                                    play: { played.append(String(decoding: $0, as: UTF8.self)) }, stopPlayback: {})
        for text in ["first", "second", "overflow"] { service.enqueue(text, configuration: config) }
        XCTAssertEqual(service.pendingCount, 2)
        XCTAssertNotNil(service.lastError)
        try await waitUntil { !service.isBusy }
        XCTAssertEqual(played, ["first", "second"])
    }

    func testPrefetchDuringPlaybackIsBoundedAndOutOfOrderResponsesStayFIFO() async throws {
        var requests: [String] = []
        var responses: [String: CheckedContinuation<Data, Never>] = [:]
        var played: [String] = []
        var finishes: [String: CheckedContinuation<Void, Never>] = [:]
        let service = SpeechService(synthesize: { text, _ in
            requests.append(text)
            return await withCheckedContinuation { responses[text] = $0 }
        }, play: { data in
            let text = String(decoding: data, as: UTF8.self)
            played.append(text)
            await withCheckedContinuation { finishes[text] = $0 }
        }, stopPlayback: {})
        service.enqueue("A", configuration: config)
        try await waitUntil { responses["A"] != nil }
        responses.removeValue(forKey: "A")?.resume(returning: Data("A".utf8))
        try await waitUntil { played == ["A"] }
        for text in ["B", "C", "D"] { service.enqueue(text, configuration: config) }
        try await waitUntil { requests.count == 3 }
        XCTAssertEqual(requests, ["A", "B", "C"])
        XCTAssertEqual(service.generatingCount, 2)
        responses.removeValue(forKey: "C")?.resume(returning: Data("C".utf8))
        try await waitUntil { service.readyCount == 1 }
        XCTAssertEqual(played, ["A"])
        XCTAssertEqual(requests.count, 3) // A ready buffer also occupies a prefetch slot.
        finishes.removeValue(forKey: "A")?.resume()
        responses.removeValue(forKey: "B")?.resume(returning: Data("B".utf8))
        try await waitUntil { played == ["A", "B"] && requests.count == 4 }
        XCTAssertEqual(service.pendingCount, 3)
        service.stop()
        // Even uncancellable completions after Stop must never play queued audio.
        responses.removeValue(forKey: "D")?.resume(returning: Data("D".utf8))
        finishes.removeValue(forKey: "B")?.resume()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(played, ["A", "B"])
        XCTAssertEqual(service.pendingCount, 0)
        XCTAssertEqual(service.readyCount, 0)
        XCTAssertEqual(service.generatingCount, 0)
        XCTAssertNil(service.lastError)
    }

    func testPrefetchFailureWaitsForCurrentSentenceAndCancelsRemainingWork() async throws {
        var finish: CheckedContinuation<Void, Never>?
        var failed = false
        var requests: [String] = []
        var played: [String] = []
        let service = SpeechService(synthesize: { text, _ in
            requests.append(text)
            if text == "fail" { failed = true; throw SpeechError.httpStatus(429) }
            return Data(text.utf8)
        }, play: { data in
            played.append(String(decoding: data, as: UTF8.self))
            await withCheckedContinuation { finish = $0 }
        }, stopPlayback: {})
        service.enqueue("A", configuration: config)
        try await waitUntil { finish != nil }
        service.enqueue("fail", configuration: config)
        try await waitUntil { failed && service.generatingCount == 0 }
        service.enqueue("discard", configuration: config)
        XCTAssertEqual(requests, ["A", "fail"])
        XCTAssertTrue(service.isBusy)
        XCTAssertNil(service.lastError)
        finish?.resume()
        try await waitUntil { !service.isBusy }
        XCTAssertEqual(played, ["A"])
        XCTAssertTrue(try XCTUnwrap(service.lastError).contains("429"))
    }

    func testTimingsSeparateGenerationBufferedWaitAndPlaybackGap() async throws {
        var clock = 0.0
        var responses: [String: CheckedContinuation<Data, Never>] = [:]
        var finishes: [String: CheckedContinuation<Void, Never>] = [:]
        let service = SpeechService(prefetchCount: 1, synthesize: { text, _ in
            await withCheckedContinuation { responses[text] = $0 }
        }, play: { data in
            let text = String(decoding: data, as: UTF8.self)
            await withCheckedContinuation { finishes[text] = $0 }
        }, stopPlayback: {}, now: { clock })
        service.enqueue("A", configuration: config)
        service.enqueue("B", configuration: config)
        service.enqueue("C", configuration: config)
        try await waitUntil { responses["A"] != nil }
        clock = 2
        responses.removeValue(forKey: "A")?.resume(returning: Data("A".utf8))
        try await waitUntil { finishes["A"] != nil && responses["B"] != nil }
        clock = 5
        responses.removeValue(forKey: "B")?.resume(returning: Data("B".utf8))
        try await waitUntil { service.readyCount == 1 }
        clock = 10
        finishes.removeValue(forKey: "A")?.resume()
        try await waitUntil { finishes["B"] != nil && responses["C"] != nil }
        clock = 12
        finishes.removeValue(forKey: "B")?.resume()
        try await waitUntil { service.pendingCount == 1 }
        clock = 15
        responses.removeValue(forKey: "C")?.resume(returning: Data("C".utf8))
        try await waitUntil { finishes["C"] != nil }
        let samples = service.recentTimings
        XCTAssertEqual(samples.map(\.generationSeconds), [2, 3, 5])
        XCTAssertEqual(samples.map(\.generationQueueSeconds), [0, 2, 10])
        XCTAssertEqual(samples.map(\.playbackWaitSeconds), [0, 5, 0])
        XCTAssertEqual(samples.map(\.totalWaitSeconds), [2, 10, 15])
        XCTAssertNil(samples[0].gapSeconds)
        XCTAssertEqual(samples[1].gapSeconds, 0)
        XCTAssertEqual(samples[2].gapSeconds, 3)
        finishes.removeValue(forKey: "C")?.resume()
        try await waitUntil { !service.isBusy }
    }

    func testLongTranslationChunksSharePendingCountAndHistoryIsBounded() async throws {
        var played: [String] = []
        let service = SpeechService(maximumPending: 30, synthesize: { text, _ in Data(text.utf8) },
                                   play: { played.append(String(decoding: $0, as: UTF8.self)) }, stopPlayback: {})
        let text = String(repeating: "あ", count: 4_000)
        service.enqueue(text, configuration: config)
        XCTAssertEqual(service.pendingCount, 1)
        try await waitUntil { !service.isBusy }
        XCTAssertEqual(played.joined(), text)
        XCTAssertEqual(played.count, 3)
        for _ in 0..<22 { service.enqueue("A", configuration: config) }
        try await waitUntil { !service.isBusy }
        XCTAssertEqual(service.recentTimings.count, 20)
        XCTAssertEqual(service.recentTimings.last?.id, 25)
        XCTAssertEqual(service.pendingCount, 0)
    }
}
