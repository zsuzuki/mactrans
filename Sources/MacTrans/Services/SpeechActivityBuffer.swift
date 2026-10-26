import Foundation

/// Audio clock and VAD endpointing, independent of inference speed.
struct SpeechActivityBuffer {
    static let sampleRate = 16_000
    static let frameSize = 512
    private let preRollSamples = 3_200
    private let minimumSpeechSamples = 2_560
    var silenceSamples: Int64
    private(set) var cursor: Int64 = 0
    private(set) var startSample: Int64 = 0
    private(set) var samples: [Float] = []
    private(set) var speechSamples = 0
    private var preRoll: [Float] = []
    private var lastSpeechEnd: Int64 = 0
    private var active = false

    var hasSpeech: Bool { active && speechSamples >= minimumSpeechSamples }
    var isActive: Bool { active }

    init(silenceSeconds: Double) {
        silenceSamples = Int64(silenceSeconds * Double(Self.sampleRate))
    }

    /// Returns true when an active interval has ended. Caller decodes it, then
    /// calls endInterval(). Short noise bursts are discarded without ASR.
    mutating func append(_ frame: [Float], probability: Float) -> Bool {
        let speaking = probability >= (active ? 0.35 : 0.6)
        if !active && speaking {
            active = true
            startSample = cursor - Int64(preRoll.count)
            samples = preRoll
            speechSamples = 0
        }
        cursor += Int64(frame.count)
        if active {
            samples.append(contentsOf: frame)
            if speaking {
                speechSamples += frame.count
                lastSpeechEnd = cursor
            }
        }
        preRoll.append(contentsOf: frame)
        if preRoll.count > preRollSamples { preRoll.removeFirst(preRoll.count - preRollSamples) }
        return active && cursor - lastSpeechEnd >= silenceSamples
    }

    mutating func endInterval() {
        samples.removeAll(keepingCapacity: true)
        speechSamples = 0
        active = false
        startSample = cursor
    }

    mutating func discardAudio(before sample: Int64) {
        let count = Int(max(0, min(sample - startSample, Int64(samples.count))))
        samples.removeFirst(count)
        startSample += Int64(count)
    }
}
