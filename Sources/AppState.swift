import Foundation
import AppKit
import Combine
import CoreGraphics

/// Central coordinator: wires hotkey → record → transcribe → cleanup → paste.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Status: Equatable {
        case warming            // bridge loading
        case ready
        case recording
        case transcribing
        case cleaning
        case error(String)

        var menuText: String {
            switch self {
            case .warming:      return "Starting…"
            case .ready:        return "Ready"
            case .recording:    return "Recording…"
            case .transcribing: return "Transcribing…"
            case .cleaning:     return "Cleaning up…"
            case .error(let e): return "Error: \(e)"
            }
        }
        var symbol: String {
            switch self {
            case .warming:      return "hourglass"
            case .ready:        return "lizard"
            case .recording:    return "mic.fill"
            case .transcribing: return "waveform"
            case .cleaning:     return "sparkles"
            case .error:        return "exclamationmark.triangle"
            }
        }
    }

    @Published private(set) var status: Status = .warming
    @Published var micAuthorized = PermissionsManager.micAuthorized
    @Published var accessibilityTrusted = PermissionsManager.accessibilityTrusted
    @Published var inputMonitoringTrusted = PermissionsManager.inputMonitoringTrusted
    @Published var lastTranscript = ""
    @Published var lastDiagnostic = ""
    @Published var lastKeyEvent = "— (press your shortcut)"

    let settings = AppSettings.shared
    let recorder = AudioRecorder()
    private let bridge = ChatGPTBridge()
    private let groq = GroqClient()
    private let hotkey = HotkeyManager()
    private let overlay = OverlayController()
    private var pipeline: Task<Void, Never>?
    private var busy = false
    private var permPoll: Timer?
    private var recTimeout: Timer?

    private init() {}

    // MARK: - Startup

    func start() {
        // Keep the menu-bar icon alive across the Accessibility-grant SIGKILL and
        // at login (reconciled with the user's setting, default on).
        LaunchManager.sync(enabled: settings.launchAtLogin)
        overlay.attach(recorder: recorder)
        overlay.setStopHandler { [weak self] in self?.finishRecording() }
        wireHotkey()
        Task { await warmBridge() }
        refreshPermissions()
        promptForAccessibilityIfNeeded()
        startPermissionPoll()
    }

    func refreshPermissions() {
        micAuthorized = PermissionsManager.micAuthorized
        accessibilityTrusted = PermissionsManager.accessibilityTrusted
        inputMonitoringTrusted = PermissionsManager.inputMonitoringTrusted
    }

    var hotkeyInstalled: Bool { hotkey.isInstalled }
    var statusText: String { status.menuText }

    /// Diagnostic: paste a marker so the user can see if ⌘V actually fires.
    func testPaste() {
        let trusted = PermissionsManager.accessibilityTrusted
        let ok = TextInserter.insert("LizardType paste test ✓")
        lastDiagnostic = trusted && ok
            ? "⌘V sent (focus a text field to see it). AXIsProcessTrusted=YES."
            : "Accessibility NOT granted → text only copied to clipboard (paste with ⌘V). AXIsProcessTrusted=NO."
        refreshPermissions()
    }

    /// On launch, if Accessibility isn't granted the hotkey can't work — tell the
    /// user explicitly instead of failing silently.
    private func promptForAccessibilityIfNeeded() {
        refreshPermissions()
        guard !accessibilityTrusted else { return }
        PermissionsManager.promptAccessibility()   // system grant dialog (non-blocking)
        // Defer our explanatory alert: running a modal during launch races the
        // SwiftUI MenuBarExtra setup and can leave the status item missing. Let
        // the menu-bar icon render first, then explain.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !PermissionsManager.accessibilityTrusted else { return }
            let relaunchNote = self.settings.launchAtLogin
                ? "macOS may quit LizardType the moment you flip the switch — that's normal. " +
                  "It relaunches itself within a few seconds (auto-start is on), so just wait " +
                  "for the menu-bar icon to come back."
                : "macOS may quit LizardType when you flip the switch. If the menu-bar icon " +
                  "disappears, reopen LizardType from Applications (or turn on “Launch at login” " +
                  "in Settings so it comes back by itself)."
            let alert = NSAlert()
            alert.messageText = "Enable Accessibility for LizardType"
            alert.informativeText = """
            LizardType needs Accessibility to capture the push-to-talk key \
            (\(self.settings.trigger.label)) and to paste text.

            Open System Settings → Privacy & Security → Accessibility and turn on LizardType.
            \(relaunchNote)

            You can still record from the menu-bar icon without it — transcripts are copied \
            to the clipboard so you can paste with ⌘V.
            """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                PermissionsManager.openAccessibilitySettings()
            }
        }
    }

    /// Re-check permissions; install the hotkey the moment Accessibility is granted.
    private func startPermissionPoll() {
        permPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPermissions() }
        }
    }

    private func pollPermissions() {
        let prevAX = accessibilityTrusted
        let prevIM = inputMonitoringTrusted
        refreshPermissions()
        // Custom key-combos additionally require Input Monitoring; modifier holds don't.
        let needsIM = settings.useCustomShortcut
        let permsOK = accessibilityTrusted && (!needsIM || inputMonitoringTrusted)
        let permsJustChanged = (accessibilityTrusted && !prevAX) || (needsIM && inputMonitoringTrusted && !prevIM)
        if permsOK && (!hotkey.isInstalled || permsJustChanged) {
            if hotkey.start(trigger: currentTrigger()) {
                NSLog("[LizardType] hotkey (re)installed (custom=%@ inputMonitoring=%@)",
                      needsIM ? "Y" : "N", inputMonitoringTrusted ? "Y" : "N")
                if permsJustChanged, settings.playSounds { NSSound(named: "Glass")?.play() }
            }
        }

        // Reclaim the WebView's WebContent memory when idle (ChatGPT provider only).
        // Cheap to call every tick; it self-gates on idle time and never fires mid-use.
        if settings.provider == .chatgpt, !busy, !recorder.isRecording {
            bridge.recycleIfIdle()
        }
    }

    /// The backend selected in Settings.
    private var activeProvider: SpeechProvider {
        settings.provider == .groq ? groq : bridge
    }

    func warmBridge() async {
        status = .warming
        switch settings.provider {
        case .groq:
            do {
                try await groq.validate()       // ensure a key is resolvable
                status = .ready
                NSLog("[LizardType] Groq provider ready")
            } catch {
                status = .error(error.localizedDescription)
                NSLog("[LizardType] Groq warm failed: %@", error.localizedDescription)
            }
        case .chatgpt:
            guard !settings.cookiesPath.isEmpty else {
                status = .error("Set cookies.json in Settings"); return
            }
            do {
                NSLog("[LizardType] warming bridge with %@", settings.cookiesPath)
                try await bridge.start(cookiesPath: settings.cookiesPath)
                await bridge.waitUntilReady()
                _ = try await bridge.accessToken(forceRefresh: true)   // verify login
                status = .ready
                NSLog("[LizardType] bridge ready — logged in")
            } catch {
                status = .error(error.localizedDescription)
                NSLog("[LizardType] warm failed: %@", error.localizedDescription)
            }
        }
    }

    /// Build the active trigger from settings (custom shortcut overrides preset).
    private func currentTrigger() -> HotkeyManager.Trigger {
        if settings.useCustomShortcut {
            return .keyCombo(keyCode: Int64(settings.shortcutKeyCode),
                             mods: Self.cgFlags(settings.shortcutModifiers))
        }
        return .modifier(settings.trigger)
    }

    static func cgFlags(_ raw: UInt) -> CGEventFlags {
        let m = NSEvent.ModifierFlags(rawValue: raw)
        var f: CGEventFlags = []
        if m.contains(.command) { f.insert(.maskCommand) }
        if m.contains(.option)  { f.insert(.maskAlternate) }
        if m.contains(.control) { f.insert(.maskControl) }
        if m.contains(.shift)   { f.insert(.maskShift) }
        return f
    }

    /// Custom key-combos need Input Monitoring (keyDown taps); request it if missing.
    private func ensureInputMonitoring() {
        guard settings.useCustomShortcut else { return }
        refreshPermissions()
        if !inputMonitoringTrusted {
            PermissionsManager.requestInputMonitoring()   // system prompt + adds app to the list
        }
    }

    private func wireHotkey() {
        hotkey.onStart = { [weak self] in self?.beginRecording() }
        hotkey.onStop = { [weak self] in self?.finishRecording() }
        hotkey.onKeyDebug = { [weak self] s in self?.lastKeyEvent = s }
        ensureInputMonitoring()
        let ok = hotkey.start(trigger: currentTrigger())
        NSLog("[LizardType] hotkey tap installed=%@ shortcut=%@ axTrusted=%@",
              ok ? "YES" : "NO", settings.shortcutDisplay, PermissionsManager.accessibilityTrusted ? "YES" : "NO")
        if !ok {
            // Accessibility not granted yet; will be retried after grant.
            accessibilityTrusted = false
        }
    }

    func retryHotkey() { ensureInputMonitoring(); _ = hotkey.start(trigger: currentTrigger()) }
    func applyTrigger() { ensureInputMonitoring(); hotkey.updateTrigger(currentTrigger()) }

    /// Manual toggle from the menu bar (no hotkey / Accessibility needed to record).
    func toggleRecording() {
        if recorder.isRecording { finishRecording() } else { beginRecording() }
    }
    var isRecording: Bool { recorder.isRecording }

    // MARK: - Recording pipeline

    private func beginRecording() {
        NSLog("[LizardType] hotkey DOWN — beginRecording (status=%@ busy=%@)", status.menuText, busy ? "Y" : "N")
        guard !busy else { return }
        guard case .ready = statusOrReady() else {
            overlay.show(.error(status.menuText))   // visible feedback, not silent
            if settings.playSounds { NSSound.beep() }
            return
        }
        Task {
            guard await PermissionsManager.requestMic() else {
                status = .error("Microphone permission needed"); refreshPermissions()
                overlay.show(.error("Microphone permission needed"))
                return
            }
            do {
                try recorder.start()
                status = .recording
                overlay.show(.recording)
                if settings.playSounds { NSSound(named: "Tink")?.play() }
                // safety: auto-stop at the configured max duration
                recTimeout?.invalidate()
                recTimeout = Timer.scheduledTimer(withTimeInterval: TimeInterval(settings.maxRecordingSeconds),
                                                  repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.finishRecording() }
                }
            } catch {
                status = .error(error.localizedDescription)
                overlay.show(.error("Mic error — check permission"))
            }
        }
    }

    private func statusOrReady() -> Status {
        // recording is only allowed from .ready (or after a prior error we still allow)
        if case .recording = status { return .recording }
        if case .ready = status { return .ready }
        if case .error = status { return .ready }   // allow retry; warmBridge sets real state
        return status
    }

    private func finishRecording() {
        recTimeout?.invalidate(); recTimeout = nil
        guard recorder.isRecording else { return }
        if settings.playSounds { NSSound(named: "Pop")?.play() }
        guard let (url, durationMs) = recorder.stop() else { overlay.hide(); status = .ready; return }
        guard durationMs >= 400 else {          // ignore accidental taps / silence
            recorder.cleanup(url); overlay.hide(); status = .ready; return
        }
        overlay.show(.transcribing)             // keep overlay up through processing
        pipeline?.cancel()
        pipeline = Task { await runPipeline(url: url) }
    }

    private func runPipeline(url: URL) async {
        busy = true
        defer { busy = false; recorder.cleanup(url) }
        do {
            let provider = activeProvider
            if settings.provider == .chatgpt { await bridge.waitUntilReady() }
            status = .transcribing
            overlay.show(.transcribing)
            let raw = try await provider.transcribe(audioURL: url, language: settings.transcribeLanguage)
            guard !raw.isEmpty else { status = .ready; overlay.hide(); return }
            lastTranscript = raw

            var final = raw
            if settings.cleanupEnabled {
                status = .cleaning
                overlay.show(.cleaning)
                let cleanupModel = settings.provider == .groq ? settings.groqCleanupModel : settings.model
                do {
                    final = try await provider.cleanup(raw: raw, prompt: settings.cleanupPrompt,
                                                       model: cleanupModel, language: settings.oaiLanguage)
                } catch {
                    // Cleanup failed (e.g. sentinel) — fall back to raw so text is never lost.
                    final = raw
                    notify("Cleanup skipped", error.localizedDescription)
                }
            }
            lastTranscript = final
            let pasted = TextInserter.insert(final)
            status = .ready
            if pasted {
                overlay.show(.done(String(final.prefix(40))))
            } else {
                // No Accessibility yet → text is on the clipboard, tell the user.
                overlay.show(.done("Copied — press ⌘V"))
                notify("Copied to clipboard", "Grant Accessibility to auto-paste. Text: \(final.prefix(60))")
            }
        } catch ChatGPTBridge.BridgeError.noAccount {
            status = .error("Session expired — re-export cookies.json")
            overlay.show(.error("Session expired — re-export cookies.json"))
        } catch {
            status = .error(error.localizedDescription)
            overlay.show(.error(error.localizedDescription))
        }
    }

    private func notify(_ title: String, _ body: String) {
        NSLog("[LizardType] %@: %@", title, body)
    }
}
