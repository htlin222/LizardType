import Foundation
import Combine
import AppKit

/// Hold-to-talk trigger. We default to holding a single modifier key (most
/// ergonomic for push-to-talk) but also support a regular key+modifiers chord.
enum TriggerKind: String, Codable, CaseIterable {
    case rightOption    // hold ⌥ (right)
    case rightCommand   // hold ⌘ (right)
    case rightControl   // hold ⌃ (right)
    case fn             // hold Fn / globe

    var label: String {
        switch self {
        case .rightOption:  return "Right Option ⌥ (hold)"
        case .rightCommand: return "Right Command ⌘ (hold)"
        case .rightControl: return "Right Control ⌃ (hold)"
        case .fn:           return "Fn / 🌐 (hold)"
        }
    }
}

/// UserDefaults-backed app settings (observable).
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var cookiesPath: String { didSet { d.set(cookiesPath, forKey: "cookiesPath") } }
    @Published var trigger: TriggerKind { didSet { d.set(trigger.rawValue, forKey: "trigger") } }
    // Custom shortcut (any key + modifiers). When enabled, overrides `trigger`.
    @Published var useCustomShortcut: Bool { didSet { d.set(useCustomShortcut, forKey: "useCustomShortcut") } }
    @Published var shortcutKeyCode: Int { didSet { d.set(shortcutKeyCode, forKey: "shortcutKeyCode") } }
    @Published var shortcutModifiers: UInt { didSet { d.set(Int(shortcutModifiers), forKey: "shortcutModifiers") } }
    @Published var transcribeLanguage: String { didSet { d.set(transcribeLanguage, forKey: "transcribeLanguage") } }
    @Published var oaiLanguage: String { didSet { d.set(oaiLanguage, forKey: "oaiLanguage") } }
    @Published var model: String { didSet { d.set(model, forKey: "model") } }
    @Published var cleanupEnabled: Bool { didSet { d.set(cleanupEnabled, forKey: "cleanupEnabled") } }
    @Published var cleanupPrompt: String { didSet { d.set(cleanupPrompt, forKey: "cleanupPrompt") } }
    @Published var playSounds: Bool { didSet { d.set(playSounds, forKey: "playSounds") } }
    @Published var maxRecordingSeconds: Int { didSet { d.set(maxRecordingSeconds, forKey: "maxRecordingSeconds") } }

    var shortcutDisplay: String {
        useCustomShortcut ? KeyFormatter.string(keyCode: shortcutKeyCode, modifiers: shortcutModifiers)
                          : trigger.label
    }

    private init() {
        cookiesPath = d.string(forKey: "cookiesPath") ?? ""
        trigger = TriggerKind(rawValue: d.string(forKey: "trigger") ?? "") ?? .rightOption
        useCustomShortcut = d.bool(forKey: "useCustomShortcut")
        shortcutKeyCode = d.object(forKey: "shortcutKeyCode") as? Int ?? 49   // Space
        shortcutModifiers = (d.object(forKey: "shortcutModifiers") as? Int).map(UInt.init)
            ?? UInt(NSEvent.ModifierFlags([.control, .option]).rawValue)
        transcribeLanguage = d.string(forKey: "transcribeLanguage") ?? "zh"
        oaiLanguage = d.string(forKey: "oaiLanguage") ?? "zh-TW"
        model = d.string(forKey: "model") ?? "gpt-5-5"
        cleanupEnabled = d.object(forKey: "cleanupEnabled") as? Bool ?? true
        cleanupPrompt = d.string(forKey: "cleanupPrompt") ?? Prompts.defaultCleanup
        playSounds = d.object(forKey: "playSounds") as? Bool ?? true
        maxRecordingSeconds = d.object(forKey: "maxRecordingSeconds") as? Int ?? 60
    }
}
