import SwiftUI

struct SpeechVoicePicker: View {
    @ObservedObject var preferences: AppPreferences
    @StateObject private var catalog = SpeechVoiceCatalog()
    @State private var search = ""

    private var filteredVoices: [SpeechVoice] { catalog.voices.filter { $0.matches(search) } }

    var body: some View {
        Picker("Voice", selection: $preferences.speechVoiceName) {
            // Keep the selected ID valid even before loading or while filtering.
            if !filteredVoices.contains(where: { $0.id == preferences.speechVoiceName }) {
                Text(preferences.speechVoiceName.isEmpty ? "Choose a voice" : "Current: \(preferences.speechVoiceName)")
                    .tag(preferences.speechVoiceName)
            }
            ForEach(filteredVoices) { voice in
                Text(voice.title).tag(voice.id)
            }
        }
        if !catalog.voices.isEmpty {
            TextField("Search voices", text: $search, prompt: Text("Name, language, type or ID"))
        }
        HStack {
            Button(catalog.hasLoaded ? "Refresh Voices" : "Load Voices") {
                catalog.load(apiKey: preferences.googleTTSAPIKey)
            }
            .disabled(catalog.isLoading || preferences.googleTTSAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if catalog.isLoading {
                ProgressView().controlSize(.small)
                Button("Cancel") { catalog.cancel() }
            } else if catalog.hasLoaded {
                Text("\(filteredVoices.count) of \(catalog.voices.count) voices")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if let error = catalog.error { Text(error).font(.caption).foregroundStyle(.red) }
        if catalog.hasLoaded && catalog.voices.isEmpty {
            Text("No voices returned. You can enter a voice ID or name below.")
                .font(.caption).foregroundStyle(.secondary)
        }
        DisclosureGroup("Enter voice manually") {
            TextField("Voice ID / name", text: $preferences.speechVoiceName, prompt: Text("voice_… or Kore"))
        }
        .onChange(of: preferences.googleTTSAPIKey) { _, _ in catalog.invalidate() }
        .onDisappear { catalog.cancel() }
        .task {
            if !catalog.hasLoaded && !catalog.isLoading && !preferences.googleTTSAPIKey.isEmpty {
                catalog.load(apiKey: preferences.googleTTSAPIKey)
            }
        }
    }
}
