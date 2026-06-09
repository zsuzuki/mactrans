import AVFoundation
import Foundation

enum AudioCaptureError: LocalizedError {
    case microphoneDenied
    case inputUnavailable

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Microphone access is not allowed."
        case .inputUnavailable:
            "No microphone input is available."
        }
    }
}

final class AudioCaptureService: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var isTapInstalled = false

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }

    func start(onSamples: @escaping @Sendable ([Float], Double) -> Void) throws {
        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw AudioCaptureError.inputUnavailable
        }

        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let sampleRate = format.sampleRate

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

    func stop() {
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        engine.stop()
    }
}
