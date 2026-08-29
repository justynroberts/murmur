import AVFoundation
import Foundation

/// Captures microphone audio and hands back 16 kHz mono float samples,
/// which is the only format the Parakeet models accept.
final class AudioCapture {

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    /// Seconds of audio captured so far.
    var duration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Double(samples.count) / 16_000.0
    }

    func start() throws {
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw MurmurError.noInputDevice }

        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.ingest(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops capture and returns everything recorded.
    @discardableResult
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); defer { lock.unlock() }
        let out = samples
        samples.removeAll(keepingCapacity: true)
        return out
    }

    private func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, let channel = out.floatChannelData?[0] else { return }
        let frames = Int(out.frameLength)
        guard frames > 0 else { return }

        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: frames))
        lock.unlock()
    }
}
