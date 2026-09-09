import AppKit
import AVFoundation
import Combine
import Foundation

/// Wires the push-to-talk loop together: hold key -> record -> transcribe -> clean -> inject.
@MainActor
final class DictationController {

    private let hotKey = HotKeyMonitor()
    private let audio = AudioCapture()
    private let transcriber = Transcriber()
    private let state: AppState
    /// Meeting mode shares the transcriber, so its segments and dictations
    /// queue through the same actor instead of racing for the Neural Engine.
    let meeting: MeetingRecorder

    private var isRecording = false
    private var pressedAt: CFAbsoluteTime = 0
    private var tick: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// Audio captured before the models finished loading. Held rather than dropped,
    /// so speaking during first-run setup is not silently lost.
    private var pending: [Float]?
    private var modelsReady = false

    /// Ignore an accidental tap of the key rather than firing an empty transcription.
    private let minimumHold: TimeInterval = 0.25

    init(state: AppState) {
        self.state = state
        self.meeting = MeetingRecorder(state: state, transcriber: transcriber)
        state.requestMeetingStop = { [weak self] in self?.meeting.stop(reason: "stopped") }
        state.requestMeetingStart = { [weak self] in self?.meeting.start() }
        hotKey.keys = [state.hotKey, state.meetingKey]
        state.$hotKey.combineLatest(state.$meetingKey)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] dictate, meet in self?.hotKey.keys = [dictate, meet] }
            .store(in: &cancellables)
    }

    func boot() async {
        // Create the word list on launch so it is there to be found and edited,
        // rather than appearing only after the first dictation.
        _ = UserDictionary.shared.count

        // Ask once (this is what puts the system dialog up, when macOS decides
        // to show one), then wait. The panel shows what is missing with a button
        // into the right System Settings pane, and the grant is picked up live,
        // so nobody has to relaunch.
        _ = requestAccessibility()
        var microphone = await requestMicrophone()
        while !AXIsProcessTrusted() || !microphone {
            state.phase = .permissions(accessibility: AXIsProcessTrusted(), microphone: microphone)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !microphone {
                microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            }
        }

        // Arm the hotkey *before* the models load, so a first-run user can already
        // speak; the audio is queued and transcribed the moment setup finishes.
        hotKey.onPress = { [weak self] key in
            guard let self, key == self.state.hotKey else { return }
            self.beginRecording()
        }
        hotKey.onRelease = { [weak self] key in
            guard let self, key == self.state.hotKey else { return }
            self.endRecording()
        }
        hotKey.onTap = { [weak self] key in
            guard let self, key == self.state.meetingKey else { return }
            self.meeting.toggle()
        }
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
