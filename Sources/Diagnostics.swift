import Foundation
import AppKit
import ApplicationServices

/// Headless self-test, invoked via `LizardType --selftest [/path/to/audio.m4a] [--cookies path]`.
/// Prints permission states and runs transcribe → cleanup so the whole pipeline
/// can be verified from the terminal without the GUI.
@MainActor
enum Diagnostics {
    static func isCLI(_ args: [String]) -> Bool {
        args.contains("--selftest") || args.contains("--diag")
    }

    static func runCLI(_ args: [String]) async {
        func p(_ s: String) { print(s); fflush(stdout) }

        p("=== LizardType self-test ===")
        p(String(format: "Accessibility (AXIsProcessTrusted): %@", AXIsProcessTrusted() ? "YES" : "NO"))
        p(String(format: "Microphone authorized:             %@", PermissionsManager.micAuthorized ? "YES" : "NO"))
        p(String(format: "Input Monitoring:                  %@", PermissionsManager.inputMonitoringTrusted ? "YES" : "NO"))

        let settings = AppSettings.shared
        var cookies = settings.cookiesPath
        if let i = args.firstIndex(of: "--cookies"), i + 1 < args.count { cookies = args[i + 1] }
        p("cookies.json: \(cookies.isEmpty ? "(unset)" : cookies)")

        if args.contains("--diag") { p("=== diag only ==="); return }

        let audio = args.dropFirst().first {
            FileManager.default.fileExists(atPath: $0) && ($0.hasSuffix(".m4a") || $0.hasSuffix(".wav"))
        }

        // --groq forces the Groq path; otherwise follow the configured provider.
        if args.contains("--groq") || settings.provider == .groq {
            await runGroqSelfTest(audio: audio, settings: settings, p: p)
            return
        }

        guard !cookies.isEmpty else { p("no cookies path set → skipping pipeline"); return }

        let bridge = ChatGPTBridge()
        do {
            p("warming bridge…")
            try await bridge.start(cookiesPath: cookies)
            await bridge.waitUntilReady()
            let token = try await bridge.accessToken(forceRefresh: true)
            p("logged in ✓ (access token length \(token.count))")
            if let audio {
                p("transcribing \(audio) …")
                let raw = try await bridge.transcribe(audioURL: URL(fileURLWithPath: audio), language: "zh")
                p("RAW    : \(raw)")
                p("cleaning up…")
                let clean = try await bridge.cleanup(raw: raw, prompt: settings.cleanupPrompt,
                                                     model: settings.model, language: "zh-TW")
                p("CLEAN  : \(clean)")
            } else {
                p("(pass a .m4a/.wav path to also test transcribe + cleanup)")
            }
            p("=== self-test OK ===")
        } catch {
            p("ERROR: \(error.localizedDescription)")
        }
    }

    private static func runGroqSelfTest(audio: String?, settings: AppSettings,
                                        p: (String) -> Void) async {
        p("provider: Groq")
        p("API key: \(GroqSecrets.apiKey() != nil ? "found ✓" : "MISSING ✗")")
        p("transcribe model: \(settings.groqTranscribeModel)")
        p("cleanup model:    \(settings.groqCleanupModel)")
        let groq = GroqClient()
        do {
            try await groq.validate()
            if let audio {
                p("transcribing \(audio) …")
                let raw = try await groq.transcribe(audioURL: URL(fileURLWithPath: audio),
                                                    language: settings.transcribeLanguage)
                p("RAW    : \(raw)")
                p("cleaning up…")
                let clean = try await groq.cleanup(raw: raw, prompt: settings.cleanupPrompt,
                                                   model: settings.groqCleanupModel,
                                                   language: settings.oaiLanguage)
                p("CLEAN  : \(clean)")
            } else {
                p("(pass a .m4a/.wav path to also test transcribe + cleanup)")
            }
            p("=== self-test OK ===")
        } catch {
            p("ERROR: \(error.localizedDescription)")
        }
    }
}
