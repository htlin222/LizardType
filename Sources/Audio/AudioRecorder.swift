import Foundation
import AVFoundation
import Combine

/// Records mic audio to a temp `.m4a` (AAC, 16 kHz mono) and publishes a
/// normalized 0…1 level for the recording overlay.
@MainActor
final class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var level: Float = 0
    /// Rolling history of recent levels (newest last) for the scrolling waveform.
    @Published var levels: [Float] = Array(repeating: 0, count: AudioRecorder.barCount)
    @Published var isRecording = false

    static let barCount = 32

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private(set) var currentURL: URL?
    private(set) var startedAt: Date?

    /// Begin recording. Throws if the recorder can't be created.
    func start() throws {
        stopTimer()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lizardtype_\(Int(Date().timeIntervalSince1970 * 1000)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.delegate = self
        rec.isMeteringEnabled = true
        guard rec.record() else {
            throw NSError(domain: "LizardType", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "AVAudioRecorder failed to start (mic permission?)"])
        }
        recorder = rec
        currentURL = url
        startedAt = Date()
        isRecording = true
        levels = Array(repeating: 0, count: AudioRecorder.barCount)
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateLevel() }
        }
    }

    private func updateLevel() {
        guard let rec = recorder, rec.isRecording else { return }
        rec.updateMeters()
        // map ~-55 dBFS (quiet) … -10 dBFS (loud) → 0…1, with a slight curve for liveliness
        let db = rec.averagePower(forChannel: 0)
        let norm = max(0, min(1, (db + 55) / 45))
        let v = pow(norm, 0.65)
        level = v
        var arr = levels
        arr.removeFirst()
        arr.append(v)
        levels = arr
    }

    /// Stop and return the recorded file URL, plus duration in ms.
    func stop() -> (url: URL, durationMs: Double)? {
        stopTimer()
        isRecording = false
        level = 0
        guard let rec = recorder, let url = currentURL else { return nil }
        let dur = (startedAt.map { Date().timeIntervalSince($0) } ?? 0) * 1000
        rec.stop()
        recorder = nil
        return (url, dur)
    }

    /// Stop and discard the recording.
    func cancel() {
        stopTimer()
        isRecording = false
        level = 0
        recorder?.stop()
        if let url = currentURL { try? FileManager.default.removeItem(at: url) }
        recorder = nil
        currentURL = nil
    }

    func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func stopTimer() {
        meterTimer?.invalidate()
        meterTimer = nil
    }
}
