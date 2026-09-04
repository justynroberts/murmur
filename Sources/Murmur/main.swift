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
    private var menuBar: MenuBarController?
    private var dictation: DictationController?
    private var updater: UpdateChecker?
    private let state = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Fonts.register()

        let menuBar = MenuBarController(state: state)
        self.menuBar = menuBar

        let dictation = DictationController(state: state)
        self.dictation = dictation

        // Show the panel on first run so the one-off setup is visible rather than
        // looking like a hang behind a silent menu bar icon.
        if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            // The status item has no window until the run loop turns, and a
            // popover anchored to a windowless button never appears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                menuBar.presentOnce()
            }
        }

        Task { await dictation.boot() }

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
