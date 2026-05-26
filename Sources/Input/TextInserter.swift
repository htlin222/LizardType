import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

enum TextInserter {
    /// Puts `text` on the clipboard and, if Accessibility is granted, pastes it
    /// at the cursor via synthesized ⌘V. Returns whether it auto-pasted.
    @discardableResult
    static func insert(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        let trusted = AXIsProcessTrusted()
        NSLog("[LizardType] paste: AXIsProcessTrusted=%@ chars=%d", trusted ? "YES" : "NO", text.count)
        guard trusted else { return false }   // leave on clipboard; can't synthesize keys

        // Synthesize ⌘V at HID level (most reliable; delivered to frontmost app).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let src = CGEventSource(stateID: .hidSystemState)
            let vKey: CGKeyCode = 9   // 'v'
            let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
            down?.flags = .maskCommand
            let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            NSLog("[LizardType] posted ⌘V")
        }
        return true
    }
}
