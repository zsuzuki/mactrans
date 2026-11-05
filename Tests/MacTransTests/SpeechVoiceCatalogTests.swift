import Foundation
import XCTest
@testable import MacTrans

final class SpeechVoiceClientTests: XCTestCase {
    func testRequestUsesFixedHostHeaderAndEncodedPagination() throws {
        let request = try SpeechVoiceClient.request(apiKey: " test-key ", pageToken: "a&key=bad/?+")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.host, "generativelanguage.googleapis.com")
        XCTAssertEqual(request.url?.path, "/v1beta/voices")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.map(\.name), ["page_size", "page_token"])
        XCTAssertEqual(items.last?.value, "a&key=bad/?+")
        XCTAssertFalse(request.url!.absoluteString.contains("test-key"))
        XCTAssertNil(request.httpBody)
        for key in ["", " ", "key\nheader"] { XCTAssertThrowsError(try SpeechVoiceClient.request(apiKey: key)) }
    }

    func testPaginationDeduplicationMetadataAndEmptyList() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = SpeechVoiceClient(session: session)
        let voices = try await client.list(apiKey: "pages")
        XCTAssertEqual(voices.map(\.id), ["voice_one", "Kore"])
        XCTAssertEqual(voices.first?.displayName, "日本語の声")
        XCTAssertEqual(voices.first?.languageCode, "ja-JP")
        XCTAssertTrue(voices[0].matches("日本語"))
        XCTAssertTrue(voices[0].matches("JA-jp"))
        XCTAssertTrue(voices[0].matches("voice_one"))
        XCTAssertFalse(voices[0].matches("Kore"))
        let empty = try await client.list(apiKey: "empty")
        XCTAssertEqual(empty, [])
    }

    func testInvalidAndRepeatedPagesFailWithoutExposingResponses() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = SpeechVoiceClient(session: session)
        for key in ["denied", "loop", "invalid", "missing-id"] {
            do {
                _ = try await client.list(apiKey: key)
                XCTFail("Expected failure")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("private-response"))
                if key == "denied" {
                    guard case SpeechError.httpStatus(let status, _) = error else { return XCTFail("Expected HTTP error") }
                    XCTAssertEqual(status, 403)
                }
            }
        }
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VoiceStubProtocol.self]
        return URLSession(configuration: config)
    }
}

private final class VoiceStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let key = request.value(forHTTPHeaderField: "x-goog-api-key")
        let token = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page_token" }?.value
        let body: String
        switch key {
        case "denied": body = "private-response"
        case "invalid": body = "{\"voices\":\"private-response\"}"
        case "missing-id": body = "{\"voices\":[{\"display_name\":\"private-response\"}]}"
        case "loop": body = "{\"voices\":[],\"next_page_token\":\"again\"}"
        case "empty": body = "{}"
        default:
            if token == nil {
                body = "{\"voices\":[{\"id\":\"voice_one\",\"display_name\":\"日本語の声\",\"type\":\"prompted\",\"language_code\":\"ja-JP\",\"preview_audio\":\"ignored\"}],\"next_page_token\":\"next\"}"
            } else {
                body = "{\"voices\":[{\"id\":\"voice_one\"},{\"id\":\"Kore\",\"type\":\"prebuilt\"}]}"
            }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: key == "denied" ? 403 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class SpeechVoiceCatalogTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out")
    }

    func testKeyChangeDiscardsOldResponseAndLoadsNewList() async throws {
        var old: CheckedContinuation<[SpeechVoice], Never>?
        let catalog = SpeechVoiceCatalog { key in
            if key == "old" { return await withCheckedContinuation { old = $0 } }
            return [SpeechVoice(id: "new", displayName: nil, type: nil, languageCode: nil)]
        }
        catalog.load(apiKey: "old")
        try await waitUntil { old != nil }
        catalog.invalidate()
        XCTAssertFalse(catalog.isLoading)
        XCTAssertFalse(catalog.hasLoaded)
        catalog.load(apiKey: "new")
        old?.resume(returning: [SpeechVoice(id: "old", displayName: nil, type: nil, languageCode: nil)])
        try await waitUntil { !catalog.isLoading }
        XCTAssertEqual(catalog.voices.map(\.id), ["new"])
        XCTAssertNil(catalog.error)
    }

    func testRefreshFailurePreservesListAndRedactsUnknownErrors() async throws {
        var calls = 0
        let catalog = SpeechVoiceCatalog { _ in
            calls += 1
            if calls == 2 { throw NSError(domain: "private-response", code: 42, userInfo: [NSLocalizedDescriptionKey: "private-response"]) }
            return [SpeechVoice(id: "Kore", displayName: nil, type: nil, languageCode: nil)]
        }
        catalog.load(apiKey: "key")
        try await waitUntil { !catalog.isLoading }
        catalog.load(apiKey: "key")
        try await waitUntil { !catalog.isLoading }
        XCTAssertEqual(catalog.voices.map(\.id), ["Kore"])
        XCTAssertTrue(try XCTUnwrap(catalog.error).contains("42"))
        XCTAssertFalse(try XCTUnwrap(catalog.error).contains("private-response"))
        catalog.invalidate()
        XCTAssertTrue(catalog.voices.isEmpty)
        XCTAssertNil(catalog.error)
    }
}

@MainActor
final class SpeechVoiceIntegrationTests: XCTestCase {
    func testConfiguredAPIListsVoices() async throws {
        guard ProcessInfo.processInfo.environment["MACTRANS_TEST_VOICES"] == "1" else {
            throw XCTSkip("Opt in with MACTRANS_TEST_VOICES=1 for a read-only list request.")
        }
        let key = KeychainService.read(account: "googleTTSAPIKey")
        guard !key.isEmpty else { return XCTFail("No readable API key") }
        let voices = try await SpeechVoiceClient().list(apiKey: key)
        XCTAssertFalse(voices.isEmpty)
        let selected = UserDefaults(suiteName: "dev.local.MacTrans")?.string(forKey: "speechVoiceName")
        print("Voice list loaded: \(voices.count) total; \(voices.filter { $0.type == "prebuilt" }.count) prebuilt; saved selection present: \(voices.contains { $0.id == selected }).")
    }
}
