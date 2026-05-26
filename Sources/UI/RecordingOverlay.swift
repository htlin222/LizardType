import Foundation
import AppKit
import SwiftUI
import Combine

/// Drives what the floating overlay shows.
@MainActor
final class OverlayState: ObservableObject {
    enum Phase: Equatable {
        case recording
        case transcribing
        case cleaning
        case done(String)      // brief success flash (pasted text preview)
        case error(String)
    }
    @Published var phase: Phase = .recording
    let recorder: AudioRecorder
    var onStop: (() -> Void)?
    init(recorder: AudioRecorder) { self.recorder = recorder }
}

/// Floating, non-activating overlay. Must NOT steal focus (we paste into the
/// frontmost app), hence `.nonactivatingPanel`.
@MainActor
final class OverlayController {
    private var panel: NSPanel?
    private var state: OverlayState?
    private var autoHide: DispatchWorkItem?

    func attach(recorder: AudioRecorder) {
        state = OverlayState(recorder: recorder)
    }

    func setStopHandler(_ handler: @escaping () -> Void) {
        state?.onStop = handler
    }

    private func ensurePanel() {
        guard panel == nil, let state else { return }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 60),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: OverlayView(state: state))
        panel = p
    }

    /// Show (or update) the overlay with a phase.
    func show(_ phase: OverlayState.Phase) {
        autoHide?.cancel()
        ensurePanel()
        state?.phase = phase
        // Only intercept clicks while recording (for the ■ stop button); otherwise
        // let clicks pass through to the app behind the overlay.
        if case .recording = phase { panel?.ignoresMouseEvents = false }
        else { panel?.ignoresMouseEvents = true }
        position()
        panel?.orderFrontRegardless()

        // auto-hide for terminal phases
        switch phase {
        case .done:  scheduleHide(after: 2.5)
        case .error: scheduleHide(after: 3.5)
        default: break
        }
    }

    func hide() {
        autoHide?.cancel()
        panel?.orderOut(nil)
    }

    private func scheduleHide(after: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        autoHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: work)
    }

    private func position() {
        guard let panel, let screen = NSScreen.main else { return }
        let f = panel.frame
        let v = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: v.midX - f.width / 2, y: v.minY + 90))
    }
}

struct OverlayView: View {
    @ObservedObject var state: OverlayState

    private var isRecording: Bool { state.phase == .recording }

    var body: some View {
        HStack(spacing: 11) {
            content
        }
        .padding(.horizontal, 18)
        .frame(width: isRecording ? 300 : 244, height: 64)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.84))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                )
        )
        .animation(.easeInOut(duration: 0.18), value: isRecording)
    }

    @ViewBuilder private var content: some View {
        switch state.phase {
        case .recording:
            PulsingMic(recorder: state.recorder)
            Waveform(recorder: state.recorder)
            Button(action: { state.onStop?() }) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.red))
            }
            .buttonStyle(.plain)
            .help("Stop & transcribe")
        case .transcribing:
            ProcessingIndicator(icon: "waveform", label: "Transcribing", tint: .cyan)
        case .cleaning:
            ProcessingIndicator(icon: "sparkles", label: "Cleaning up", tint: .yellow)
        case .done(let preview):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(preview).foregroundStyle(.white).font(.callout).lineLimit(1)
        case .error(let msg):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(msg).foregroundStyle(.white).font(.caption).lineLimit(2)
        }
    }
}

/// Lively "working" indicator: a twinkling/pulsing SF Symbol + sequential dots.
struct ProcessingIndicator: View {
    let icon: String
    let label: String
    let tint: Color
    @State private var pulse = false
    @State private var dot = 0
    private let timer = Timer.publish(every: 0.28, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.variableColor.iterative.hideInactiveLayers, options: .repeating)
                .scaleEffect(pulse ? 1.12 : 0.92)
                .shadow(color: tint.opacity(0.6), radius: pulse ? 7 : 2)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
            Text(label).foregroundStyle(.white).font(.callout.weight(.medium))
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(.white)
                        .frame(width: 5, height: 5)
                        .opacity(dot == i ? 1 : 0.3)
                        .scaleEffect(dot == i ? 1.25 : 0.85)
                        .animation(.easeOut(duration: 0.2), value: dot)
                }
            }
        }
        .onAppear { pulse = true }
        .onReceive(timer) { _ in dot = (dot + 1) % 3 }
    }
}

/// Mic glyph whose glow pulses with the current level.
private struct PulsingMic: View {
    @ObservedObject var recorder: AudioRecorder
    var body: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.red)
            .shadow(color: .red.opacity(Double(recorder.level)), radius: 6)
            .scaleEffect(1 + CGFloat(recorder.level) * 0.18)
            .animation(.easeOut(duration: 0.08), value: recorder.level)
    }
}

/// Scrolling, volume-reactive waveform: a rolling history of amplitude samples,
/// each bar mirrored around the centerline (Voice-Memos style).
struct Waveform: View {
    @ObservedObject var recorder: AudioRecorder

    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 2.5
    private let maxH: CGFloat = 34
    private let minH: CGFloat = 3

    private let grad = LinearGradient(
        colors: [Color(red: 0.45, green: 1.0, blue: 0.85), Color(red: 0.25, green: 0.7, blue: 1.0)],
        startPoint: .top, endPoint: .bottom)

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(recorder.levels.indices, id: \.self) { idx in
                Capsule()
                    .fill(grad)
                    .frame(width: barWidth, height: height(for: recorder.levels[idx], at: idx))
                    .opacity(0.55 + 0.45 * Double(recorder.levels[idx]))
            }
        }
        .frame(height: maxH, alignment: .center)
        .animation(.easeOut(duration: 0.07), value: recorder.levels)
    }

    private func height(for lvl: Float, at idx: Int) -> CGFloat {
        // gently taper the leading (oldest) edge so it scrolls in smoothly
        let n = recorder.levels.count
        let edge = CGFloat(min(idx, n - 1 - idx, 4)) / 4.0   // 0 at edges → 1 inside
        let taper = 0.6 + 0.4 * edge
        return minH + (maxH - minH) * CGFloat(lvl) * taper
    }
}
