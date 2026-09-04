import Combine
import Foundation

struct UpdateInfo: Equatable {
    let version: String
    let url: URL
}

/// Asks GitHub for the newest release tag. **Opt-in only.** It never runs
/// unless `AppState.checkForUpdates` is on, and when it does the only thing
/// that leaves the machine is one request for the latest version number —
/// no identifier, no audio, no text. The session is ephemeral so nothing is
/// cached or persisted between checks either.
///
/// It is the one network path besides the model download, and it must stay
/// that narrow: see ARCHITECTURE.md.
@MainActor
final class UpdateChecker {

    nonisolated static let endpoint = URL(string: "https://api.github.com/repos/justynroberts/murmur/releases/latest")!
    nonisolated static let interval: TimeInterval = 24 * 60 * 60
    private static let lastCheckKey = "lastUpdateCheck"

    private let state: AppState
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(state: AppState) {
        self.state = state
    }

    func start() {
        state.requestUpdateCheck = { [weak self] in self?.check() }
        state.$checkForUpdates
            .removeDuplicates()
            .sink { [weak self] on in on ? self?.arm() : self?.disarm() }
            .store(in: &cancellables)
    }

    /// Switched on: check now — the user just consented and wants to see it
    /// work — then once a day while the app runs.
    private func arm() {
        checkIfDue()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
    }

    /// Switched off: nothing in flight, nothing scheduled, nothing shown.
    private func disarm() {
        timer?.invalidate(); timer = nil
        task?.cancel(); task = nil
        state.availableUpdate = nil
        state.updateStatus = .idle
    }

    private func checkIfDue() {
        if let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < Self.interval {
            state.updateStatus = .checked(last)
            return
        }
        check()
    }

    func check() {
        guard state.checkForUpdates else { return }
        task?.cancel()
        state.updateStatus = .checking
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let info = try await Self.fetchLatest()
                let now = Date()
                UserDefaults.standard.set(now, forKey: Self.lastCheckKey)
                self.state.availableUpdate =
                    Self.isNewer(info.version, than: Bundle.main.appVersion) ? info : nil
                self.state.updateStatus = .checked(now)
            } catch is CancellationError {
            } catch {
                self.state.updateStatus = .failed
            }
        }
    }

    enum UpdateError: Error { case badResponse }

    nonisolated static func fetchLatest() async throws -> UpdateInfo {
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = json["html_url"] as? String,
              let url = URL(string: page)
        else { throw UpdateError.badResponse }

        return UpdateInfo(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, url: url)
    }

    /// Numeric, component-wise. "dev" (the bare binary) parses to zero, so
    /// every real release counts as newer — correct, if only for previews.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
