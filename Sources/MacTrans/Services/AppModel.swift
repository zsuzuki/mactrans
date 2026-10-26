import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isOverlayVisible = false
    @Published private(set) var statusText = "Ready"
    @Published var lastError: String?

    let preferences = AppPreferences()
    let transcriptStore = TranscriptStore()

    private let audioCapture = AudioCaptureService()
    private let transcriber = WhisperTranscriber()
    private lazy var overlayController = OverlayWindowController(model: self)
    private var translationTail: Task<Void, Never>?
    private var recordingTask: Task<Void, Never>?
    private var captureContinuation: AsyncThrowingStream<CapturedAudio, Error>.Continuation?
    @Published private(set) var isStarting = false
    @Published private(set) var isFinishing = false
    @Published private(set) var activeAudioSource: AudioInputSource?

    var canChangeAudioSource: Bool { !isStarting && !isRecording && !isFinishing }
    var recordingStatus: String { "Recording · \((activeAudioSource ?? preferences.audioInputSource).title)" }

    func startRecording() {
        guard recordingTask == nil, !isStarting else { return }
        let source = preferences.audioInputSource
        isStarting = true
        statusText = "Starting · \(source.title)"
        showOverlay()

        Task {
            defer { isStarting = false }
            do {
                try await transcriber.configure(
                    modelPath: preferences.whisperModelPath,
                    sourceLanguage: preferences.sourceLanguage,
                    timeoutSeconds: preferences.chunkTimeoutSeconds,
                    maxCharacters: preferences.maxChunkCharacters,
                    mode: TextChunker.Mode(rawValue: preferences.chunkingMode) ?? .balanced
                )
                // One consumer preserves capture order. Bound backlog and report
                // overload explicitly instead of silently dropping audio.
                let (stream, continuation) = AsyncThrowingStream<CapturedAudio, Error>.makeStream(
                    bufferingPolicy: .bufferingOldest(256)
                )
                captureContinuation = continuation
                try await audioCapture.start(source: source) { samples, sampleRate in
                    if case .dropped = continuation.yield(CapturedAudio(samples: samples, sampleRate: sampleRate)) {
                        continuation.finish(throwing: AudioCaptureError.processingOverrun)
                    }
                } onError: { error in
                    continuation.finish(throwing: error)
                }
                activeAudioSource = source
                isRecording = true
                statusText = recordingStatus
                lastError = nil
                showOverlay()
                recordingTask = Task { await consumeAudio(stream) }
            } catch {
                await audioCapture.stop()
                captureContinuation?.finish()
                captureContinuation = nil
                await transcriber.reset()
                lastError = error.localizedDescription
                statusText = "Recording failed"
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        isFinishing = true
        statusText = "Finishing transcription"
        let continuation = captureContinuation
        Task {
            await audioCapture.stop()
            // Wait for the capture callback queue before draining transcription.
            continuation?.finish()
        }
    }

    private func consumeAudio(_ stream: AsyncThrowingStream<CapturedAudio, Error>) async {
        do {
            for try await audio in stream {
                for update in try await transcriber.accept(samples: audio.samples, sampleRate: audio.sampleRate) {
                    apply(update)
                }
            }
            for update in try await transcriber.finish() { apply(update) }
            statusText = "Stopped"
        } catch {
            lastError = error.localizedDescription
            statusText = "Transcription failed"
        }
        await audioCapture.stop()
        captureContinuation?.finish()
        captureContinuation = nil
        isRecording = false
        await transcriber.reset()
        transcriptStore.removePartial()
        recordingTask = nil
        activeAudioSource = nil
        isFinishing = false
    }

    private func apply(_ update: TranscriptionUpdate) {
        if !update.committed.isEmpty {
            transcriptStore.removePartial()
            for text in update.committed { enqueueTranslation(sourceText: text) }
        }
        transcriptStore.updatePartial(update.partialText)
    }

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func toggleRecordingFromOverlay() {
        toggleRecording()
        keepOverlayVisible()
    }

    func toggleOverlay() {
        if isOverlayVisible && overlayController.isVisible {
            hideOverlay()
        } else {
            showOverlay()
        }
    }

    func showOverlay() {
        overlayController.show()
        isOverlayVisible = true
    }

    func hideOverlay() {
        overlayController.hide()
        isOverlayVisible = false
    }

    private func keepOverlayVisible() {
        showOverlay()
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            await MainActor.run {
                self.showOverlay()
            }
            try? await Task.sleep(for: .milliseconds(380))
            await MainActor.run {
                self.showOverlay()
            }
        }
    }

    func clearTranscript() {
        transcriptStore.resetSession()
        statusText = isRecording ? recordingStatus : "Ready"
    }

    func saveTranscript() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "MacTrans Transcript.txt"
        panel.canCreateDirectories = true

        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        guard response == .OK, let destination = panel.url else { return }

        do {
            try transcriptStore.exportText().write(to: destination, atomically: true, encoding: .utf8)
            statusText = "Saved"
            lastError = nil
        } catch {
            statusText = "Save failed"
            lastError = error.localizedDescription
        }
    }

    func chooseWhisperModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose whisper.cpp model"
        panel.message = "Select a ggml whisper.cpp model file."

        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            preferences.whisperModelPath = url.path
            statusText = "Whisper model set"
            lastError = nil
        }
    }

    var whisperModelDisplayName: String {
        let path = preferences.whisperModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return "Not set"
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func enqueueTranslation(sourceText: String) {
        let id = transcriptStore.appendPending(sourceText: sourceText)
        let previous = translationTail
        let baseURLString = preferences.lmStudioBaseURL
        let model = preferences.lmStudioModel
        let apiKey = preferences.lmStudioAPIKey
        let reasoningEffort = preferences.lmStudioReasoningEffort
        let sourceLanguage = preferences.sourceLanguage
        let targetLanguage = preferences.targetLanguage

        translationTail = Task {
            await previous?.value
            let client = TranslationClient(
                baseURLString: baseURLString,
                model: model,
                apiKey: apiKey,
                reasoningEffort: reasoningEffort,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )

            do {
                let translated = try await client.translate(sourceText)
                await MainActor.run {
                    self.transcriptStore.markTranslated(id: id, translatedText: translated)
                    self.statusText = self.isRecording ? self.recordingStatus : (self.recordingTask == nil ? "Ready" : "Finishing transcription")
                    self.lastError = nil
                }
            } catch {
                await MainActor.run {
                    self.transcriptStore.markFailed(id: id, message: error.localizedDescription)
                    self.statusText = "Translation failed"
                    self.lastError = error.localizedDescription
                }
            }
        }
    }
}

private struct CapturedAudio: Sendable {
    var samples: [Float]
    var sampleRate: Double
}
