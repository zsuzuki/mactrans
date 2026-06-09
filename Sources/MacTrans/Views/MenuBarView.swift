import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.statusText)
                .font(.headline)

            if let lastError = model.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Divider()

            Picker("Source", selection: sourceLanguageBinding) {
                Text("English").tag("English")
                Text("Japanese").tag("Japanese")
                Text("Chinese").tag("Chinese")
                Text("Korean").tag("Korean")
                Text("Auto").tag("Auto")
            }

            Picker("Target", selection: targetLanguageBinding) {
                Text("Japanese").tag("Japanese")
                Text("English").tag("English")
                Text("Chinese").tag("Chinese")
                Text("Korean").tag("Korean")
            }

            Divider()

            Text("Whisper model: \(model.whisperModelDisplayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Button("Choose Whisper Model...") {
                model.chooseWhisperModel()
            }

            Divider()

            Button(model.isRecording ? "Stop Recording" : "Start Recording") {
                model.toggleRecording()
            }
            .keyboardShortcut("r")

            Button("Show Overlay") {
                model.toggleOverlay()
            }

            Button("Save Transcript...") {
                model.saveTranscript()
            }
            .keyboardShortcut("s")

            Button("Clear Transcript") {
                model.clearTranscript()
            }

            Divider()

            SettingsLink {
                Text("Settings...")
            }

            Button("Quit MacTrans") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(.vertical, 6)
        .frame(width: 260)
    }

    private var sourceLanguageBinding: Binding<String> {
        Binding {
            model.preferences.sourceLanguage
        } set: {
            model.preferences.sourceLanguage = $0
        }
    }

    private var targetLanguageBinding: Binding<String> {
        Binding {
            model.preferences.targetLanguage
        } set: {
            model.preferences.targetLanguage = $0
        }
    }
}
