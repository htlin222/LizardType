import Foundation
import ServiceManagement
import AppKit

/// Keeps LizardType alive across the macOS "Accessibility grant kills the app"
/// behaviour, and starts it at login.
///
/// We register a launchd agent (bundled at
/// `Contents/Library/LaunchAgents/com.lizardtype.keepalive.plist`) with
/// `KeepAlive = { SuccessfulExit = false }`. When the user toggles Accessibility,
/// macOS SIGKILLs us — an *unsuccessful* exit — so launchd relaunches within a
/// couple of seconds and the menu-bar icon comes back on its own. A clean Quit
/// (exit 0) is *successful*, so launchd leaves us quit. SIGKILL can't be trapped
/// in-process, which is why this has to live at the launchd layer.
enum LaunchManager {
    private static let plistName = "com.lizardtype.keepalive.plist"

    private static var service: SMAppService { SMAppService.agent(plistName: plistName) }

    /// Whether launchd currently owns our lifecycle.
    static var isEnabled: Bool { service.status == .enabled }

    static var statusDescription: String {
        switch service.status {
        case .enabled:          return "enabled"
        case .notRegistered:    return "not registered"
        case .requiresApproval: return "needs approval in Login Items"
        case .notFound:         return "agent plist not found in bundle"
        @unknown default:       return "unknown"
        }
    }

    /// Register the keep-alive / launch-at-login agent.
    @discardableResult
    static func enable() -> Bool {
        do {
            try service.register()
            NSLog("[LizardType] launch agent registered (%@)", statusDescription)
            if service.status == .requiresApproval {
                // The user previously disabled it; point them at the toggle.
                SMAppService.openSystemSettingsLoginItems()
            }
            return service.status == .enabled
        } catch {
            NSLog("[LizardType] launch agent register failed: %@", error.localizedDescription)
            return false
        }
    }

    static func disable() {
        do { try service.unregister() }
        catch { NSLog("[LizardType] launch agent unregister failed: %@", error.localizedDescription) }
    }

    /// Reconcile registration with the user's desired setting.
    static func sync(enabled: Bool) {
        if enabled { enable() } else { disable() }
    }

    /// Clean relaunch that survives the single-instance guard: a detached shell
    /// waits for us to exit, then reopens the bundle. Works whether or not the
    /// keep-alive agent is enabled.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}
