import AVFoundation
import Foundation
import OSLog

struct SpeechTiming: Identifiable {
    let id: Int
    let generationQueueSeconds: Double
    let generationSeconds: Double
    let playbackWaitSeconds: Double
    let totalWaitSeconds: Double
    let gapSeconds: Double?
}

@MainActor
final class SpeechService: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var pendingCount = 0
    @Published private(set) var generatingCount = 0
    @Published private(set) var readyCount = 0
    @Published private(set) var lastError: String?
    @Published private(set) var recentTimings: [SpeechTiming] = []

    private final class Job {
        enum Result {
            case ready(Data, started: Double, completed: Double)
            case failed(String)
        }
        let id: Int
        let text: String
        let configuration: SpeechConfiguration
        let enqueuedAt: Double
        let endsTranslation: Bool
        var result: Result?

        init(id: Int, text: String, configuration: SpeechConfiguration, enqueuedAt: Double, endsTranslation: Bool) {
            self.id = id
            self.text = text
            self.configuration = configuration
            self.enqueuedAt = enqueuedAt
            self.endsTranslation = endsTranslation
        }
    }

    private var queue: [Job] = []
    // Includes both generating and ready jobs, but excludes the playing job.
    private var ahead: [Job] = []
    private var playing: Job?
    private var synthesisTasks: [Int: Task<Void, Never>] = [:]
    private var playbackTask: Task<Void, Never>?
    private var generation = UUID()
    private var nextID = 0
    private var lastPlaybackEnd: Double?
    private let synthesize: (String, SpeechConfiguration) async throws -> Data
    private let play: (Data) async throws -> Void
    private let stopPlayback: () -> Void
    private let now: () -> Double
    private let maximumPending: Int
    private let prefetchCount: Int
    private let logger = Logger(subsystem: "dev.local.MacTrans", category: "Speech")

    init(maximumPending: Int = 20, prefetchCount: Int = 2,
         synthesize: @escaping (String, SpeechConfiguration) async throws -> Data = {
             try await GeminiTTSClient().synthesize($0, configuration: $1)
         },
         play: @escaping (Data) async throws -> Void,
         stopPlayback: @escaping () -> Void,
         now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.maximumPending = maximumPending
        self.prefetchCount = min(2, max(1, prefetchCount))
        self.synthesize = synthesize
        self.play = play
        self.stopPlayback = stopPlayback
        self.now = now
    }

    convenience init() {
        let output = SpeechAudioOutput()
        self.init(play: { try await output.play($0) }, stopPlayback: { output.stop() })
    }

    func enqueue(_ text: String, configuration: SpeechConfiguration) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard pendingCount < maximumPending else {
            lastError = SpeechError.queueFull.localizedDescription
            return
        }
        let chunks: [String]
        do { chunks = try GeminiTTSClient.chunks(text) }
        catch { lastError = error.localizedDescription; return }
        if !isBusy { lastError = nil }
        let enqueuedAt = now()
        for (index, chunk) in chunks.enumerated() {
            nextID += 1
            queue.append(Job(id: nextID, text: chunk, configuration: configuration,
                             enqueuedAt: enqueuedAt, endsTranslation: index == chunks.count - 1))
        }
        pendingCount += 1
        pump()
    }

    func stop() {
        generation = UUID()
        for task in synthesisTasks.values { task.cancel() }
        synthesisTasks.removeAll()
        playbackTask?.cancel()
        playbackTask = nil
        queue.removeAll()
        ahead.removeAll()
        playing = nil
        stopPlayback()
        pendingCount = 0
        lastPlaybackEnd = nil
        refreshState()
    }

    private func pump() {
        // Responses may finish out of order. Only the head can start playback.
        if playing == nil, let job = ahead.first, let result = job.result {
            switch result {
            case .failed(let message):
                lastError = message
                stop()
                return
            case .ready(let audio, let started, let completed):
                ahead.removeFirst()
                startPlayback(job, audio: audio, started: started, completed: completed)
            }
        }
        // A failed prefetched request waits its turn without cutting off the
        // current sentence, but must not cause further speculative requests.
        let hasFailure = ahead.contains { if case .failed = $0.result { return true }; return false }
        while !hasFailure, ahead.count < prefetchCount, !queue.isEmpty {
            let job = queue.removeFirst()
            ahead.append(job)
            startSynthesis(job)
        }
        refreshState()
    }

    private func startSynthesis(_ job: Job) {
        let current = generation
        synthesisTasks[job.id] = Task { [weak self] in
            guard let self else { return }
            let started = now()
            do {
                try Task.checkCancellation()
                let audio = try await synthesize(job.text, job.configuration)
                try Task.checkCancellation()
                guard current == generation else { return }
                let completed = now()
                job.result = .ready(audio, started: started, completed: completed)
                logger.info("Generated chunk=\(job.id) generation_s=\(completed - started) queue_s=\(started - job.enqueuedAt)")
            } catch {
                guard current == generation else { return }
                job.result = .failed(error.localizedDescription)
            }
            guard current == generation else { return }
            synthesisTasks[job.id] = nil
            pump()
        }
    }

    private func startPlayback(_ job: Job, audio: Data, started: Double, completed: Double) {
        playing = job
        let current = generation
        playbackTask = Task { [weak self] in
            guard let self, current == generation, !Task.isCancelled else { return }
            let playbackStart = now()
            let timing = SpeechTiming(id: job.id,
                generationQueueSeconds: max(0, started - job.enqueuedAt),
                generationSeconds: max(0, completed - started),
                playbackWaitSeconds: max(0, playbackStart - completed),
                totalWaitSeconds: max(0, playbackStart - job.enqueuedAt),
                gapSeconds: lastPlaybackEnd.map { max(0, playbackStart - $0) })
            recentTimings.append(timing)
            if recentTimings.count > 20 { recentTimings.removeFirst(recentTimings.count - 20) }
            logger.info("Playback chunk=\(job.id) generation_s=\(timing.generationSeconds) ready_wait_s=\(timing.playbackWaitSeconds) total_wait_s=\(timing.totalWaitSeconds) gap_s=\(timing.gapSeconds ?? -1)")
            do {
                try await play(audio)
                try Task.checkCancellation()
                guard current == generation else { return }
                lastPlaybackEnd = now()
                if job.endsTranslation { pendingCount -= 1 }
                playing = nil
                playbackTask = nil
                pump()
            } catch {
                guard current == generation else { return }
                lastError = error.localizedDescription
                stop()
            }
        }
    }

    private func refreshState() {
        generatingCount = synthesisTasks.count
        readyCount = ahead.filter { if case .ready = $0.result { return true }; return false }.count
        isBusy = pendingCount > 0
    }
}

@MainActor
private final class SpeechAudioOutput {
    private var player: AVAudioPlayer?

    func play(_ data: Data) async throws {
        try Task.checkCancellation()
        let audio: AVAudioPlayer
        do { audio = try AVAudioPlayer(data: data) }
        catch { throw SpeechError.invalidAudio }
        player = audio
        guard audio.play() else { player = nil; throw SpeechError.invalidAudio }
        defer {
            audio.stop()
            if player === audio { player = nil }
        }
        while audio.isPlaying {
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
    }

    func stop() {
        player?.stop()
        player = nil
    }
}
