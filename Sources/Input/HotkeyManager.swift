import Foundation
import AppKit
import CoreGraphics

/// Global push-to-talk via a CGEventTap. Two trigger styles:
///  - `.modifier`: hold a single modifier key (e.g. Right ⌥). listen-only.
///  - `.keyCombo`: hold an arbitrary key + modifiers (e.g. ⌃⌥D, F5). The matched
///    key is consumed so it doesn't leak to the focused app.
/// Press-and-hold → `onStart`; release → `onStop`.
final class HotkeyManager {

    enum Trigger {
        case modifier(TriggerKind)
        case keyCombo(keyCode: Int64, mods: CGEventFlags)
    }

    static let stdMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onKeyDebug: ((String) -> Void)?   // for the Diagnostics live readout

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var active = false
    private var trigger: Trigger = .modifier(.rightOption)

    var isInstalled: Bool { tap != nil }

    private func modKeyCode(_ t: TriggerKind) -> Int64 {
        switch t {
        case .rightOption:  return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        case .fn:           return 63
        }
    }
    private func modMask(_ t: TriggerKind) -> CGEventFlags {
        switch t {
        case .rightOption:  return .maskAlternate
        case .rightCommand: return .maskCommand
        case .rightControl: return .maskControl
        case .fn:           return .maskSecondaryFn
        }
    }

    @discardableResult
    func start(trigger: Trigger) -> Bool {
        self.trigger = trigger
        stop()

        let mask: CGEventMask
        let options: CGEventTapOptions
        switch trigger {
        case .modifier:
            mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            options = .listenOnly
        case .keyCombo:
            mask = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue))
            // listen-only: active taps that can alter the stream are gated far more
            // strictly by macOS and silently receive nothing; observing is reliable.
            options = .listenOnly
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: options, eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                let consume = mgr.handle(type: type, event: event)
                return consume ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            return false
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        switch trigger {
        case .modifier(let t): NSLog("[LizardType] tap installed: modifier %@", "\(t)")
        case .keyCombo(let kc, let mods): NSLog("[LizardType] tap installed: keyCombo key=%d mods=%llu", Int(kc), mods.rawValue)
        }
        return true
    }

    func updateTrigger(_ t: Trigger) {
        if tap != nil { start(trigger: t) } else { trigger = t }
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        tap = nil; runLoopSource = nil; active = false
    }

    /// Returns true if the event should be consumed (dropped).
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        switch trigger {
        case .modifier(let t):
            guard type == .flagsChanged else { return false }
            let kc = event.getIntegerValueField(.keyboardEventKeycode)
            guard kc == modKeyCode(t) else { return false }
            setActive(event.flags.contains(modMask(t)))
            return false   // never consume modifier keys

        case .keyCombo(let keyCode, let mods):
            let kc = event.getIntegerValueField(.keyboardEventKeycode)
            let want = mods.intersection(HotkeyManager.stdMask)
            let have = event.flags.intersection(HotkeyManager.stdMask)
            // Live readout for Diagnostics (proves whether the tap receives keys).
            let tname = type == .keyDown ? "down" : (type == .keyUp ? "up" : "\(type.rawValue)")
            DispatchQueue.main.async { [weak self] in
                self?.onKeyDebug?("kc=\(kc) \(tname) mods=\(have.rawValue) (want kc=\(keyCode) mods=\(want.rawValue))")
            }
            guard kc == keyCode else { return false }
            if type == .keyDown {
                if have == want, !active { setActive(true) }
                return false   // listen-only: never consume
            } else if type == .keyUp {
                if active { setActive(false) }
                return false
            }
            return false
        }
    }

    private func setActive(_ on: Bool) {
        if on && !active {
            active = true
            DispatchQueue.main.async { [weak self] in self?.onStart?() }
        } else if !on && active {
            active = false
            DispatchQueue.main.async { [weak self] in self?.onStop?() }
        }
    }
}
