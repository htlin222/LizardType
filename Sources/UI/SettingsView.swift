import SwiftUI
import AppKit

enum SettingsTab: Hashable { case general, cleanup, permissions, diagnostics }

struct SettingsView: View {
    @ObservedObject var app = AppState.shared
    @ObservedObject var settings = AppSettings.shared
    @State private var tab: SettingsTab
    @State private var groqKey: String = GroqSecrets.keychainKey() ?? ""

    init(tab: SettingsTab = .general) { _tab = State(initialValue: tab) }

    var body: some View {
        TabView(selection: $tab) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            cleanup.tabItem { Label("Cleanup", systemImage: "sparkles") }.tag(SettingsTab.cleanup)
            permissions.tabItem { Label("Permissions", systemImage: "lock.shield") }.tag(SettingsTab.permissions)
            diagnostics.tabItem { Label("Diagnostics", systemImage: "stethoscope") }.tag(SettingsTab.diagnostics)
        }
        .frame(width: 540, height: 520)
        .onAppear { app.refreshPermissions() }
    }

    // MARK: Diagnostics
    private var diagnostics: some View {
        Form {
            Section("Status") {
                statusRow("\(settings.provider.label) ready", app.status == .ready)
                statusRow("Microphone", app.micAuthorized)
                statusRow("Accessibility (paste + hotkey)", app.accessibilityTrusted)
                statusRow("Input Monitoring (custom combos)", app.inputMonitoringTrusted)
                statusRow("Hotkey installed", app.hotkeyInstalled)
                Text("Bridge: \(app.statusText)").font(.caption).foregroundStyle(.secondary)
            }
            Section("Tests") {
                HStack {
                    Button("Refresh") { app.refreshPermissions() }
                    Button("Test Paste") { app.testPaste() }
                    Text("(focus a text field first)").font(.caption).foregroundStyle(.secondary)
                }
                if !app.lastDiagnostic.isEmpty {
                    Text(app.lastDiagnostic).font(.caption).foregroundStyle(.secondary)
                }
            }
            if settings.useCustomShortcut {
                Section("Hotkey live readout") {
                    Text("Press your shortcut (\(settings.shortcutDisplay)) now:")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(app.lastKeyEvent).font(.system(.callout, design: .monospaced))
                    Text("If this never changes when you press keys, the tap isn't receiving keyDown events → Input Monitoring isn't effective for this build (re-grant below).")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Section("Fix permissions") {
                Button("Re-grant Accessibility") {
                    PermissionsManager.promptAccessibility(); app.refreshPermissions(); app.retryHotkey()
                }
                Button("Request Input Monitoring") {
                    PermissionsManager.requestInputMonitoring(); app.refreshPermissions()
                }
                Button("Open Accessibility Settings") { PermissionsManager.openAccessibilitySettings() }
                Button("Open Input Monitoring Settings") { PermissionsManager.openInputMonitoringSettings() }
            }
            if !app.lastTranscript.isEmpty {
                Section("Last result") {
                    Text(app.lastTranscript).textSelection(.enabled).font(.callout)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func statusRow(_ label: String, _ ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(label)
            Spacer()
        }
    }

    // MARK: General
    private var general: some View {
        Form {
            Section("API provider") {
                Picker("Provider", selection: $settings.provider) {
                    ForEach(APIProvider.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .onChange(of: settings.provider) { _, _ in Task { await app.warmBridge() } }
                Text("Status: \(app.status.menuText)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if settings.provider == .chatgpt {
                Section("ChatGPT session") {
                    HStack {
                        TextField("cookies.json path", text: $settings.cookiesPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") { chooseCookies() }
                        Button("Reconnect") { Task { await app.warmBridge() } }
                    }
                }
            } else {
                Section("Groq API") {
                    SecureField("GROQ_API_KEY (sk-…/gsk_…)", text: $groqKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveGroqKey() }
                    HStack {
                        Button("Save key") { saveGroqKey() }
                        Button("Reconnect") { Task { await app.warmBridge() } }
                        if groqKey.isEmpty && GroqSecrets.hasEnvKey() {
                            Text("Using key from environment / .env")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Get a key at console.groq.com. Stored in your macOS Keychain; leave empty to fall back to GROQ_API_KEY in .env.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Transcribe model", text: $settings.groqTranscribeModel)
                    TextField("Cleanup model", text: $settings.groqCleanupModel)
                }
            }
            Section("Push-to-talk trigger") {
                Toggle("Use a custom shortcut", isOn: $settings.useCustomShortcut)
                    .onChange(of: settings.useCustomShortcut) { _, _ in app.applyTrigger() }
                if settings.useCustomShortcut {
                    ShortcutRecorder { app.applyTrigger() }
                    Text("Hold the shortcut to record, release to transcribe. The key is captured so it won't trigger other apps.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Modifier key", selection: $settings.trigger) {
                        ForEach(TriggerKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .onChange(of: settings.trigger) { _, _ in app.applyTrigger() }
                }
            }
            Section("Language & model") {
                TextField("Transcribe language (e.g. zh, en)", text: $settings.transcribeLanguage)
                TextField("UI language (oai-language, e.g. zh-TW)", text: $settings.oaiLanguage)
                if settings.provider == .chatgpt {
                    TextField("Cleanup model slug", text: $settings.model)
                }
            }
            Section("Misc") {
                Toggle("Play start/stop sounds", isOn: $settings.playSounds)
                Stepper("Max recording: \(settings.maxRecordingSeconds)s",
                        value: $settings.maxRecordingSeconds, in: 10...300, step: 10)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Cleanup
    private var cleanup: some View {
        Form {
            Section {
                Toggle("Clean up transcript with ChatGPT (LLM pass)", isOn: $settings.cleanupEnabled)
                Text("When off, the raw transcription is pasted directly.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Cleanup prompt") {
                TextEditor(text: $settings.cleanupPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 240)
                Button("Reset to default") { settings.cleanupPrompt = Prompts.defaultCleanup }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Permissions
    private var permissions: some View {
        Form {
            Section("Microphone") {
                row(ok: app.micAuthorized, label: "Microphone access") {
                    Task { _ = await PermissionsManager.requestMic(); app.refreshPermissions() }
                } settingsAction: { PermissionsManager.openMicSettings() }
            }
            Section("Accessibility") {
                row(ok: app.accessibilityTrusted, label: "Accessibility (hotkey + paste)") {
                    PermissionsManager.promptAccessibility()
                    app.refreshPermissions(); app.retryHotkey()
                } settingsAction: { PermissionsManager.openAccessibilitySettings() }
                Text("Needed to capture the global push-to-talk key and to paste (⌘V). After granting, click Retry.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Retry") { app.refreshPermissions(); app.retryHotkey() }
            }
        }
        .formStyle(.grouped)
        .onAppear { app.refreshPermissions() }
    }

    @ViewBuilder
    private func row(ok: Bool, label: String, requestAction: @escaping () -> Void,
                     settingsAction: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(label)
            Spacer()
            if !ok {
                Button("Request", action: requestAction)
                Button("Open Settings", action: settingsAction)
            }
        }
    }

    private func saveGroqKey() {
        GroqSecrets.setKeychainKey(groqKey)
        Task { await app.warmBridge() }
    }

    private func chooseCookies() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        p.allowsMultipleSelection = false
        p.canChooseDirectories = false
        if p.runModal() == .OK, let url = p.url {
            settings.cookiesPath = url.path
            Task { await app.warmBridge() }
        }
    }
}

/// Captures the next key combo the user presses (while the Settings window is key).
struct ShortcutRecorder: View {
    @ObservedObject var settings = AppSettings.shared
    var onChange: () -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text("Shortcut")
            Spacer()
            Button(recording ? "Press keys…" : settings.shortcutDisplay) { toggle() }
                .frame(minWidth: 130)
                .foregroundStyle(recording ? .secondary : .primary)
        }
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { ev in
            // Escape cancels recording without changing the shortcut.
            if ev.keyCode == 53 { stop(); return nil }
            let mods = ev.modifierFlags.intersection([.command, .option, .control, .shift])
            settings.shortcutKeyCode = Int(ev.keyCode)
            settings.shortcutModifiers = UInt(mods.rawValue)
            settings.useCustomShortcut = true
            stop()
            onChange()
            return nil   // consume so it doesn't fire app/menu actions
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
