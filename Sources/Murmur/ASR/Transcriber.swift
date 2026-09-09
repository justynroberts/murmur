import Foundation
import FluidAudio

/// Wraps Parakeet TDT. Everything runs on-device; see `lockOffline()`.
actor Transcriber {

    private var manager: AsrManager?
    private(set) var isReady = false

    /// Loads models, downloading them once if they are not already cached.
    /// After loading, the network door is bolted shut for the rest of the process.
    ///
    /// - Parameter onProgress: called with a human-readable phase and, where known,
    ///   a 0…1 fraction. The compile step is the slow one on a cold process.
    func load(
        allowingDownload: Bool,
        onProgress: @escaping @Sendable (String, Double?) -> Void
    ) async throws {
        ModelHub.offlineMode = !allowingDownload

        // First launch: one zip from GitHub instead of dozens of files from
        // Hugging Face. Any failure is logged and FluidAudio downloads as before.
        if allowingDownload, !ModelMirror.isCached {
            do {
                try await ModelMirror.seed(onProgress: onProgress)
            } catch {
                NSLog("[murmur] model mirror failed (%@); falling back to Hugging Face", error.localizedDescription)
            }
        }

        let models = try await AsrModels.downloadAndLoad(version: .v2) { progress in
            let detail: String
            switch progress.phase {
            case .downloading(let done, let total):
                // After the mirror has seeded the cache there is nothing left to
                // fetch, and FluidAudio reports 0 of 0; say what is happening.
                detail = total == 0 ? "Preparing speech model"
                                    : "Downloading speech model — \(done) of \(total) files"
            case .compiling(let name):
                detail = "Compiling \(name) for the Neural Engine"
            @unknown default:
                detail = "Preparing"
            }
            onProgress(detail, progress.fractionCompleted > 0 ? progress.fractionCompleted : nil)
        }

        onProgress("Warming up", 0.95)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)

        self.manager = manager
        lockOffline()
        isReady = true
    }

    /// Hard offline guarantee: any later attempt to reach the network throws
    /// `DownloadError.networkDisabled` rather than silently succeeding.
    nonisolated func lockOffline() {
        ModelHub.offlineMode = true
    }

    func transcribe(_ samples: [Float]) async throws -> (text: String, elapsed: TimeInterval) {
        guard let manager else { throw MurmurError.modelsNotLoaded }

        // A fresh decoder state per utterance. TdtDecoderState carries LSTM context
        // across chunks for streaming; reusing it would let the previous
        // dictation bleed into the next one.
        var decoderState = try TdtDecoderState()

        let started = CFAbsoluteTimeGetCurrent()
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        return (result.text, CFAbsoluteTimeGetCurrent() - started)
    }
}
