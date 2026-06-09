import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        Form {
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
                    Text("Timeout")
                    Slider(value: $preferences.chunkTimeoutSeconds, in: 0.8...8.0, step: 0.2)
                    Text("\(preferences.chunkTimeoutSeconds, specifier: "%.1f")s")
                        .frame(width: 44, alignment: .trailing)
                }

                Stepper("Max characters: \(preferences.maxChunkCharacters)", value: $preferences.maxChunkCharacters, in: 60...800, step: 20)
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
