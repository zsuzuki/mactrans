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
    private var chunker = TextChunker(timeoutSeconds: 2.8, maxCharacters: 220)
    private var translationTail: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func startRecording() {
        guard !isRecording else { return }
        showOverlay()

        Task {
            let allowed = await audioCapture.requestPermission()
            guard allowed else {
                lastError = AudioCaptureError.microphoneDenied.localizedDescription
                statusText = "Microphone denied"
                return
            }

            do {
                try await transcriber.configure(
                    modelPath: preferences.whisperModelPath,
                    sourceLanguage: preferences.sourceLanguage
                )
                chunker = TextChunker(
                    timeoutSeconds: preferences.chunkTimeoutSeconds,
                    maxCharacters: preferences.maxChunkCharacters,
                    mode: TextChunker.Mode(rawValue: preferences.chunkingMode) ?? .balanced
                )
                try audioCapture.start { [weak self] samples, sampleRate in
                    Task {
                        await self?.handle(samples: samples, sampleRate: sampleRate)
                    }
                }
                isRecording = true
                statusText = "Recording"
                lastError = nil
                showOverlay()
                startTimeoutLoop()
            } catch {
                lastError = error.localizedDescription
                statusText = "Recording failed"
                audioCapture.stop()
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        audioCapture.stop()
        timeoutTask?.cancel()
        timeoutTask = nil
        Task {
            await transcriber.reset()
        }
        if let chunk = chunker.flushIfTimedOut(now: Date.distantFuture) {
            enqueueTranslation(sourceText: chunk)
        }
        transcriptStore.removePartial()
        isRecording = false
        statusText = "Stopped"
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
        statusText = isRecording ? "Recording" : "Ready"
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

    private func handle(samples: [Float], sampleRate: Double) async {
        do {
            guard let update = try await transcriber.accept(samples: samples, sampleRate: sampleRate) else {
                return
            }

            if let chunk = chunker.accept(update.text, isFinal: update.isFinal) {
                transcriptStore.removePartial()
                enqueueTranslation(sourceText: chunk)
            } else {
                transcriptStore.updatePartial(update.text)
            }
        } catch {
            statusText = "Transcription failed"
            lastError = error.localizedDescription
        }
    }

    private func enqueueTranslation(sourceText: String) {
        let id = transcriptStore.appendPendingReplacingRecentRevision(sourceText: sourceText)
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
                    self.statusText = self.isRecording ? "Recording" : "Ready"
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

    private func startTimeoutLoop() {
        timeoutTask?.cancel()
        timeoutTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                await MainActor.run {
                    if let chunk = self.chunker.flushIfTimedOut() {
                        self.transcriptStore.removePartial()
                        self.enqueueTranslation(sourceText: chunk)
                    }
                }
            }
        }
    }
}
