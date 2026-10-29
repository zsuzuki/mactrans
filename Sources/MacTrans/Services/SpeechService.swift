import AVFoundation
import Foundation

@MainActor
final class SpeechService: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var pendingCount = 0
    @Published private(set) var lastError: String?

    private struct Item {
        var text: String
        var configuration: SpeechConfiguration
    }
    private var queue: [Item] = []
    private var worker: Task<Void, Never>?
    private var generation = UUID()
    private let synthesize: (String, SpeechConfiguration) async throws -> Data
    private let play: (Data) async throws -> Void
    private let stopPlayback: () -> Void
    private let maximumPending: Int

    init(maximumPending: Int = 20,
         synthesize: @escaping (String, SpeechConfiguration) async throws -> Data = {
             try await GeminiTTSClient().synthesize($0, configuration: $1)
         },
         play: @escaping (Data) async throws -> Void,
         stopPlayback: @escaping () -> Void) {
        self.maximumPending = maximumPending
        self.synthesize = synthesize
        self.play = play
        self.stopPlayback = stopPlayback
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
        queue.append(Item(text: text, configuration: configuration))
        pendingCount += 1
        guard worker == nil else { return }
        lastError = nil
        isBusy = true
        let current = generation
        worker = Task { [weak self] in await self?.drain(generation: current) }
    }

    func stop() {
        generation = UUID()
        worker?.cancel()
        worker = nil
        queue.removeAll()
        stopPlayback()
        pendingCount = 0
        isBusy = false
    }

    private func drain(generation current: UUID) async {
        do {
            while !queue.isEmpty {
                try Task.checkCancellation()
                let item = queue.removeFirst()
                for chunk in try GeminiTTSClient.chunks(item.text) {
                    let audio = try await synthesize(chunk, item.configuration)
                    try Task.checkCancellation()
                    guard current == generation else { return }
                    try await play(audio)
                    try Task.checkCancellation()
                    guard current == generation else { return }
                }
                pendingCount -= 1
            }
        } catch {
            guard current == generation else { return }
            if !Task.isCancelled { lastError = error.localizedDescription }
            queue.removeAll()
            stopPlayback()
        }
        guard current == generation else { return }
        pendingCount = 0
        isBusy = false
        worker = nil
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
