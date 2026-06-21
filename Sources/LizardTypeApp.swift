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
        // The keep-alive agent (launchd) and a manual Finder launch can both
        // start us; defer to whichever instance is already running so we never
        // show two menu-bar icons. Exit 0 so launchd treats it as a clean quit.
        if isDuplicateInstance() {
            NSLog("[LizardType] another instance is already running — exiting")
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        AppState.shared.start()
    }

    /// True if an older instance of this app (lower PID) is already running.
    private func isDuplicateInstance() -> Bool {
        let me = NSRunningApplication.current
        let bundleID = Bundle.main.bundleIdentifier ?? "com.lizardtype.app"
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != me && !$0.isTerminated }
        return others.contains { $0.processIdentifier < me.processIdentifier }
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
