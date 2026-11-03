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
    @Published private(set) var retryingCount = 0
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
    private var retryingJobs: Set<Int> = []
    private var generation = UUID()
    private var nextID = 0
    private var lastPlaybackEnd: Double?
    private let synthesize: (String, SpeechConfiguration) async throws -> Data
    private let play: (Data) async throws -> Void
    private let stopPlayback: () -> Void
    private let now: () -> Double
    private let maximumPending: Int
    private let prefetchCount: Int
    let diagnostics: SpeechDiagnostics
    private let retryPolicy: SpeechRetryPolicy
    private let retrySleep: (Double) async throws -> Void
    private let logger = Logger(subsystem: "dev.local.MacTrans", category: "Speech")

    init(maximumPending: Int = 20, prefetchCount: Int = 2,
         synthesize: @escaping (String, SpeechConfiguration) async throws -> Data = {
             try await GeminiTTSClient().synthesize($0, configuration: $1)
         },
         play: @escaping (Data) async throws -> Void,
         stopPlayback: @escaping () -> Void,
         now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         diagnostics: SpeechDiagnostics = .disabled,
         retryPolicy: SpeechRetryPolicy = .init(),
         retrySleep: @escaping (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.maximumPending = maximumPending
        self.prefetchCount = min(2, max(1, prefetchCount))
        self.synthesize = synthesize
        self.play = play
        self.stopPlayback = stopPlayback
        self.now = now
        self.diagnostics = diagnostics
        self.retryPolicy = retryPolicy
        self.retrySleep = retrySleep
        diagnostics.record(.started, session: generation, pending: 0)
    }

    convenience init() {
        let output = SpeechAudioOutput()
        self.init(play: { try await output.play($0) }, stopPlayback: { output.stop() }, diagnostics: .shared)
    }

    func enqueue(_ text: String, configuration: SpeechConfiguration) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard pendingCount < maximumPending else {
            lastError = SpeechError.queueFull.localizedDescription
            diagnostics.record(.queueRejected, session: generation, pending: pendingCount, failure: SpeechFailure(SpeechError.queueFull))
            return
        }
        let chunks: [String]
        do { chunks = try GeminiTTSClient.chunks(text) }
        catch {
            lastError = error.localizedDescription
            diagnostics.record(.queueRejected, session: generation, pending: pendingCount, failure: SpeechFailure(error))
            return
        }
        if !isBusy { lastError = nil }
        let enqueuedAt = now()
        for (index, chunk) in chunks.enumerated() {
            nextID += 1
            queue.append(Job(id: nextID, text: chunk, configuration: configuration,
                             enqueuedAt: enqueuedAt, endsTranslation: index == chunks.count - 1))
            diagnostics.record(.queued, session: generation, chunk: nextID, pending: pendingCount + 1)
        }
        pendingCount += 1
        pump()
    }

    func stop() {
        diagnostics.record(.stopped, session: generation, pending: pendingCount)
        generation = UUID()
        for task in synthesisTasks.values { task.cancel() }
        synthesisTasks.removeAll()
        retryingJobs.removeAll()
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
                let audio = try await synthesizeWithRetry(job, session: current)
                try Task.checkCancellation()
                guard current == generation else { return }
                let completed = now()
                job.result = .ready(audio, started: started, completed: completed)
                logger.info("Generated chunk=\(job.id) generation_s=\(completed - started) queue_s=\(started - job.enqueuedAt)")
            } catch {
                guard current == generation else { return }
                job.result = .failed(error.localizedDescription)
                diagnostics.record(.generationFailed, session: current, chunk: job.id,
                                   pending: pendingCount, failure: SpeechFailure(error), elapsed: now() - started)
            }
            guard current == generation else { return }
            synthesisTasks[job.id] = nil
            pump()
        }
    }

    private func synthesizeWithRetry(_ job: Job, session: UUID) async throws -> Data {
        var attempt = 1
        while true {
            try Task.checkCancellation()
            guard session == generation else { throw CancellationError() }
            let started = now()
            diagnostics.record(.requestStarted, session: session, chunk: job.id, attempt: attempt, pending: pendingCount)
            do {
                let audio = try await synthesize(job.text, job.configuration)
                try Task.checkCancellation()
                guard session == generation else { throw CancellationError() }
                diagnostics.record(.generated, session: session, chunk: job.id, attempt: attempt,
                                   pending: pendingCount, elapsed: now() - started)
                return audio
            } catch {
                guard session == generation, !Task.isCancelled else { throw CancellationError() }
                let failure = SpeechFailure(error)
                diagnostics.record(.requestFailed, session: session, chunk: job.id, attempt: attempt,
                                   pending: pendingCount, failure: failure, elapsed: now() - started)
                guard let delay = retryPolicy.delay(after: attempt, failure: failure) else { throw error }
                diagnostics.record(.retryScheduled, session: session, chunk: job.id, attempt: attempt,
                                   pending: pendingCount, failure: failure, delay: delay)
                retryingJobs.insert(job.id)
                refreshState()
                do { try await retrySleep(delay) }
                catch {
                    if session == generation { retryingJobs.remove(job.id); refreshState() }
                    throw error
                }
                guard session == generation else { throw CancellationError() }
                retryingJobs.remove(job.id)
                refreshState()
                try Task.checkCancellation()
                attempt += 1
            }
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
            diagnostics.record(.playbackStarted, session: current, chunk: job.id, pending: pendingCount, elapsed: timing.totalWaitSeconds)
            do {
                try await play(audio)
                try Task.checkCancellation()
                guard current == generation else { return }
                lastPlaybackEnd = now()
                diagnostics.record(.playbackEnded, session: current, chunk: job.id, pending: pendingCount, elapsed: now() - playbackStart)
                if job.endsTranslation { pendingCount -= 1 }
                playing = nil
                playbackTask = nil
                pump()
            } catch {
                guard current == generation else { return }
                lastError = error.localizedDescription
                diagnostics.record(.playbackFailed, session: current, chunk: job.id, pending: pendingCount, failure: SpeechFailure(error))
                stop()
            }
        }
    }

    private func refreshState() {
        generatingCount = synthesisTasks.count
        retryingCount = retryingJobs.count
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
