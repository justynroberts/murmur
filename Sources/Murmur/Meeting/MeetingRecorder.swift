import AVFoundation
import Foundation

/// Meeting mode: continuous capture, transcribed as it goes, written to one
/// Markdown file per session. Audio is never kept — except for the seconds of
/// the segment currently being spoken, which sit in a spool file on disk until
/// their transcript is safely written, so that a crash or a power cut loses
/// nothing that was heard. See `recover()`.
///
/// Everything here runs on the main actor. The capture callback arrives on the
/// audio thread and is bounced over immediately; the transcriber is an actor,
/// so meeting segments and dictations interleave without stepping on each other.
@MainActor
final class MeetingRecorder {

    struct Session: Equatable {
        let startedAt: Date
        let fileURL: URL
        var segments = 0
        var lastSavedAt: Date?
    }

    nonisolated static let notificationName = Notification.Name("com.fintonlabs.murmur.meeting")

    private let state: AppState
    private let transcriber: Transcriber
    private let capture = AudioCapture()
    private let now: () -> Date

    private var segmenter = Segmenter()
    private var spool: FileHandle?
    private var spoolURL: URL?
    private var flushTimer: Timer?
    private var queue: Task<Void, Never>?
    private var session: Session?

    /// How often the transcript and spool are forced to disk, on top of the
    /// sync that happens every time a segment lands. Power loss inside this
    /// window costs nothing the spool cannot replay.
    static let flushInterval: TimeInterval = 60

    init(state: AppState, transcriber: Transcriber, now: @escaping () -> Date = Date.init) {
        self.state = state
        self.transcriber = transcriber
        self.now = now
    }

    var isRecording: Bool { session != nil }

    // MARK: - Session control

    func toggle() {
        if isRecording { stop(reason: "stopped") } else { start() }
    }

    func start() {
        guard session == nil else { return }
        let started = now()
        let folder = state.transcriptFolder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: Self.spoolDirectory, withIntermediateDirectories: true)
        } catch {
            state.meetingNote = "Could not create the transcript folder: \(error.localizedDescription)"
            return
        }

        let fileURL = folder.appendingPathComponent(Self.fileName(for: started))
        do {
            try Self.header(for: started).write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            state.meetingNote = "Could not write to \(folder.path): \(error.localizedDescription)"
            return
        }

        segmenter = Segmenter()
        capture.onSamples = { [weak self] chunk in
            DispatchQueue.main.async { self?.ingest(chunk) }
        }
        do {
            try capture.start()
        } catch {
            state.meetingNote = "Could not start the microphone: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        session = Session(startedAt: started, fileURL: fileURL)
        state.meeting = session
        state.meetingNote = nil

        flushTimer = Timer.scheduledTimer(withTimeInterval: Self.flushInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushToDisk() }
        }
    }

    func stop(reason: String) {
        guard let ending = session else { return }
        capture.stop()
        capture.onSamples = nil
        flushTimer?.invalidate(); flushTimer = nil

        if let last = segmenter.flush() { enqueue(last) }
        closeSpool()

        session = nil
        state.meeting = nil

        // The footer goes on after every queued segment has landed, so the
        // file ends with its last words rather than a footer in the middle.
        let ended = now()
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let count = self.completedSegments[ending.fileURL] ?? 0
            self.append(Self.footer(started: ending.startedAt, ended: ended, segments: count, reason: reason),
                        to: ending.fileURL)
            self.completedSegments[ending.fileURL] = nil
        }
    }

    // MARK: - Audio in

    private var completedSegments: [URL: Int] = [:]

    /// Test hook: feed samples as if they had come from the microphone.
    func ingest(_ chunk: [Float]) {
        guard session != nil else { return }
        if spool == nil { openSpool(startedAt: now()) }
        spool?.write(Data(bytes: chunk, count: chunk.count * MemoryLayout<Float>.size))

        if let segment = segmenter.push(chunk, at: now()) {
            enqueue(segment)
        }
    }

    private func enqueue(_ segment: Segmenter.Segment) {
        let spoolURL = self.spoolURL
        closeSpool()

        guard segment.hasSpeech, let fileURL = session?.fileURL ?? lastFileURL else {
            if let spoolURL { try? FileManager.default.removeItem(at: spoolURL) }
            return
        }
        lastFileURL = fileURL

        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            // Meeting mode can be switched on during first-run setup; the
            // audio is already safe in the spool, so just wait for the models.
            while await !self.transcriber.isReady {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            do {
                let (raw, _) = try await self.transcriber.transcribe(segment.samples)
                let text = RuleCleaner.clean(raw)
                if let spoolURL { try? FileManager.default.removeItem(at: spoolURL) }
                // Room noise can pass the gate and transcribe to nothing; only
                // a segment that put words in the file counts as one.
                guard !text.isEmpty, text != "." else { return }
                self.append(text + "\n\n", to: fileURL)
                self.completedSegments[fileURL, default: 0] += 1
                if self.session?.fileURL == fileURL {
                    self.session?.segments += 1
                    self.session?.lastSavedAt = self.now()
                    self.state.meeting = self.session
                }
            } catch {
                // Leave the spool where it is: recover() will retry it next launch.
                self.state.meetingNote = "A segment could not be transcribed; its audio is kept for recovery."
            }
        }
    }
    private var lastFileURL: URL?

    // MARK: - Files

    private func append(_ text: String, to url: URL) {
        guard let data = text.data(using: .utf8) else { return }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            state.meetingNote = "Could not write the transcript: \(error.localizedDescription)"
        }
    }

    private func flushToDisk() {
        try? spool?.synchronize()
        if let url = session?.fileURL, let h = try? FileHandle(forWritingTo: url) {
            try? h.synchronize(); try? h.close()
        }
    }

    // MARK: - Spool (what survives a crash)

    static var spoolDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur/spool", isDirectory: true)
    }

    private func openSpool(startedAt: Date) {
        guard let session else { return }
        // Name carries the session file and the segment start, so recovery
        // knows where the words belong and in what order.
        let name = "\(session.fileURL.deletingPathExtension().lastPathComponent)__\(Int(startedAt.timeIntervalSince1970)).pcm"
        let url = Self.spoolDirectory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        spool = try? FileHandle(forWritingTo: url)
        spoolURL = url
    }

    private func closeSpool() {
        try? spool?.synchronize()
        try? spool?.close()
        spool = nil
        spoolURL = nil
    }

    /// Replays any spool files left by a crash or power cut: each is
    /// transcribed and appended to the session file it belongs to, under a
    /// heading that says so. Returns the number of segments recovered.
    @discardableResult
    func recover() async -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Self.spoolDirectory.path) else { return 0 }
        let files = names.filter { $0.hasSuffix(".pcm") }.sorted()
        guard !files.isEmpty else { return 0 }

        var recovered = 0
        var touched: Set<URL> = []
        for name in files {
            let url = Self.spoolDirectory.appendingPathComponent(name)
            defer { try? fm.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url), data.count >= 4 * 16_000 else { continue }
            let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            guard Segmenter.rms(samples) > 0.004 else { continue }

            let base = String(name.split(separator: "_", omittingEmptySubsequences: false)
                                .prefix(while: { !$0.isEmpty }).joined(separator: "_"))
            let fileURL = state.transcriptFolder.appendingPathComponent(base + ".md")
            if !fm.fileExists(atPath: fileURL.path) {
                try? Self.header(for: Date()).write(to: fileURL, atomically: true, encoding: .utf8)
            }
            if !touched.contains(fileURL) {
                append("\n## Recovered after an interruption\n\n", to: fileURL)
                touched.insert(fileURL)
            }
            do {
                let (raw, _) = try await transcriber.transcribe(samples)
                let text = RuleCleaner.clean(raw)
                if !text.isEmpty, text != "." { append(text + "\n\n", to: fileURL) }
                recovered += 1
            } catch {
                continue
            }
        }
        for fileURL in touched {
            append("_Recovered \(recovered) segment\(recovered == 1 ? "" : "s") at \(Self.clock.string(from: now()))._\n", to: fileURL)
        }
        return recovered
    }

    // MARK: - Test hooks

    /// Starts a session without touching the microphone; `ingest` feeds it.
    func startForTest() {
        let started = now()
        let folder = state.transcriptFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Self.spoolDirectory, withIntermediateDirectories: true)
        let fileURL = folder.appendingPathComponent(Self.fileName(for: started))
        try? Self.header(for: started).write(to: fileURL, atomically: true, encoding: .utf8)
        segmenter = Segmenter()
        session = Session(startedAt: started, fileURL: fileURL)
        state.meeting = session
    }

    /// Waits for every queued segment and the footer to land.
    func drainForTest() async {
        await queue?.value
    }

    // MARK: - Format

    static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let fileStamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm"; return f
    }()
    private static let longDate: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE d MMMM yyyy"; return f
    }()

    static func fileName(for date: Date) -> String {
        "Meeting \(fileStamp.string(from: date)).md"
    }

    static func header(for started: Date) -> String {
        "# Meeting — \(longDate.string(from: started))\n\n**Started** \(clock.string(from: started))\n\n"
    }

    static func footer(started: Date, ended: Date, segments: Int, reason: String) -> String {
        let seconds = Int(ended.timeIntervalSince(started))
        let length = seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min"
        return "\n---\n\n**Ended** \(clock.string(from: ended)) · \(length) · \(segments) segment\(segments == 1 ? "" : "s") · \(reason)\n"
    }
}
