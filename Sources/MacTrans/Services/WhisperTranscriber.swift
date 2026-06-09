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

struct TranscriptionUpdate: Sendable {
    var text: String
    var isFinal: Bool
}

actor WhisperTranscriber {
    private var modelPath: String = ""
    private var accumulatedSamples: [Float] = []
    private var sampleRate: Double = 16_000
    private var lastEmitDate = Date()
    private var runtime: OpaquePointer?

    func configure(modelPath: String, sourceLanguage: String) throws {
        let trimmed = modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WhisperTranscriberError.modelPathMissing
        }
        guard FileManager.default.fileExists(atPath: trimmed) else {
            throw WhisperTranscriberError.modelFileMissing(trimmed)
        }

        if let runtime {
            mt_whisper_destroy(runtime)
            self.runtime = nil
        }

        var errorBuffer = [CChar](repeating: 0, count: 512)
        let language = Self.languageCode(for: sourceLanguage)
        let created = trimmed.withCString { modelCString in
            language.withCString { languageCString in
                mt_whisper_create(modelCString, languageCString, true, Self.defaultThreadCount, &errorBuffer, Int32(errorBuffer.count))
            }
        }
        guard let created else {
            throw WhisperTranscriberError.runtimeFailed(Self.errorMessage(from: errorBuffer))
        }

        runtime = created
        self.modelPath = trimmed
        accumulatedSamples.removeAll(keepingCapacity: true)
        lastEmitDate = Date()
    }

    func reset() {
        accumulatedSamples.removeAll(keepingCapacity: true)
        lastEmitDate = Date()
        if let runtime {
            mt_whisper_reset(runtime)
        }
    }

    func accept(samples: [Float], sampleRate: Double) async throws -> TranscriptionUpdate? {
        guard !modelPath.isEmpty else {
            throw WhisperTranscriberError.modelPathMissing
        }
        guard let runtime else {
            throw WhisperTranscriberError.runtimeFailed("Whisper runtime is not initialized")
        }

        self.sampleRate = sampleRate
        accumulatedSamples.append(contentsOf: samples)

        let maxSamples = Int(sampleRate * 10)
        if accumulatedSamples.count > maxSamples {
            accumulatedSamples.removeFirst(accumulatedSamples.count - maxSamples)
        }

        guard accumulatedSamples.count >= Int(sampleRate * 3.0) else {
            return nil
        }
        guard Date().timeIntervalSince(lastEmitDate) >= 1.5 else {
            return nil
        }
        lastEmitDate = Date()

        let resampled = Self.resampleTo16k(accumulatedSamples, sourceRate: sampleRate)
        var isFinal = false
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let textPointer = resampled.withUnsafeBufferPointer { buffer in
            mt_whisper_transcribe(runtime, buffer.baseAddress, Int32(buffer.count), &isFinal, &errorBuffer, Int32(errorBuffer.count))
        }
        guard let textPointer else {
            throw WhisperTranscriberError.runtimeFailed(Self.errorMessage(from: errorBuffer))
        }
        defer { mt_whisper_free_string(textPointer) }

        let text = String(cString: textPointer).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }

        return TranscriptionUpdate(text: text, isFinal: isFinal)
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

    private static func resampleTo16k(_ samples: [Float], sourceRate: Double) -> [Float] {
        guard sourceRate > 0, abs(sourceRate - 16_000) > 1 else {
            return samples
        }

        let ratio = sourceRate / 16_000
        let outputCount = max(1, Int(Double(samples.count) / ratio))
        return (0..<outputCount).map { outputIndex in
            let sourcePosition = Double(outputIndex) * ratio
            let lower = min(samples.count - 1, Int(sourcePosition))
            let upper = min(samples.count - 1, lower + 1)
            let fraction = Float(sourcePosition - Double(lower))
            return samples[lower] * (1 - fraction) + samples[upper] * fraction
        }
    }

    private static func errorMessage(from buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
