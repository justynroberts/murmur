import AppKit
import AVFoundation
import Foundation

/// Wires the push-to-talk loop together: hold key -> record -> transcribe -> clean -> inject.
final class DictationController {

    private let hotKey = HotKeyMonitor()
    private let audio = AudioCapture()
    private let transcriber = Transcriber()

    private var isRecording = false
    private var pressedAt: CFAbsoluteTime = 0

    /// Ignore an accidental tap of the key rather than firing an empty transcription.
    private let minimumHold: TimeInterval = 0.25

    func boot() async {
        guard requestAccessibility() else {
            log("Grant Accessibility to Murmur in System Settings > Privacy & Security, then relaunch.")
            return
        }
        guard await requestMicrophone() else {
            log("Microphone access denied.")
            return
        }

        log("Loading Parakeet models…")
        let started = CFAbsoluteTimeGetCurrent()
        do {
            try await transcriber.load(allowingDownload: true)
        } catch {
            log("Model load failed: \(error.localizedDescription)")
            return
        }
        log(String(format: "Models ready in %.1fs. Network is now locked off.",
                   CFAbsoluteTimeGetCurrent() - started))

        hotKey.onPress = { [weak self] in self?.beginRecording() }
        hotKey.onRelease = { [weak self] in self?.endRecording() }

        do {
            try hotKey.start()
            log("Hold RIGHT OPTION to dictate. Release to insert.")
        } catch {
            log("Could not install the hotkey tap: \(error.localizedDescription)")
        }
    }

    // MARK: - Recording

    private func beginRecording() {
        guard !isRecording else { return }
        do {
            try audio.start()
            isRecording = true
            pressedAt = CFAbsoluteTimeGetCurrent()
            log("● recording")
        } catch {
            log("Could not start capture: \(error.localizedDescription)")
        }
    }

    private func endRecording() {
        guard isRecording else { return }
        isRecording = false

        let held = CFAbsoluteTimeGetCurrent() - pressedAt
        let samples = audio.stop()

        guard held >= minimumHold, samples.count > 16_000 / 10 else {
            log("… too short, ignored")
            return
        }

        let spoken = Double(samples.count) / 16_000.0
        Task { [weak self] in
            guard let self else { return }
            do {
                let (raw, elapsed) = try await self.transcriber.transcribe(samples)
                let cleaned = RuleCleaner.clean(raw)

                await MainActor.run {
                    self.log(String(format: "%.2fs speech -> %.3fs asr (%.1fx realtime)",
                                    spoken, elapsed, spoken / max(elapsed, 0.001)))
                    self.log("   raw:     \(raw)")
                    self.log("   cleaned: \(cleaned)")
                    do {
                        try TextInjector.insert(cleaned)
                    } catch {
                        self.log("   ! \(error.localizedDescription)")
                    }
                }
            } catch {
                self.log("Transcription failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Permissions

    private func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    private func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func log(_ message: String) {
        print("[murmur] \(message)")
        fflush(stdout)
    }
}
