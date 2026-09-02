import AppKit
import AVFoundation
import Foundation

/// Wires the push-to-talk loop together: hold key -> record -> transcribe -> clean -> inject.
@MainActor
final class DictationController {

    private let hotKey = HotKeyMonitor()
    private let audio = AudioCapture()
    private let transcriber = Transcriber()
    private let state: AppState

    private var isRecording = false
    private var pressedAt: CFAbsoluteTime = 0
    private var tick: Timer?

    /// Audio captured before the models finished loading. Held rather than dropped,
    /// so speaking during first-run setup is not silently lost.
    private var pending: [Float]?
    private var modelsReady = false

    /// Ignore an accidental tap of the key rather than firing an empty transcription.
    private let minimumHold: TimeInterval = 0.25

    init(state: AppState) {
        self.state = state
    }

    func boot() async {
        // Create the word list on launch so it is there to be found and edited,
        // rather than appearing only after the first dictation.
        _ = UserDictionary.shared.count

        guard requestAccessibility() else {
            state.phase = .failed("Grant Accessibility in System Settings, then relaunch.")
            return
        }
        guard await requestMicrophone() else {
            state.phase = .failed("Microphone access was denied.")
            return
        }

        // Arm the hotkey *before* the models load, so a first-run user can already
        // speak; the audio is queued and transcribed the moment setup finishes.
        hotKey.onPress = { [weak self] in self?.beginRecording() }
        hotKey.onRelease = { [weak self] in self?.endRecording() }
        do {
            try hotKey.start()
        } catch {
            state.phase = .failed("Could not install the hotkey: \(error.localizedDescription)")
            return
        }

        state.phase = .settingUp(detail: "Preparing", fraction: nil)
        do {
            try await transcriber.load(allowingDownload: true) { [weak self] detail, fraction in
                Task { @MainActor in
                    guard let self, self.state.phase.isBusy else { return }
                    self.state.phase = .settingUp(detail: detail, fraction: fraction)
                }
            }
        } catch {
            state.phase = .failed("Model load failed: \(error.localizedDescription)")
            return
        }

        modelsReady = true
        state.phase = .ready

        if let queued = pending {
            pending = nil
            state.queuedWhileLoading = false
            await process(queued)
        }
    }

    // MARK: - Recording

    private func beginRecording() {
        guard !isRecording else { return }
        do {
            try audio.start()
            isRecording = true
            pressedAt = CFAbsoluteTimeGetCurrent()

            if modelsReady { state.phase = .recording(seconds: 0) }

            tick = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isRecording, self.modelsReady else { return }
                    self.state.phase = .recording(seconds: CFAbsoluteTimeGetCurrent() - self.pressedAt)
                }
            }
        } catch {
            state.phase = .failed("Could not start capture: \(error.localizedDescription)")
        }
    }

    private func endRecording() {
        guard isRecording else { return }
        isRecording = false
        tick?.invalidate(); tick = nil

        let held = CFAbsoluteTimeGetCurrent() - pressedAt
        let samples = audio.stop()

        guard held >= minimumHold, samples.count > 1_600 else {
            if modelsReady { state.phase = .ready }
            return
        }

        guard modelsReady else {
            pending = samples
            state.queuedWhileLoading = true
            return
        }

        state.phase = .transcribing
        Task { await process(samples) }
    }

    private func process(_ samples: [Float]) async {
        let spoken = Double(samples.count) / 16_000.0
        do {
            let (raw, elapsed) = try await transcriber.transcribe(samples)
            let cleaned = RuleCleaner.clean(raw)

            guard !cleaned.isEmpty, cleaned != "." else {
                state.phase = .ready
                return
            }

            var injected = true
            do {
                try TextInjector.insert(cleaned)
            } catch {
                injected = false
                state.phase = .failed(error.localizedDescription)
            }

            state.record(Dictation(text: cleaned, spoken: spoken,
                                   latency: elapsed, injected: injected))
            if injected { state.phase = .ready }
        } catch {
            state.phase = .failed("Transcription failed: \(error.localizedDescription)")
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
}
