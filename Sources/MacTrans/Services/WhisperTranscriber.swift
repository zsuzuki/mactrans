import Foundation
import WhisperBridge

enum WhisperTranscriberError: LocalizedError {
    case modelPathMissing
    case modelFileMissing(String)
    case runtimeFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelPathMissing:
            "Set a whisper.cpp model path in Settings before recording."
        case .modelFileMissing(let path):
            "Whisper model file was not found at \(path)."
        case .runtimeFailed(let message):
            message
        }
    }
}

// Access is confined to WhisperTranscriber. The wrapper also releases native
// resources when the actor is destroyed, without a nonisolated pointer access.
private final class WhisperRuntime: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    deinit { mt_whisper_destroy(pointer) }
}

actor WhisperTranscriber {
    private var runtime: WhisperRuntime?
    private var resampler = StreamingResampler()
    private var speech = SpeechActivityBuffer(silenceSeconds: 0.7)
    private var chunker = TextChunker(timeoutSeconds: 2.8, maxCharacters: 220)
    private var pendingFrames: [Float] = []
    private var lastDecodeSample: Int64 = 0
    private var finished = false

    func configure(modelPath: String, sourceLanguage: String, timeoutSeconds: Double = 2.8,
                   maxCharacters: Int = 220, mode: TextChunker.Mode = .balanced) throws {
        let trimmed = modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WhisperTranscriberError.modelPathMissing }
        guard FileManager.default.fileExists(atPath: trimmed) else {
            throw WhisperTranscriberError.modelFileMissing(trimmed)
        }
        guard let vadURL = Bundle.module.url(forResource: "ggml-silero-v6.2.0", withExtension: "bin") else {
            throw WhisperTranscriberError.runtimeFailed("The bundled Silero VAD model is missing. Rebuild MacTrans.")
        }
        runtime = nil
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let created = mt_whisper_create(trimmed, vadURL.path, Self.languageCode(for: sourceLanguage),
                                        true, Self.defaultThreadCount, &errorBuffer, Int32(errorBuffer.count))
        guard let created else {
            throw WhisperTranscriberError.runtimeFailed(Self.errorMessage(from: errorBuffer))
        }
        runtime = WhisperRuntime(created)
        chunker = TextChunker(timeoutSeconds: timeoutSeconds, maxCharacters: maxCharacters, mode: mode)
        speech = SpeechActivityBuffer(silenceSeconds: mode.silenceSeconds)
        resampler = StreamingResampler()
        pendingFrames.removeAll(keepingCapacity: true)
        lastDecodeSample = 0
        finished = false
    }

    func reset() {
        runtime = nil
        pendingFrames.removeAll()
        speech = SpeechActivityBuffer(silenceSeconds: chunker.mode.silenceSeconds)
        resampler = StreamingResampler()
        finished = true
    }

    func accept(samples: [Float], sampleRate: Double) throws -> [TranscriptionUpdate] {
        guard !finished, runtime != nil else {
            throw WhisperTranscriberError.runtimeFailed("Whisper runtime is not initialized")
        }
        return try process(resampler.convert(samples, sampleRate: sampleRate))
    }

    /// Called only after all captured buffers have been consumed. Includes the
    /// converter tail, incomplete VAD frame, and the final spoken words.
    func finish() throws -> [TranscriptionUpdate] {
        guard !finished, runtime != nil else { return [] }
        var updates = try process(resampler.finish())
        if !pendingFrames.isEmpty {
            let tail = pendingFrames
            pendingFrames.removeAll()
            var padded = tail
            padded.append(contentsOf: repeatElement(0, count: SpeechActivityBuffer.frameSize - tail.count))
            let probability = try probabilities(for: padded)[0]
            _ = speech.append(tail, probability: probability)
        }
        if speech.hasSpeech {
            updates.append(try decode(isFinal: true))
        } else {
            updates.append(TranscriptionUpdate())
        }
        speech.endInterval()
        finished = true
        return updates
    }

    private func process(_ samples: [Float]) throws -> [TranscriptionUpdate] {
        pendingFrames.append(contentsOf: samples)
        let count = pendingFrames.count / SpeechActivityBuffer.frameSize * SpeechActivityBuffer.frameSize
        guard count > 0 else { return [] }
        let complete = Array(pendingFrames.prefix(count))
        pendingFrames.removeFirst(count)
        let probabilities = try probabilities(for: complete)
        var updates: [TranscriptionUpdate] = []
        for (index, probability) in probabilities.enumerated() {
            let start = index * SpeechActivityBuffer.frameSize
            let frame = Array(complete[start..<(start + SpeechActivityBuffer.frameSize)])
            if speech.append(frame, probability: probability) {
                if speech.hasSpeech { updates.append(try decode(isFinal: true)) }
                speech.endInterval()
            }
            // Never discard unrecognized audio just to enforce a rolling window.
            // First advance at a decoded word boundary, retaining the trailing audio.
            if speech.hasSpeech && speech.samples.count >= 24 * 16_000 &&
                speech.cursor - lastDecodeSample >= 24_000 {
                updates.append(try decode(isFinal: false, forceBoundary: true))
                speech.discardAudio(before: chunker.committedThrough)
            }
            if speech.samples.count >= 28 * 16_000 {
                throw WhisperTranscriberError.runtimeFailed("Unable to find a speech boundary. Restart recording.")
            }
        }
        if speech.hasSpeech && speech.samples.count >= 2 * 16_000 &&
            speech.cursor - lastDecodeSample >= 24_000 {
            updates.append(try decode(isFinal: false))
            if speech.samples.count >= 12 * 16_000 {
                speech.discardAudio(before: chunker.committedThrough)
            }
        }
        return updates
    }

    private func probabilities(for samples: [Float]) throws -> [Float] {
        guard let runtime else {
            throw WhisperTranscriberError.runtimeFailed("Whisper runtime is not initialized")
        }
        var values = [Float](repeating: 0, count: samples.count / SpeechActivityBuffer.frameSize)
        let count = samples.withUnsafeBufferPointer { input in
            mt_whisper_vad(runtime.pointer, input.baseAddress, Int32(samples.count), &values, Int32(values.count))
        }
        guard count == values.count, values.allSatisfy({ $0.isFinite }) else {
            throw WhisperTranscriberError.runtimeFailed("Voice activity detection failed")
        }
        return values
    }

    private func decode(isFinal: Bool, forceBoundary: Bool = false) throws -> TranscriptionUpdate {
        guard let runtime else {
            throw WhisperTranscriberError.runtimeFailed("Whisper runtime is not initialized")
        }
        var samples = speech.samples
        // Short utterances still need enough input for Whisper's encoder.
        if samples.count < 16_000 { samples.append(contentsOf: repeatElement(0, count: 16_000 - samples.count)) }
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let count = samples.withUnsafeBufferPointer { input in
            mt_whisper_transcribe(runtime.pointer, input.baseAddress, Int32(samples.count),
                                  &errorBuffer, Int32(errorBuffer.count))
        }
        guard count >= 0 else {
            throw WhisperTranscriberError.runtimeFailed(Self.errorMessage(from: errorBuffer))
        }
        lastDecodeSample = speech.cursor
        var words: [TimedWord] = []
        for index in 0..<count {
            guard let pointer = mt_whisper_word_text(runtime.pointer, index) else { continue }
            let text = String(cString: pointer)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let start = speech.startSample + max(0, mt_whisper_word_start_ms(runtime.pointer, index)) * 16
            let end = speech.startSample + max(0, mt_whisper_word_end_ms(runtime.pointer, index)) * 16
            guard start < speech.cursor else { continue }
            words.append(TimedWord(text: text, startSample: start,
                                   endSample: min(speech.cursor, max(start, end))))
        }
        return chunker.accept(words, audioEnd: speech.cursor, isFinal: isFinal, forceBoundary: forceBoundary)
    }

    private static var defaultThreadCount: Int32 {
        Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
    }

    private static func languageCode(for language: String) -> String {
        switch language.lowercased() {
        case "japanese": "ja"
        case "chinese": "zh"
        case "korean": "ko"
        case "auto": "auto"
        default: "en"
        }
    }

    private static func errorMessage(from buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
