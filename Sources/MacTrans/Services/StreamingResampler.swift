import AVFoundation

/// Reuses the converter so fractional sample positions and its anti-aliasing
/// filter survive audio capture callback boundaries.
final class StreamingResampler {
    private var converter: AVAudioConverter?
    private var sourceRate: Double?
    private let targetRate = 16_000.0
    private var inputFrameCount: Int64 = 0
    private var outputFrameCount = 0

    func convert(_ samples: [Float], sampleRate: Double) throws -> [Float] {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw WhisperTranscriberError.runtimeFailed("Invalid audio input sample rate")
        }
        if let sourceRate, sourceRate != sampleRate {
            throw WhisperTranscriberError.runtimeFailed("Audio input format changed. Restart recording.")
        }
        if sourceRate == nil {
            sourceRate = sampleRate
            if sampleRate != targetRate {
                guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                                 channels: 1, interleaved: false),
                      let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate,
                                                 channels: 1, interleaved: false),
                      let created = AVAudioConverter(from: source, to: target) else {
                    throw WhisperTranscriberError.runtimeFailed("Cannot convert audio input to 16 kHz")
                }
                created.primeMethod = .none
                converter = created
            }
        }
        inputFrameCount += Int64(samples.count)
        guard let converter else {
            outputFrameCount += samples.count
            return samples
        }
        guard !samples.isEmpty else { return [] }
        let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(samples.count))!
        input.frameLength = input.frameCapacity
        samples.withUnsafeBufferPointer { pointer in
            input.floatChannelData![0].update(from: pointer.baseAddress!, count: samples.count)
        }
        let capacity = AVAudioFrameCount(ceil(Double(samples.count) * targetRate / sampleRate)) + 64
        let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity)!
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error else {
            throw WhisperTranscriberError.runtimeFailed(error?.localizedDescription ?? "Audio conversion failed")
        }
        outputFrameCount += Int(output.frameLength)
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    func finish() throws -> [Float] {
        guard let converter else { return [] }
        var result: [Float] = []
        while true {
            let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: 1024)!
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            guard status != .error else {
                throw WhisperTranscriberError.runtimeFailed(error?.localizedDescription ?? "Audio conversion failed")
            }
            result.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            if status == .endOfStream || output.frameLength == 0 { break }
        }
        // The converter flush includes filter padding. Do not extend the audio
        // clock beyond the duration that was actually captured.
        let expectedCount = Int(Double(inputFrameCount) * targetRate / converter.inputFormat.sampleRate)
        result = Array(result.prefix(max(0, expectedCount - outputFrameCount)))
        outputFrameCount += result.count
        return result
    }
}
