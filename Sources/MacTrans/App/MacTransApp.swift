import AppKit
import SwiftUI

@main
struct MacTransApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("MacTrans", systemImage: model.isRecording ? "waveform.circle.fill" : "captions.bubble") {
            MenuBarView(model: model)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(preferences: model.preferences)
                .frame(width: 520)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
