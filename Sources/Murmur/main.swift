import AppKit
import AVFoundation
import Foundation

/// `murmur selftest <file.wav>` exercises the whole pipeline without a keypress,
/// which is how the transcribe path gets verified in CI and during development.
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "selftest" {
    let path = CommandLine.arguments[2]
    let semaphore = DispatchSemaphore(value: 0)

    Task {
        defer { semaphore.signal() }
        do {
            let samples = try loadSamples(at: path)
            let spoken = Double(samples.count) / 16_000.0

            // `--offline` refuses the network outright, proving the app works from
            // cache alone. Any attempt to fetch throws DownloadError.networkDisabled.
            let offline = CommandLine.arguments.contains("--offline")

            let transcriber = Transcriber()
            let loadStart = CFAbsoluteTimeGetCurrent()
            try await transcriber.load(allowingDownload: !offline)
            if offline { print("network: DISABLED for this run") }
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
    exit(0)
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
    let capacity = AVAudioFrameCount(Double(file.length) * target.sampleRate / file.processingFormat.sampleRate) + 1024
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

// Menu-bar style agent: no Dock icon, no main window yet.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let controller = DictationController()
Task { await controller.boot() }

app.run()
