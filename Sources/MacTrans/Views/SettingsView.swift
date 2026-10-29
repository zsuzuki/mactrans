import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        Form {
            Section("Audio Input") {
                Picker("Input", selection: $preferences.audioInputSource) {
                    ForEach(AudioInputSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .disabled(!model.canChangeAudioSource)
                Text("System Audio captures sound from other apps without using the microphone. Allow MacTrans in Privacy & Security > Screen & System Audio Recording when prompted. Stop recording before changing the input.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Languages") {
                TextField("Source language", text: $preferences.sourceLanguage)
                TextField("Target language", text: $preferences.targetLanguage)
            }

            Section("LM Studio") {
                TextField("Chat completions URL", text: $preferences.lmStudioBaseURL)
                    .textFieldStyle(.roundedBorder)
                TextField("Model", text: $preferences.lmStudioModel)
                    .textFieldStyle(.roundedBorder)
                SecureField("API token", text: $preferences.lmStudioAPIKey)
                    .textFieldStyle(.roundedBorder)
                Picker("Thinking", selection: $preferences.lmStudioReasoningEffort) {
                    Text("Off").tag("none")
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                    Text("Server Default").tag("default")
                }
            }

            SpeechSettingsView(model: model, preferences: preferences, speech: model.speech)

            Section("whisper.cpp") {
                HStack {
                    TextField("Model path", text: $preferences.whisperModelPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose...") {
                        chooseWhisperModel()
                    }
                }
            }

            Section("Chunking") {
                Picker("Mode", selection: $preferences.chunkingMode) {
                    Text("Fast").tag("fast")
                    Text("Balanced").tag("balanced")
                    Text("Stable").tag("stable")
                }

                HStack {
                    Text("Stable phrase delay")
                    Slider(value: $preferences.chunkTimeoutSeconds, in: 0.8...8.0, step: 0.2)
                    Text("\(preferences.chunkTimeoutSeconds, specifier: "%.1f")s")
                        .frame(width: 44, alignment: .trailing)
                }

                Stepper("Max characters: \(preferences.maxChunkCharacters)", value: $preferences.maxChunkCharacters, in: 60...800, step: 20)
                Text("Speech pauses finish a phrase automatically. During continuous speech, only stable words are committed; the delay never forces an unstable ending.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    private func chooseWhisperModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose whisper.cpp model"
        panel.message = "Select a ggml whisper.cpp model file."
        if panel.runModal() == .OK, let url = panel.url {
            preferences.whisperModelPath = url.path
        }
    }
}
