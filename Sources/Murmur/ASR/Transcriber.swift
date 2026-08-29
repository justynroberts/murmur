import Foundation
import FluidAudio

/// Wraps Parakeet TDT. Everything runs on-device; see `lockOffline()`.
actor Transcriber {

    private var manager: AsrManager?
    private(set) var isReady = false

    /// Loads models, downloading them once if they are not already cached.
    /// After loading, the network door is bolted shut for the rest of the process.
    func load(allowingDownload: Bool) async throws {
        ModelHub.offlineMode = !allowingDownload

        let models = try await AsrModels.downloadAndLoad(version: .v2)  // v2 = English-only, fastest
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)

        self.manager = manager
        lockOffline()
        isReady = true
    }

    /// Hard offline guarantee: any later attempt to reach the network throws
    /// `DownloadError.networkDisabled` rather than quietly succeeding.
    nonisolated func lockOffline() {
        ModelHub.offlineMode = true
    }

    func transcribe(_ samples: [Float]) async throws -> (text: String, elapsed: TimeInterval) {
        guard let manager else { throw MurmurError.modelsNotLoaded }

        // A fresh decoder state per utterance. TdtDecoderState carries LSTM context
        // across chunks for streaming; reusing it here would let the previous
        // dictation bleed into the next one.
        var decoderState = try TdtDecoderState()

        let started = CFAbsoluteTimeGetCurrent()
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        return (result.text, CFAbsoluteTimeGetCurrent() - started)
    }
}
