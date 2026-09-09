import CryptoKit
import FluidAudio
import Foundation

/// Seeds FluidAudio's model cache from a single zip on GitHub, so first launch
/// is one download rather than dozens of small files from Hugging Face. The
/// archive is the unmodified FluidInference CoreML conversion of Parakeet TDT
/// 0.6B v2 (CC BY 4.0), published as a prerelease asset so it never becomes
/// the app's "latest" release. Any failure falls back to FluidAudio's own
/// download, so the mirror can only ever make things faster, not break them.
enum ModelMirror {

    static let archiveURL = URL(string:
        "https://github.com/justynroberts/murmur/releases/download/models-parakeet-v2/parakeet-tdt-0.6b-v2-coreml.zip")!
    /// SHA-256 of the published archive. Changing the asset means changing this.
    static let archiveSHA256 = "63bff06d260ab8713344e611a890f406dc30169847569eecdd7e674b29fb7474"
    static let version: AsrModelVersion = .v2

    /// Where FluidAudio expects the files. Mirrors its default: it loads from
    /// here without downloading if the required files are present.
    static var cacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v2", isDirectory: true)
    }

    static var isCached: Bool {
        AsrModels.modelsExist(at: cacheDirectory, version: version)
    }

    enum MirrorError: LocalizedError {
        case checksum, unpack
        var errorDescription: String? {
            switch self {
            case .checksum: return "The mirrored model did not match its checksum."
            case .unpack:   return "The mirrored model could not be unpacked."
            }
        }
    }

    /// Downloads, verifies and unpacks into the cache. Throws on any problem;
    /// the caller falls back to FluidAudio. `onProgress` gets a phrase and a
    /// 0…1 fraction.
    static func seed(onProgress: @escaping @Sendable (String, Double?) -> Void) async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-model-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let zip = tmp.appendingPathComponent("model.zip")

        onProgress("Downloading speech model", nil)
        try await Downloader.fetch(archiveURL, to: zip) { written, total in
            let mb = Int(written / 1_048_576)
            if let total {
                onProgress("Downloading speech model — \(mb) of \(Int(total / 1_048_576)) MB",
                           Double(written) / Double(total) * 0.9)
            } else {
                onProgress("Downloading speech model — \(mb) MB", nil)
            }
        }

        onProgress("Checking the download", 0.92)
        guard try sha256(of: zip) == archiveSHA256 else { throw MirrorError.checksum }

        onProgress("Unpacking speech model", 0.95)
        let parent = cacheDirectory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: cacheDirectory)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, parent.path]
        ditto.standardOutput = Pipe(); ditto.standardError = Pipe()
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0, isCached else {
            try? FileManager.default.removeItem(at: cacheDirectory)
            throw MirrorError.unpack
        }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
