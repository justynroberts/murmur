import Foundation

/// One file, to disk, with progress. Delegate-based so the bytes go straight
/// to a file on a background thread; iterating an AsyncBytes stream byte by
/// byte is CPU-bound and takes minutes for a few hundred megabytes.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    enum DownloadError: LocalizedError {
        case http(Int), moveFailed, cancelled
        var errorDescription: String? {
            switch self {
            case .http(let code): return "The server answered \(code)."
            case .moveFailed:     return "The downloaded file could not be saved."
            case .cancelled:      return "The download was cancelled."
            }
        }
    }

    private let destination: URL
    private let onProgress: @Sendable (Int64, Int64?) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private init(destination: URL, onProgress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    /// Downloads `url` to `destination`, replacing anything there.
    static func fetch(_ url: URL, to destination: URL,
                      onProgress: @escaping @Sendable (_ written: Int64, _ total: Int64?) -> Void) async throws {
        let d = Downloader(destination: destination, onProgress: onProgress)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            d.continuation = c
            var request = URLRequest(url: url)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            d.session.downloadTask(with: request).resume()
        }
        d.session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            continuation?.resume(throwing: DownloadError.http(http.statusCode)); continuation = nil; return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            continuation?.resume(); continuation = nil
        } catch {
            continuation?.resume(throwing: DownloadError.moveFailed); continuation = nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error); continuation = nil
        }
    }
}
