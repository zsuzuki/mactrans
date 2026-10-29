import AVFoundation
import Foundation

enum AudioCaptureError: LocalizedError {
    case microphoneDenied
    case inputUnavailable
    case processingOverrun
    case systemAudioDenied
    case displayUnavailable
    case unsupportedAudioFormat

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Microphone access is not allowed."
        case .inputUnavailable:
            "No microphone input is available."
        case .processingOverrun:
            "Transcription could not keep up with the audio input. Recording stopped; try closing other GPU-heavy apps."
        case .systemAudioDenied:
            "Allow MacTrans in System Settings > Privacy & Security > Screen & System Audio Recording, then quit and reopen MacTrans. If it is already enabled after an app update, turn it off and on again; if needed, remove the old entry and add the current MacTrans.app."
        case .displayUnavailable:
            "No display is available for system audio capture."
        case .unsupportedAudioFormat:
            "System audio returned an unsupported or invalid audio buffer. Recording stopped."
        }
    }
}

@MainActor
final class AudioCaptureService {
    private var engine: AVAudioEngine?
    private let systemAudio = SystemAudioCaptureService()
    private var isTapInstalled = false

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }

    func start(source: AudioInputSource,
               onSamples: @escaping @Sendable ([Float], Double) -> Void,
               onError: @escaping @Sendable (Error) -> Void) async throws {
        if source == .systemAudio {
            try await systemAudio.start(onSamples: onSamples, onError: onError)
            return
        }
        guard await requestPermission() else { throw AudioCaptureError.microphoneDenied }
        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw AudioCaptureError.inputUnavailable
        }
        let engine = AVAudioEngine()
        self.engine = engine

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let sampleRate = format.sampleRate
        guard sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.inputUnavailable
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            let channelCount = Int(format.channelCount)
            guard frameCount > 0, channelCount > 0 else { return }

            var samples = [Float](repeating: 0, count: frameCount)
            for channel in 0..<channelCount {
                let data = channelData[channel]
                for frame in 0..<frameCount {
                    samples[frame] += data[frame] / Float(channelCount)
                }
            }

            let capturedSamples = samples
            onSamples(capturedSamples, sampleRate)
        }
        isTapInstalled = true

        engine.prepare()
        try engine.start()
    }

    func stop() async {
        if let engine, isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        engine?.stop()
        engine = nil
        await systemAudio.stop()
    }
}
