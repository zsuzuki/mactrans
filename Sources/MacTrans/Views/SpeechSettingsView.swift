import SwiftUI

struct SpeechSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var speech: SpeechService
    @State private var testText = "こんにちは。翻訳の読み上げをテストします。"

    var body: some View {
        Section("Gemini Text-to-Speech") {
            Toggle("Speak translations", isOn: $preferences.speechEnabled)
            SecureField("API key", text: $preferences.googleTTSAPIKey)
            TextField("Model", text: $preferences.speechModel, prompt: Text("gemini-3.8-flash-tts"))
            TextField("Voice ID / name", text: $preferences.speechVoiceName, prompt: Text("voice_… or Kore"))
            Text("Choose a Gemini TTS model and voice ID or name. Language is inferred from the translated text; model and voice settings are not changed automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Test text", text: $testText)
            HStack {
                Button("Test Speech") { model.testSpeech(testText) }
                    .disabled(testText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Stop Speech") { model.stopSpeech() }
                if speech.isBusy { Text("Pending: \(speech.pendingCount)").foregroundStyle(.secondary) }
            }
            Text("Prefetch: up to 2 chunks · Generating: \(speech.generatingCount) · Ready: \(speech.readyCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let timing = speech.recentTimings.last {
                Text("Last: generation \(timing.generationSeconds, specifier: "%.2f")s · ready wait \(timing.playbackWaitSeconds, specifier: "%.2f")s")
                    .font(.caption)
                DisclosureGroup("Speech timings (last 20 chunks)") {
                    ScrollView {
                        Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 5) {
                            GridRow {
                                Text("#")
                                Text("Generation")
                                Text("Ready wait")
                                Text("Total wait")
                                Text("Gap")
                            }.fontWeight(.medium)
                            ForEach(speech.recentTimings.reversed()) { sample in
                                GridRow {
                                    Text("\(sample.id)")
                                    Text("\(sample.generationSeconds, specifier: "%.2f")s")
                                    Text("\(sample.playbackWaitSeconds, specifier: "%.2f")s")
                                    Text("\(sample.totalWaitSeconds, specifier: "%.2f")s")
                                    if let gap = sample.gapSeconds { Text("\(gap, specifier: "%.2f")s") }
                                    else { Text("—") }
                                }
                            }
                        }
                        .font(.caption.monospacedDigit())
                    }
                    .frame(maxHeight: 180)
                    Text("Ready wait is time buffered after generation. Total wait starts when translation is queued. Gap is time between playback calls, including waiting for the next translation; silence inside audio is not measured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = speech.lastError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            Text("Enabling speech sends translated text to the Gemini API and may incur usage charges. The API key is stored in Keychain. With microphone input, use headphones to avoid capturing the spoken translation.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct SpeechMenuView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var speech: SpeechService

    var body: some View {
        Toggle("Speak Translations", isOn: $preferences.speechEnabled)
        Button(speech.isBusy ? "Stop Speech (\(speech.pendingCount))" : "Stop Speech") {
            model.stopSpeech()
        }
        if let error = speech.lastError { Text(error).font(.caption) }
    }
}
