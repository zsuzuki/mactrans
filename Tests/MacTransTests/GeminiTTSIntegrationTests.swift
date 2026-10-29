import AVFoundation
import XCTest
@testable import MacTrans

@MainActor
final class GeminiTTSIntegrationTests: XCTestCase {
    func testConfiguredAPIProducesPlayableWAV() async throws {
        guard ProcessInfo.processInfo.environment["MACTRANS_TEST_GEMINI_TTS"] == "1" else {
            throw XCTSkip("Opt in with MACTRANS_TEST_GEMINI_TTS=1; sends a short test sentence using the app's saved key and voice.")
        }
        let preferences = AppPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: "dev.local.MacTrans")))
        guard !preferences.googleTTSAPIKey.isEmpty else {
            XCTFail("No readable Gemini API key in MacTrans Keychain.")
            return
        }
        let data = try await GeminiTTSClient().synthesize("こんにちは。読み上げの接続テストです。", configuration: preferences.speechConfiguration)
        let player = try AVAudioPlayer(data: data)
        XCTAssertGreaterThan(player.duration, 0)
        XCTAssertTrue(player.prepareToPlay())
        print("Gemini TTS returned playable WAV: \(data.count) bytes, \(player.duration) seconds.")
    }
}
