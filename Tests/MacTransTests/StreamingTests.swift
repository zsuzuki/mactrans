import XCTest
@testable import MacTrans

final class TextChunkerTests: XCTestCase {
    private func words(_ text: String, offset: Int64 = 0) -> [TimedWord] {
        text.split(separator: " ").enumerated().map { index, word in
            let start = offset + Int64(index) * 4_800
            return TimedWord(text: " " + word, startSample: start, endSample: start + 4_800)
        }
    }

    func testOnlyUncommittedSuffixIsDisplayedIncludingAfterOldTextChanges() {
        var chunker = TextChunker(timeoutSeconds: 2.8, maxCharacters: 220)
        let input = words("The release is ready. We can test")
        XCTAssertTrue(chunker.accept(input, audioEnd: 40_000, isFinal: false).committed.isEmpty)
        let second = chunker.accept(input, audioEnd: 50_000, isFinal: false)
        XCTAssertEqual(second.committed, ["The release is ready."])
        XCTAssertEqual(second.partialText, "We can test")
        var revised = input
        revised[0].text = " Our"
        let third = chunker.accept(revised, audioEnd: 60_000, isFinal: false)
        XCTAssertTrue(third.committed.isEmpty)
        XCTAssertEqual(third.partialText, "We can test")
    }

    func testExactRepeatedUpdateDoesNotReturnCommittedTextAsPartial() {
        var chunker = TextChunker(timeoutSeconds: 2.8, maxCharacters: 220)
        let input = words("The release is ready.")
        XCTAssertEqual(chunker.accept(input, audioEnd: 24_000, isFinal: true).committed.count, 1)
        let repeated = chunker.accept(input, audioEnd: 32_000, isFinal: false)
        XCTAssertTrue(repeated.committed.isEmpty)
        XCTAssertEqual(repeated.partialText, "")
    }

    func testChangedHypothesisMustAgreeAgain() {
        var chunker = TextChunker(timeoutSeconds: 2.8, maxCharacters: 220)
        _ = chunker.accept(words("I think the deployment failed. Next"), audioEnd: 40_000, isFinal: false)
        let revision = words("I think our deployment succeeded. Next")
        XCTAssertTrue(chunker.accept(revision, audioEnd: 48_000, isFinal: false).committed.isEmpty)
        XCTAssertEqual(chunker.accept(revision, audioEnd: 56_000, isFinal: false).committed,
                       ["I think our deployment succeeded."])
    }

    func testTimeoutCannotCommitShortUnfinishedPhrase() {
        var chunker = TextChunker(timeoutSeconds: 0.8, maxCharacters: 220, mode: .stable)
        let input = words("Let's review the")
        for end in stride(from: Int64(32_000), through: 320_000, by: 32_000) {
            XCTAssertTrue(chunker.accept(input, audioEnd: end, isFinal: false).committed.isEmpty)
        }
        XCTAssertEqual(chunker.accept(input, audioEnd: 330_000, isFinal: true).committed, ["Let's review the"])
    }

    func testSameAudioDoesNotCountTwiceAndStableModeRequiresThreeUpdates() {
        var chunker = TextChunker(timeoutSeconds: 2.8, maxCharacters: 220, mode: .stable)
        let input = words("The release is ready. Next")
        for _ in 0..<5 {
            XCTAssertTrue(chunker.accept(input, audioEnd: 48_000, isFinal: false).committed.isEmpty)
        }
        XCTAssertTrue(chunker.accept(input, audioEnd: 56_000, isFinal: false).committed.isEmpty)
        XCTAssertEqual(chunker.accept(input, audioEnd: 64_000, isFinal: false).committed.count, 1)
    }

    func testActualRepeatedSpeechAtALaterTimeIsPreserved() {
        var chunker = TextChunker(timeoutSeconds: 2.8, maxCharacters: 220)
        let first = chunker.accept(words("Yes we can."), audioEnd: 20_000, isFinal: true)
        let second = chunker.accept(words("Yes we can.", offset: 32_000), audioEnd: 52_000, isFinal: true)
        XCTAssertEqual(first.committed, second.committed)
        XCTAssertEqual(second.committed, ["Yes we can."])
    }

    func testTimestampJitterAtConfirmedBoundaryDoesNotRepeatLastWord() {
        var chunker = TextChunker(timeoutSeconds: 2.8, maxCharacters: 220)
        let input = words("The release is ready. Next step")
        _ = chunker.accept(input, audioEnd: 40_000, isFinal: false)
        _ = chunker.accept(input, audioEnd: 48_000, isFinal: false)
        var jittered = input
        jittered[3].startSample += 1_600
        jittered[3].endSample += 1_600
        XCTAssertEqual(chunker.accept(jittered, audioEnd: 56_000, isFinal: false).partialText, "Next step")
    }

    func testFinalEmptyHypothesisClearsPartialAndConsumesInterval() {
        var chunker = TextChunker(timeoutSeconds: 2.8, maxCharacters: 220)
        _ = chunker.accept(words("Wrong hypothesis"), audioEnd: 24_000, isFinal: false)
        let final = chunker.accept([], audioEnd: 32_000, isFinal: true)
        XCTAssertTrue(final.committed.isEmpty)
        XCTAssertEqual(final.partialText, "")
        XCTAssertEqual(chunker.committedThrough, 32_000)
    }

    func testConfirmedWordsAreAnchoredWhenTimestampJitterCrossesCutoff() {
        var chunker = TextChunker(timeoutSeconds: 2.8, maxCharacters: 220)
        let input = words("The release is ready. Next step")
        _ = chunker.accept(input, audioEnd: 40_000, isFinal: false)
        _ = chunker.accept(input, audioEnd: 48_000, isFinal: false)
        var jittered = input
        jittered[3].startSample += 4_800
        jittered[3].endSample += 4_800
        XCTAssertEqual(chunker.accept(jittered, audioEnd: 56_000, isFinal: false).partialText, "Next step")
    }

    func testImmediateRepeatedWordsAreNotRemovedByTextAnchor() {
        var chunker = TextChunker(timeoutSeconds: 2.8, maxCharacters: 220)
        _ = chunker.accept(words("Go now."), audioEnd: 9_600, isFinal: true)
        XCTAssertEqual(chunker.accept(words("Go now.", offset: 9_600), audioEnd: 19_200, isFinal: true).committed,
                       ["Go now."])
    }

    func testLongWindowKeepsTrailingAudioUncommitted() {
        var chunker = TextChunker(timeoutSeconds: 2.8, maxCharacters: 800)
        let input = words("one two three four five six seven eight nine ten")
        let result = chunker.accept(input, audioEnd: 48_000, isFinal: false, forceBoundary: true)
        XCTAssertEqual(result.committed, ["one two three four five six seven"])
        XCTAssertEqual(result.partialText, "eight nine ten")
        XCTAssertEqual(chunker.committedThrough, 33_600)
    }

    func testNewWordAtBoundaryAndShortFinalUtteranceAreNotLost() {
        var chunker = TextChunker(timeoutSeconds: 2.8, maxCharacters: 220)
        _ = chunker.accept(words("Hello."), audioEnd: 4_800, isFinal: true)
        let next = chunker.accept(words("Yes.", offset: 4_800), audioEnd: 9_600, isFinal: true)
        XCTAssertEqual(next.committed, ["Yes."])
    }
}

final class SpeechActivityBufferTests: XCTestCase {
    private let frame = [Float](repeating: 0.1, count: 512)

    func testSilenceDoesNotStartSpeech() {
        var buffer = SpeechActivityBuffer(silenceSeconds: 0.7)
        for _ in 0..<1_000 { XCTAssertFalse(buffer.append(frame, probability: 0.01)) }
        XCTAssertFalse(buffer.hasSpeech)
        XCTAssertTrue(buffer.samples.isEmpty)
        XCTAssertEqual(buffer.cursor, 512_000)
    }

    func testSpeechEndpointUsesAudioTimeAndIncludesPreRoll() {
        var buffer = SpeechActivityBuffer(silenceSeconds: 0.7)
        for _ in 0..<20 { _ = buffer.append(frame, probability: 0.01) }
        for _ in 0..<10 { XCTAssertFalse(buffer.append(frame, probability: 0.9)) }
        XCTAssertTrue(buffer.hasSpeech)
        XCTAssertEqual(buffer.startSample, 20 * 512 - 3_200)
        for _ in 0..<21 { XCTAssertFalse(buffer.append(frame, probability: 0.1)) }
        XCTAssertTrue(buffer.append(frame, probability: 0.1))
        XCTAssertEqual(Int64(buffer.samples.count), buffer.cursor - buffer.startSample)
    }

    func testBriefPauseDoesNotSplitSpeechAndNoiseBurstDoesNotQualify() {
        var buffer = SpeechActivityBuffer(silenceSeconds: 0.7)
        _ = buffer.append(frame, probability: 0.9)
        XCTAssertFalse(buffer.hasSpeech)
        for _ in 0..<22 { _ = buffer.append(frame, probability: 0.01) }
        XCTAssertFalse(buffer.hasSpeech)
        buffer.endInterval()
        for _ in 0..<10 { _ = buffer.append(frame, probability: 0.9) }
        for _ in 0..<10 { XCTAssertFalse(buffer.append(frame, probability: 0.1)) }
        XCTAssertFalse(buffer.append(frame, probability: 0.9))
        XCTAssertTrue(buffer.hasSpeech)
    }

    func testTrimmingPreservesAbsoluteClockAndUncommittedSamples() {
        var buffer = SpeechActivityBuffer(silenceSeconds: 0.7)
        for _ in 0..<100 { _ = buffer.append(frame, probability: 0.9) }
        let cursor = buffer.cursor
        buffer.discardAudio(before: 16_000)
        XCTAssertEqual(buffer.cursor, cursor)
        XCTAssertEqual(buffer.startSample, 16_000)
        XCTAssertEqual(buffer.samples.count, 35_200)
        XCTAssertTrue(buffer.hasSpeech)
        buffer.endInterval()
        XCTAssertFalse(buffer.isActive)
        XCTAssertEqual(buffer.cursor, cursor)
    }
}

final class StreamingResamplerTests: XCTestCase {
    func testCallbackBoundariesPreserveAudioAt44100And48000() throws {
        for rate in [44_100.0, 48_000.0] {
            let input = (0..<Int(rate)).map { Float(sin(Double($0) * 2 * .pi * 440 / rate)) }
            let one = StreamingResampler()
            var expected = try one.convert(input, sampleRate: rate)
            expected += try one.finish()
            let many = StreamingResampler()
            var actual: [Float] = []
            for start in stride(from: 0, to: input.count, by: 997) {
                actual += try many.convert(Array(input[start..<min(start + 997, input.count)]), sampleRate: rate)
            }
            actual += try many.finish()
            XCTAssertEqual(actual.count, expected.count)
            XCTAssertEqual(actual.count, 16_000, accuracy: 2)
            let error = zip(actual, expected).map { abs($0 - $1) }.max() ?? 0
            XCTAssertLessThan(error, 0.0001)
        }
    }

    func testInputFormatChangeIsReportedInsteadOfCorruptingAudioClock() throws {
        let converter = StreamingResampler()
        _ = try converter.convert([Float](repeating: 0, count: 4096), sampleRate: 48_000)
        XCTAssertThrowsError(try converter.convert([0], sampleRate: 44_100))
    }
}
