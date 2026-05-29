import SwiftUI
import AppKit

@main
struct LizardTypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject var app = AppState.shared

    var body: some Scene {
        MenuBarExtra("LizardType", systemImage: app.status.symbol) {
            MenuContent(app: app)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if Diagnostics.isCLI(args) {
            // Headless self-test: no menu bar, run pipeline, exit.
            NSApp.setActivationPolicy(.prohibited)
            Task { await Diagnostics.runCLI(args); exit(0) }
            return
        }
        NSApp.setActivationPolicy(.accessory)
        AppState.shared.start()
    }
}

struct MenuContent: View {
    @ObservedObject var app: AppState
    @ObservedObject var recorder = AppState.shared.recorder
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Text("LizardType — \(app.status.menuText)")
        Divider()
        Button(recorder.isRecording ? "■ Stop & Transcribe" : "● Start Recording") {
            app.toggleRecording()
        }
        Text("Push-to-talk: \(settings.shortcutDisplay)")   // the real global trigger (hold)
        Divider()
        Toggle("Clean up transcript (LLM pass)", isOn: $settings.cleanupEnabled)   // off → paste raw transcript
        if !app.lastTranscript.isEmpty {
            Divider()
            Button("Copy last transcript") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(app.lastTranscript, forType: .string)
            }
            Text(app.lastTranscript.prefix(80) + (app.lastTranscript.count > 80 ? "…" : ""))
        }
        Divider()
        if case .error = app.status {
            Button("Reconnect") { Task { await app.warmBridge() } }
        }
        Button("Settings…") { WindowManager.shared.show() }
            .keyboardShortcut(",", modifiers: .command)
        Button("Diagnostics…") { WindowManager.shared.show(tab: .diagnostics) }
        Divider()
        Button("Quit LizardType") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}
