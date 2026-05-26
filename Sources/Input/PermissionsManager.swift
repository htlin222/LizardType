import Foundation
import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics

/// Microphone (TCC) + Accessibility (AX) permission helpers.
enum PermissionsManager {

    // MARK: Microphone
    static var micAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMic() async -> Bool {
        if micAuthorized { return true }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: Accessibility (needed for CGEventTap hotkey + synthesized ⌘V)
    static var accessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the system "grant Accessibility" dialog if not yet trusted.
    @discardableResult
    static func promptAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openMicSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Input Monitoring (needed for active key-combo CGEventTaps)
    static var inputMonitoringTrusted: Bool {
        CGPreflightListenEventAccess()
    }

    @discardableResult
    static func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }

    static func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}
