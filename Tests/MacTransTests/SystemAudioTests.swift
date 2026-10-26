import AVFoundation
import CoreMedia
import XCTest
@testable import MacTrans

final class SystemAudioTests: XCTestCase {
    private func sampleBuffer(interleaved: Bool, channels: [[Float]], sampleRate: Double = 48_000) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                                channels: AVAudioChannelCount(channels.count), interleaved: interleaved))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(channels[0].count)))
        pcm.frameLength = pcm.frameCapacity
        let data = try XCTUnwrap(pcm.floatChannelData)
        for channel in channels.indices {
            for frame in channels[channel].indices {
                if interleaved { data[0][frame * channels.count + channel] = channels[channel][frame] }
                else { data[channel][frame] = channels[channel][frame] }
            }
        }
        var description: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            asbd: format.streamDescription, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil,
            dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
            sampleCount: Int(pcm.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
        let result = try XCTUnwrap(sample)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(result,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: pcm.audioBufferList), noErr)
        return result
    }

    func testPlanarStereoIsAveragedAndCopied() throws {
        let audio = try SystemAudioDecoder.decode(sampleBuffer(interleaved: false,
            channels: [[1, 0.5, -1, 0], [0, -0.5, 1, 0.5]]))
        XCTAssertEqual(audio.samples, [0.5, 0, 0, 0.25])
        XCTAssertEqual(audio.sampleRate, 48_000)
    }

    func testInterleavedStereoPreservesFrameOrder() throws {
        let audio = try SystemAudioDecoder.decode(sampleBuffer(interleaved: true,
            channels: [[1, 0.5, -1, 0], [0, -0.5, 1, 0.5]]))
        XCTAssertEqual(audio.samples, [0.5, 0, 0, 0.25])
    }

    func testMonoPreservesSamplesAndActualSampleRate() throws {
        let audio = try SystemAudioDecoder.decode(sampleBuffer(interleaved: false,
            channels: [[0.25, -0.5, 0, 1]], sampleRate: 44_100))
        XCTAssertEqual(audio.samples, [0.25, -0.5, 0, 1])
        XCTAssertEqual(audio.sampleRate, 44_100)
    }

    func testStereoToTranscriberResamplerPreservesDuration() throws {
        let frames = 4_800
        let sample = try sampleBuffer(interleaved: false,
            channels: [[Float](repeating: 0.25, count: frames), [Float](repeating: 0.75, count: frames)])
        let audio = try SystemAudioDecoder.decode(sample)
        let resampler = StreamingResampler()
        var converted = try resampler.convert(audio.samples, sampleRate: audio.sampleRate)
        converted += try resampler.finish()
        XCTAssertEqual(converted.count, 1_600)
        XCTAssertEqual(converted[800], 0.5, accuracy: 0.01)
    }
}
