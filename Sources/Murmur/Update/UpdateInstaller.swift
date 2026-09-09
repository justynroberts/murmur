import AppKit
import Foundation
import Security

/// Downloads a release, checks it was signed by the same Developer ID as the
/// running app, swaps it over the running bundle and relaunches. Only ever
/// runs when the user presses Update; the daily check never downloads.
///
/// If anything refuses — an unwritable Applications folder, a signature that
/// does not match — it falls back to opening the disk image in Finder so the
/// user can drag it themselves, and says so.
@MainActor
enum UpdateInstaller {

    enum Step: Equatable {
        case downloading(fraction: Double?)
        case verifying
        case installing
        case relaunching
        case failed(String)
    }

    enum InstallError: LocalizedError {
        case noDownload, badDownload, mountFailed, noAppInImage, unsigned(String), teamMismatch(String, String), swapFailed(String)
        var errorDescription: String? {
            switch self {
            case .noDownload: return "This release has no disk image to download."
            case .badDownload: return "The download did not complete."
            case .mountFailed: return "The disk image could not be opened."
            case .noAppInImage: return "The disk image does not contain Murmur."
            case .unsigned(let why): return "The downloaded app failed signature validation: \(why)"
            case .teamMismatch(let a, let b): return "The download is signed by \(b), not \(a). Not installing it."
            case .swapFailed(let why): return "Could not replace the app: \(why)"
            }
        }
    }

    /// Runs the whole thing. `relaunch: false` is for the headless test.
    static func install(_ update: UpdateInfo, relaunch: Bool = true,
                        progress: @escaping @MainActor (Step) -> Void) async throws {
        guard let downloadURL = update.downloadURL else { throw InstallError.noDownload }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-update-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let dmg = tmp.appendingPathComponent(downloadURL.lastPathComponent)

        progress(.downloading(fraction: nil))
        try await download(downloadURL, to: dmg, expected: update.downloadSize) { progress(.downloading(fraction: $0)) }

        progress(.verifying)
        let mount = try attach(dmg)
        defer { detach(mount); try? FileManager.default.removeItem(at: tmp) }

        let candidates = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? []
        guard let newApp = candidates.first(where: { $0.pathExtension == "app" }) else { throw InstallError.noAppInImage }

        let mine = try teamIdentifier(of: Bundle.main.bundleURL)
        let theirs = try teamIdentifier(of: newApp)
        guard mine == theirs else { throw InstallError.teamMismatch(mine, theirs) }

        progress(.installing)
        let current = Bundle.main.bundleURL
        try swap(newApp, over: current)

        if relaunch {
            progress(.relaunching)
            let sh = Process()
            sh.executableURL = URL(fileURLWithPath: "/bin/sh")
            sh.arguments = ["-c", "sleep 1; /usr/bin/open \"\(current.path)\""]
            try sh.run()
            NSApp.terminate(nil)
        }
    }

    // MARK: - Steps

    /// A download task with a delegate, for progress. Streaming the body
    /// byte-by-byte through AsyncBytes took two minutes for 11 MB.
    private static func download(_ url: URL, to file: URL, expected: Int?,
                                 progress: @escaping @MainActor (Double?) -> Void) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        let delegate = DownloadDelegate(destination: file, progress: progress)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            delegate.completion = { cont.resume(with: $0) }
            session.downloadTask(with: url).resume()
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        if let expected, size != expected { throw InstallError.badDownload }
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let destination: URL
        let progress: @MainActor (Double?) -> Void
        var completion: ((Result<Void, Error>) -> Void)?
        private var lastReport = Date.distantPast

        init(destination: URL, progress: @escaping @MainActor (Double?) -> Void) {
            self.destination = destination
            self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard Date().timeIntervalSince(lastReport) > 0.2 else { return }
            lastReport = Date()
            let fraction = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil
            let report = progress
            Task { @MainActor in report(fraction) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // The temp file is gone when this returns; move it now.
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                    throw InstallError.badDownload
                }
                completion?(.success(())); completion = nil
            } catch {
                completion?(.failure(error)); completion = nil
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { completion?(.failure(error)); completion = nil }
        }
    }

    private static func attach(_ dmg: URL) throws -> URL {
        let out = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-noautoopen", "-plist", dmg.path])
        guard let plist = try? PropertyListSerialization.propertyList(from: out, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mount = entities.compactMap({ $0["mount-point"] as? String }).first
        else { throw InstallError.mountFailed }
        return URL(fileURLWithPath: mount, isDirectory: true)
    }

    private static func detach(_ mount: URL) {
        _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"])
    }

    /// Validates the signature and returns the Team ID. A bundle with no team
    /// (ad-hoc, a local dev build) throws, which means: never auto-install
    /// over a build that could not have come from a release.
    static func teamIdentifier(of bundle: URL) throws -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else {
            throw InstallError.unsigned("not a signed bundle")
        }
        var error: Unmanaged<CFError>?
        guard SecStaticCodeCheckValidityWithErrors(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil, &error) == errSecSuccess else {
            throw InstallError.unsigned(error?.takeRetainedValue().localizedDescription ?? "invalid")
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        else { throw InstallError.unsigned("no Team ID") }
        return team
    }

    /// Copy in beside the current bundle, then two renames. The running
    /// process keeps its mapped pages, so it survives until it relaunches.
    private static func swap(_ newApp: URL, over current: URL) throws {
        let fm = FileManager.default
        let parent = current.deletingLastPathComponent()
        let staged = parent.appendingPathComponent(current.lastPathComponent + ".update")
        let old = parent.appendingPathComponent(current.lastPathComponent + ".previous")
        try? fm.removeItem(at: staged); try? fm.removeItem(at: old)

        // ditto keeps the signature, resource forks and the stapled ticket intact.
        _ = try run("/usr/bin/ditto", [newApp.path, staged.path])
        do {
            try fm.moveItem(at: current, to: old)
        } catch {
            try? fm.removeItem(at: staged)
            throw InstallError.swapFailed(error.localizedDescription)
        }
        do {
            try fm.moveItem(at: staged, to: current)
        } catch {
            try? fm.moveItem(at: old, to: current)
            throw InstallError.swapFailed(error.localizedDescription)
        }
        try? fm.removeItem(at: old)
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw InstallError.swapFailed("\(URL(fileURLWithPath: tool).lastPathComponent) exited \(p.terminationStatus)")
        }
        return data
    }
}
