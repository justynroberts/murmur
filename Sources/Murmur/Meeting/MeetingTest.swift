import AVFoundation
import Foundation

/// Run via `Murmur meetingtest`. Three layers, each independent of the last:
///
/// 1. The segmenter on synthetic audio — where cuts land, what is dropped.
/// 2. A WAV pushed through the real recorder into a scratch folder — the
///    file appears, has a header, real words, a footer, and no spool left.
/// 3. Recovery — a spool file planted as if the app had died mid-segment is
///    transcribed and appended to its session file on the next launch.
@MainActor
enum MeetingTest {

    private static var failures = 0

    private static func check(_ ok: Bool, _ note: String, _ detail: @autoclosure () -> String = "") {
        print("\(ok ? "PASS" : "FAIL")  \(note)")
        if !ok { failures += 1; let d = detail(); if !d.isEmpty { print("      \(d)") } }
    }

    static func run() -> Int32 {
        segmenterTests()
        hotKeyTests()

        // The recorder is main-actor bound, so the main thread cannot block on a
        // semaphore while the work waits for it. Pump the run loop instead.
        var done = false
        Task { @MainActor in
            await pipelineTests()
            done = true
        }
        while !done {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }

        print("\n\(failures == 0 ? "all meeting tests passed" : "\(failures) failure(s)")")
        return failures == 0 ? 0 : 1
    }

    // MARK: 0. Tap detection, with synthetic events

    private static func flagsEvent(_ key: HotKey, down: Bool) -> CGEvent {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key.keyCode), keyDown: true)!
        e.type = .flagsChanged
        e.flags = down ? CGEventFlags(rawValue: key.deviceFlag | CGEventFlags.maskControl.rawValue) : []
        return e
    }

    private static func pump() {
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
    }

    private static func hotKeyTests() {
        let m = HotKeyMonitor()
        var t: CFAbsoluteTime = 1000
        m.clock = { t }
        m.keys = [.rightOption, .rightControl]
        var presses: [HotKey] = [], releases: [HotKey] = [], taps: [HotKey] = []
        m.onPress = { presses.append($0) }
        m.onRelease = { releases.append($0) }
        m.onTap = { taps.append($0) }

        // Quick tap of the meeting key.
        m.handle(flagsEvent(.rightControl, down: true)); t += 0.2
        m.handle(flagsEvent(.rightControl, down: false)); pump()
        check(presses == [.rightControl] && releases == [.rightControl] && taps == [.rightControl],
              "quick press+release is a tap", "\(presses) \(releases) \(taps)")

        // Held too long: press and release, no tap.
        taps.removeAll()
        m.handle(flagsEvent(.rightControl, down: true)); t += 1.5
        m.handle(flagsEvent(.rightControl, down: false)); pump()
        check(taps.isEmpty, "a long hold is not a tap")

        // A key pressed while held (Ctrl-C) spoils the tap.
        m.handle(flagsEvent(.rightControl, down: true)); t += 0.1
        m.spoilTaps(); t += 0.1
        m.handle(flagsEvent(.rightControl, down: false)); pump()
        check(taps.isEmpty, "a shortcut is not a tap")

        // Two watched modifiers together are a chord, not a tap.
        m.handle(flagsEvent(.rightOption, down: true)); t += 0.1
        m.handle(flagsEvent(.rightControl, down: true)); t += 0.1
        m.handle(flagsEvent(.rightControl, down: false)); t += 0.1
        m.handle(flagsEvent(.rightOption, down: false)); pump()
        check(taps.isEmpty, "a chord is not a tap")

        // An unwatched key is ignored; a watched one is told apart by device flag.
        presses.removeAll()
        m.handle(flagsEvent(.leftControl, down: true)); pump()
        check(presses.isEmpty, "unwatched Left Control is ignored")
        let leftOnly = CGEvent(keyboardEventSource: nil, virtualKey: 62, keyDown: true)!
        leftOnly.type = .flagsChanged
        leftOnly.flags = CGEventFlags(rawValue: HotKey.leftControl.deviceFlag | CGEventFlags.maskControl.rawValue)
        m.handle(leftOnly); pump()
        check(presses.isEmpty, "Right Control keycode with only the left device flag is not down")

        // Changing keys while one is held releases it.
        m.handle(flagsEvent(.rightControl, down: true)); pump()
        releases.removeAll()
        m.keys = [.rightOption, .leftControl]; pump()
        check(releases == [.rightControl], "a key that stops being watched is released", "\(releases)")
    }

    // MARK: 1. Segmenter

    private static func noise(seconds: Double, amplitude: Float) -> [Float] {
        var g = SystemRandomNumberGenerator()
        return (0..<Int(seconds * 16_000)).map { _ in Float.random(in: -amplitude...amplitude, using: &g) }
    }

    private static func segmenterTests() {
        var seg = Segmenter()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var clock = t0
        var closed: [Segmenter.Segment] = []

        // 1s quiet, 3s speech, 2s quiet, 5s speech, 0.5s quiet, 40s speech, 3s quiet.
        let script: [(Double, Float)] = [(1, 0.002), (3, 0.1), (2, 0.002), (5, 0.1), (0.5, 0.002), (40, 0.1), (3, 0.002)]
        for (seconds, amp) in script {
            let samples = noise(seconds: seconds, amplitude: amp)
            var i = 0
            while i < samples.count {
                let chunk = Array(samples[i..<min(i + 1024, samples.count)])
                if let s = seg.push(chunk, at: clock) { closed.append(s) }
                clock.addTimeInterval(Double(chunk.count) / 16_000)
                i += 1024
            }
        }
        if let s = seg.flush() { closed.append(s) }

        check(closed.count == 4, "four segments from the script", "got \(closed.count): \(closed.map { String(format: "%.1fs", $0.seconds) })")
        guard closed.count == 4 else { return }
        check(abs(closed[0].seconds - 5.5) < 0.2, "first closes 1.5s after the 3s burst", String(format: "%.2fs", closed[0].seconds))
        check(closed[0].hasSpeech, "first has speech")
        check(abs(closed[1].seconds - 30) < 0.1, "a monologue is cut at 30s", String(format: "%.2fs", closed[1].seconds))
        check(closed[2].hasSpeech && closed[2].seconds > 15, "the remainder follows", String(format: "%.2fs", closed[2].seconds))
        check(closed[0].startedAt == t0, "first segment starts at the clock start")
        check(abs(closed[1].startedAt.timeIntervalSince(t0) - 5.5) < 0.2, "second starts where the first ended")

        var quiet = Segmenter()
        var dropped: Segmenter.Segment?
        let silence = noise(seconds: 31, amplitude: 0.002)
        var i = 0
        while i < silence.count, dropped == nil {
            dropped = quiet.push(Array(silence[i..<min(i + 1024, silence.count)]), at: clock)
            i += 1024
        }
        check(dropped != nil && dropped?.hasSpeech == false, "a silent window closes at 30s marked no-speech")
    }

    // MARK: 2 & 3. Real pipeline

    private static func pipelineTests() async {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-meetingtest-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let state = AppState()
        state.transcriptFolder = scratch
        // The setter persists; put the default back so a later render-ui or
        // real run does not inherit the scratch folder.
        defer { UserDefaults.standard.removeObject(forKey: "transcriptFolder") }

        var clock = Date()
        let transcriber = Transcriber()
        do {
            print("  loading models…")
            try await transcriber.load(allowingDownload: true) { _, _ in }
        } catch {
            check(false, "models load", "\(error)"); return
        }

        let recorder = MeetingRecorder(state: state, transcriber: transcriber, now: { clock })

        // A 13.5s clip, fed in 64ms chunks with the clock advancing as audio would.
        guard let samples = try? loadSamples(at: "test_sample.wav") else {
            check(false, "test_sample.wav loads"); return
        }
        recorder.startForTest()
        check(state.meeting != nil, "session starts")
        let fileURL = state.meeting!.fileURL
        check(fileURL.lastPathComponent.hasPrefix("Meeting "), "file is named for the session", fileURL.lastPathComponent)

        var i = 0
        while i < samples.count {
            let chunk = Array(samples[i..<min(i + 1024, samples.count)])
            recorder.ingest(chunk)
            clock.addTimeInterval(Double(chunk.count) / 16_000)
            i += 1024
        }
        let spoolMid = (try? FileManager.default.contentsOfDirectory(atPath: MeetingRecorder.spoolDirectory.path))?
            .filter { $0.hasSuffix(".pcm") } ?? []
        check(!spoolMid.isEmpty, "audio in flight is spooled to disk", "spool dir: \(MeetingRecorder.spoolDirectory.path)")

        clock.addTimeInterval(120)
        recorder.stop(reason: "test")
        await recorder.drainForTest()

        let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        check(text.hasPrefix("# Meeting — "), "header present")
        check(text.contains("**Started** "), "start time recorded")
        check(text.contains("**Ended** ") && text.contains("2 min"), "footer with end time and duration", text.suffix(120).description)
        check(text.contains("1 segment ·"), "one segment counted", text.suffix(120).description)
        let body = text.components(separatedBy: "\n\n").filter { !$0.hasPrefix("#") && !$0.hasPrefix("**") && !$0.hasPrefix("---") && !$0.hasPrefix("_") && !$0.isEmpty }
        check(!body.isEmpty && body.joined().split(separator: " ").count > 8, "real words were written", text)
        check(!text.contains("["), "no clock stamps on lines", text)
        let spoolAfter = (try? FileManager.default.contentsOfDirectory(atPath: MeetingRecorder.spoolDirectory.path))?
            .filter { $0.hasSuffix(".pcm") } ?? []
        check(spoolAfter.isEmpty, "spool is empty after a clean stop", spoolAfter.joined(separator: ", "))
        print("      \(fileURL.lastPathComponent):")
        text.split(separator: "\n").forEach { print("      | \($0)") }

        // Recovery: plant a spool as a crash would leave it, then "relaunch".
        guard let short = try? loadSamples(at: "test_short.wav") else { check(false, "test_short.wav loads"); return }
        let base = fileURL.deletingPathExtension().lastPathComponent
        let spoolURL = MeetingRecorder.spoolDirectory.appendingPathComponent("\(base)__\(Int(clock.timeIntervalSince1970)).pcm")
        try? Data(bytes: short, count: short.count * 4).write(to: spoolURL)
        let before = text
        let recovered = await recorder.recover()
        let after = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        check(recovered == 1, "one segment recovered", "\(recovered)")
        check(after.hasPrefix(before), "recovery appends, never rewrites")
        check(after.contains("## Recovered after an interruption"), "recovery is labelled")
        check(after.count > before.count + 60, "recovered words appended", after.suffix(200).description)
        check(!FileManager.default.fileExists(atPath: spoolURL.path), "spool removed after recovery")
        check(await recorder.recover() == 0, "nothing to recover second time")
    }
}
