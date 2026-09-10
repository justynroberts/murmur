import AppKit
import AVFoundation
import Foundation
import SwiftUI

/// `murmur selftest <file.wav> [--offline]` exercises the whole pipeline without a
/// keypress, which is how the transcribe path gets verified during development.
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "render-ui" {
    MainActor.assumeIsolated { RenderPreview.run(outputDirectory: CommandLine.arguments[2]) }
    exit(0)
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "cleantest" {
    exit(CleanerTest.run())
}

/// `Murmur.app/Contents/MacOS/Murmur selfupdate` runs the installer headlessly
/// against the latest release, without relaunching. It replaces the bundle it
/// is run from, so run it on a scratch copy.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "selfupdate" {
    var done = false
    Task { @MainActor in
        do {
            print("bundle:  \(Bundle.main.bundleURL.path)  v\(Bundle.main.appVersion)")
            print("team:    \(try UpdateInstaller.teamIdentifier(of: Bundle.main.bundleURL))")
            let info = try await UpdateChecker.fetchLatest()
            print("latest:  \(info.version)")
            try await UpdateInstaller.install(info, relaunch: false) { step in print("  \(step)") }
            print("installed \(info.version) over \(Bundle.main.bundleURL.lastPathComponent)")
        } catch {
            print("selfupdate failed: \(error.localizedDescription)")
            exit(1)
        }
        done = true
    }
    while !done { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
    exit(0)
}

/// `murmur meetingtest` drives meeting mode end to end without a microphone:
/// the segmenter on synthetic audio, a WAV through the real pipeline into a
/// scratch folder, and recovery of a spool left by a simulated crash.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "meetingtest" {
    exit(MainActor.assumeIsolated { MeetingTest.run() })
}

/// `murmur meeting start|stop|toggle` tells the running app what to do, via a
/// distributed notification. Scriptable from Shortcuts or a calendar hook.
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "meeting" {
    let action = CommandLine.arguments[2]
    guard ["start", "stop", "toggle", "debug-fill-panel"].contains(action) else {
        print("usage: Murmur meeting start|stop|toggle"); exit(2)
    }
    DistributedNotificationCenter.default().postNotificationName(
        MeetingRecorder.notificationName, object: action, userInfo: nil, deliverImmediately: true)
    print("sent \(action)")
    exit(0)
}

/// `murmur updatecheck` exercises the opt-in update path headlessly: one
/// request, prints what came back and whether it is newer than this build.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "updatecheck" {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        defer { semaphore.signal() }
        do {
            let info = try await UpdateChecker.fetchLatest()
            let current = Bundle.main.appVersion
            print("latest:  \(info.version)  \(info.url)")
            print("dmg:     \(info.downloadURL?.absoluteString ?? "none")  \(info.downloadSize ?? 0) bytes")
            print("current: \(current)")
            print(UpdateChecker.isNewer(info.version, than: current) ? "update available" : "up to date")
        } catch {
            print("updatecheck failed: \(error)")
            exit(1)
        }
    }
    semaphore.wait()
    exit(0)
}

if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "selftest" {
    runSelftest(path: CommandLine.arguments[2],
                offline: CommandLine.arguments.contains("--offline"))
    exit(0)
}

func runSelftest(path: String, offline: Bool) {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        defer { semaphore.signal() }
        do {
            let samples = try loadSamples(at: path)
            let spoken = Double(samples.count) / 16_000.0

            if offline { print("network: DISABLED for this run") }

            let transcriber = Transcriber()
            let loadStart = CFAbsoluteTimeGetCurrent()
            try await transcriber.load(allowingDownload: !offline) { detail, fraction in
                let pct = fraction.map { String(format: " %.0f%%", $0 * 100) } ?? ""
                print("  \(detail)\(pct)")
            }
            print(String(format: "model load: %.2fs", CFAbsoluteTimeGetCurrent() - loadStart))

            let (raw, elapsed) = try await transcriber.transcribe(samples)
            print(String(format: "audio: %.2fs   asr: %.3fs   %.1fx realtime",
                         spoken, elapsed, spoken / max(elapsed, 0.001)))
            print("raw:     \(raw)")
            print("cleaned: \(RuleCleaner.clean(raw))")
        } catch {
            print("selftest failed: \(error)")
            exit(1)
        }
    }
    semaphore.wait()
}

/// Reads any audio file and resamples it to the 16 kHz mono the models expect.
func loadSamples(at path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                               sampleRate: 16_000, channels: 1, interleaved: false)!

    guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                       frameCapacity: AVAudioFrameCount(file.length)) else {
        throw MurmurError.noInputDevice
    }
    try file.read(into: input)

    guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
        throw MurmurError.noInputDevice
    }
    let capacity = AVAudioFrameCount(
        Double(file.length) * target.sampleRate / file.processingFormat.sampleRate) + 1024
    guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
        throw MurmurError.noInputDevice
    }

    var supplied = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
        if supplied { status.pointee = .noDataNow; return nil }
        supplied = true
        status.pointee = .haveData
        return input
    }
    if let error { throw error }

    guard let channel = output.floatChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        dictation?.meeting.stop(reason: "Murmur quit")
    }

    private var menuBar: MenuBarController?
    private var dictation: DictationController?
    private var updater: UpdateChecker?
    private var setup: SetupWindowController?
    private let state = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Fonts.register()

        let menuBar = MenuBarController(state: state)
        self.menuBar = menuBar

        let dictation = DictationController(state: state)
        self.dictation = dictation

        // Show the panel on first run so the one-off setup is visible rather than
        // looking like a hang behind a silent menu bar icon.
        // Setup gets a real window, on launch, until it has completed once —
        // and again any time Accessibility has been taken away. It does not
        // depend on the menu bar icon being visible.
        let setup = SetupWindowController(state: state)
        self.setup = setup
        state.requestSetupWindow = { [weak setup] in setup?.show() }
        UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
        if !SetupWindowController.hasCompletedSetup || !AXIsProcessTrusted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { setup.show() }
        }

        Task {
            await dictation.boot()
            // Anything a crash or power cut left in the spool is transcribed
            // and appended to its session file before the user does anything.
            let recovered = await dictation.meeting.recover()
            if recovered > 0 {
                state.meetingNote = "Recovered \(recovered) meeting segment\(recovered == 1 ? "" : "s") from the last run."
            }
        }

        // Meeting mode stops on sleep and on quit, and does not resume on its
        // own: better a gap than a transcript of a room nobody meant to record.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dictation?.meeting.stop(reason: "Mac went to sleep") }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: MeetingRecorder.notificationName, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let meeting = self?.dictation?.meeting else { return }
                switch note.object as? String {
                case "start":  meeting.start()
                case "stop":   meeting.stop(reason: "stopped")
                case "debug-fill-panel": self?.menuBar?.debugFillAndPresent()
                default:       meeting.toggle()
                }
            }
        }

        // Does nothing unless the user has switched update checks on.
        let updater = UpdateChecker(state: state)
        self.updater = updater
        updater.start()
    }
}

let app = NSApplication.shared
// Top-level code is not actor-isolated under language mode 5, but it does run on
// the main thread, so asserting that is accurate rather than a workaround.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
