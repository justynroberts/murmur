import Foundation

/// Cuts a continuous stream into utterance-sized segments for the transcriber,
/// which sees 15 seconds at a time and has no memory beyond that. Pure logic
/// with an injected clock, so `MeetingTest` can drive it deterministically.
///
/// A segment closes on a pause after some speech, or at `maxSeconds` regardless
/// so a monologue still reaches the file every half minute. Windows with no
/// speech in them are dropped: a quiet hour writes nothing.
struct Segmenter {

    struct Segment {
        let samples: [Float]
        let startedAt: Date
        let hasSpeech: Bool
        var seconds: Double { Double(samples.count) / 16_000 }
    }

    let sampleRate = 16_000
    var maxSeconds: Double = 30
    var silenceSeconds: Double = 1.5
    var minSeconds: Double = 2
    /// RMS above this counts as speech. Room noise on a laptop mic sits around
    /// 0.002–0.005; quiet speech at arm's length is 0.02 and up.
    var threshold: Float = 0.012

    private(set) var buffer: [Float] = []
    private(set) var startedAt: Date?
    private var hadSpeech = false
    private var silentSamples = 0

    var isEmpty: Bool { buffer.isEmpty }

    /// Feed a chunk; returns a segment when one closes.
    mutating func push(_ chunk: [Float], at now: Date) -> Segment? {
        guard !chunk.isEmpty else { return nil }
        if buffer.isEmpty { startedAt = now }
        buffer.append(contentsOf: chunk)

        if Self.rms(chunk) > threshold {
            hadSpeech = true
            silentSamples = 0
        } else {
            silentSamples += chunk.count
        }

        let seconds = Double(buffer.count) / Double(sampleRate)
        let pause = Double(silentSamples) / Double(sampleRate)
        if seconds >= maxSeconds || (hadSpeech && pause >= silenceSeconds && seconds >= minSeconds) {
            return close()
        }
        return nil
    }

    /// Close whatever is pending, e.g. on stop.
    mutating func flush() -> Segment? {
        buffer.isEmpty ? nil : close()
    }

    private mutating func close() -> Segment {
        let segment = Segment(samples: buffer, startedAt: startedAt ?? Date(), hasSpeech: hadSpeech)
        buffer.removeAll(keepingCapacity: true)
        startedAt = nil
        hadSpeech = false
        silentSamples = 0
        return segment
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}
