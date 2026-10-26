import CoreMedia
import ScreenCaptureKit

@MainActor
final class SystemAudioCaptureService {
    private var stream: SCStream?
    private var output: SystemAudioOutput?
    private let sampleQueue = DispatchQueue(label: "dev.local.MacTrans.systemAudio")
    private var stopTask: Task<Void, Never>?

    func start(onSamples: @escaping @Sendable ([Float], Double) -> Void,
               onError: @escaping @Sendable (Error) -> Void) async throws {
        do {
            // This requests ScreenCaptureKit permission only. Microphone access
            // is neither requested nor used for this input source.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else { throw AudioCaptureError.displayUnavailable }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            // No screen output is registered or saved. Minimize the unused
            // video portion of the macOS 14 display-backed stream.
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
            configuration.showsCursor = false
            let output = SystemAudioOutput(onSamples: onSamples, onError: onError)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
            self.output = output
            self.stream = stream
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()
        } catch {
            await stop()
            let nsError = error as NSError
            if nsError.domain == SCStreamErrorDomain && nsError.code == SCStreamError.Code.userDeclined.rawValue {
                throw AudioCaptureError.systemAudioDenied
            }
            throw error
        }
    }

    func stop() async {
        // A user stop and an asynchronous stream failure may overlap.
        if let stopTask { await stopTask.value; return }
        guard let stream, let output else { return }
        let queue = sampleQueue
        let task = Task {
            do { try await stream.stopCapture() }
            catch { output.report(error) }
            try? stream.removeStreamOutput(output, type: .audio)
            // Deliver already queued samples before AppModel finishes its stream.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async { continuation.resume() }
            }
        }
        stopTask = task
        await task.value
        self.stream = nil
        self.output = nil
        stopTask = nil
    }
}

// Immutable callbacks can be called from ScreenCaptureKit's delegate thread
// and the serial sample queue. No AppModel state is touched on either thread.
private final class SystemAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let onSamples: @Sendable ([Float], Double) -> Void
    private let onError: @Sendable (Error) -> Void

    init(onSamples: @escaping @Sendable ([Float], Double) -> Void,
         onError: @escaping @Sendable (Error) -> Void) {
        self.onSamples = onSamples
        self.onError = onError
    }

    func report(_ error: Error) { onError(error) }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError(error)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer),
              sampleBuffer.numSamples > 0 else { return }
        do {
            let audio = try SystemAudioDecoder.decode(sampleBuffer)
            onSamples(audio.samples, audio.sampleRate)
        } catch {
            onError(error)
        }
    }
}

enum SystemAudioDecoder {
    static func decode(_ sampleBuffer: CMSampleBuffer) throws -> (samples: [Float], sampleRate: Double) {
        guard let description = sampleBuffer.formatDescription,
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              format.mBitsPerChannel == 32,
              format.mChannelsPerFrame > 0, format.mSampleRate > 0 else {
            throw AudioCaptureError.unsupportedAudioFormat
        }
        let frameCount = sampleBuffer.numSamples
        guard frameCount > 0 else { return ([], format.mSampleRate) }
        let channelCount = Int(format.mChannelsPerFrame)
        return try sampleBuffer.withAudioBufferList { buffers, _ in
            var samples = [Float](repeating: 0, count: frameCount)
            var channelsRead = 0
            for buffer in buffers {
                let channels = Int(buffer.mNumberChannels)
                guard channels > 0, let data = buffer.mData,
                      Int(buffer.mDataByteSize) >= frameCount * channels * MemoryLayout<Float>.size else {
                    throw AudioCaptureError.unsupportedAudioFormat
                }
                let values = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<frameCount {
                    for channel in 0..<channels {
                        samples[frame] += values[frame * channels + channel] / Float(channelCount)
                    }
                }
                channelsRead += channels
            }
            guard channelsRead == channelCount else { throw AudioCaptureError.unsupportedAudioFormat }
            // Own the samples before the retained CMSampleBuffer memory expires.
            return (samples, format.mSampleRate)
        }
    }
}
