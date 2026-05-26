import AppKit
import SwiftUI

/// Opens the settings/diagnostics window reliably for an accessory (menu-bar) app.
/// Accessory apps can't normally focus windows, so we temporarily switch to a
/// regular activation policy while the window is open (reverted on close) — this
/// is what makes text fields and the shortcut recorder work.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()
    private var window: NSWindow?

    func show(tab: SettingsTab = .general) {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            w.title = "LizardType"
            w.isReleasedWhenClosed = false
            w.center()
            w.delegate = self
            window = w
        }
        window?.contentView = NSHostingView(rootView: SettingsView(tab: tab))
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // back to menu-bar-only
    }
}
