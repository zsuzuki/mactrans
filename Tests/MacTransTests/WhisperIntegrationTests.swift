import AVFoundation
import XCTest
@testable import MacTrans

/// Opt-in, local-model test: no microphone, network, or translation server.
/// MACTRANS_TEST_MODEL=/path/ggml-large-v3-turbo.bin
/// MACTRANS_TEST_AUDIO=/path/whisper.cpp/samples/jfk.wav
final class WhisperIntegrationTests: XCTestCase, @unchecked Sendable {
    func testRecordedEnglishRepeatedWithSilenceAndStopFlush() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let model = environment["MACTRANS_TEST_MODEL"],
              let audioPath = environment["MACTRANS_TEST_AUDIO"] else {
            throw XCTSkip("Set MACTRANS_TEST_MODEL and MACTRANS_TEST_AUDIO for the real-model check")
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let source = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let resampler = StreamingResampler()
        var speech = try resampler.convert(source, sampleRate: file.processingFormat.sampleRate)
        speech += try resampler.finish()
        let silence = [Float](repeating: 0, count: 16_000)
        // The second copy has no trailing silence: finish() must decode its tail.
        let input = silence + speech + silence + speech
        let transcriber = WhisperTranscriber()
        try await transcriber.configure(modelPath: model, sourceLanguage: "English")
        let started = Date()
        var commits: [String] = []
        var lastPartial = ""
        for offset in stride(from: 0, to: input.count, by: 4096) {
            let updates = try await transcriber.accept(
                samples: Array(input[offset..<min(offset + 4096, input.count)]), sampleRate: 16_000
            )
            for update in updates {
                commits += update.committed
                lastPartial = update.partialText
                if !update.committed.isEmpty { print("COMMIT at \(Double(offset) / 16_000)s: \(update.committed)") }
                if !update.partialText.isEmpty { print("PARTIAL: \(update.partialText)") }
            }
            if offset < 16_000 { XCTAssertTrue(commits.isEmpty, "Silence must not be transcribed") }
        }
        let final = try await transcriber.finish()
        for update in final {
            commits += update.committed
            lastPartial = update.partialText
            print("FINAL: \(update.committed)")
        }
        XCTAssertEqual(lastPartial, "")
        let secondFinish = try await transcriber.finish()
        XCTAssertTrue(secondFinish.isEmpty)
        await transcriber.reset()
        let normalized = commits.joined(separator: " ").lowercased()
            .split { $0.isWhitespace || $0.isPunctuation }.joined(separator: " ")
        for phrase in ["my fellow americans", "ask not what your country can do for you", "ask what you can do for your country"] {
            XCTAssertEqual(normalized.components(separatedBy: phrase).count - 1, 2,
                           "Expected each spoken phrase exactly twice: \(normalized)")
        }
        print("AUDIO_SECONDS=\(Double(input.count) / 16_000) PROCESSING_SECONDS=\(Date().timeIntervalSince(started))")
    }
}
