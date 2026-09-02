import Foundation

/// User-defined term replacements, applied after cleanup.
///
/// Covers the two things a speech model reliably gets wrong about your vocabulary:
/// words it splits or cases wrongly ("pager duty" -> "PagerDuty"), and names that
/// are homophones of a commoner spelling ("Justin" -> "Justyn"). The model will
/// never produce the rarer spelling on its own, so no amount of decoder tuning
/// fixes it — but a literal substitution does, for free.
final class UserDictionary {

    static let shared = UserDictionary(fileURL: UserDictionary.defaultFileURL)

    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("Murmur/dictionary.json")
    }

    private let fileURL: URL?
    private let lock = NSLock()
    private var entries: [String: String] = [:]
    private var matcher: NSRegularExpression?
    private var loadedModified: Date?

    /// Terms seeded on first run, so the file explains itself by example.
    private static let seed: [String: String] = [
        "pager duty": "PagerDuty",
        "pagerduty": "PagerDuty",
        "rundeck": "Rundeck",
        "justin": "Justyn",
        "finton labs": "FintonLabs",
        "github": "GitHub",
        "postgres": "Postgres",
    ]

    /// In-memory instance, used by the tests.
    init(entries: [String: String]) {
        self.fileURL = nil
        self.entries = entries
        self.matcher = Self.buildMatcher(for: entries)
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        reloadIfNeeded()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    // MARK: - Applying

    func apply(to text: String) -> String {
        reloadIfNeeded()

        lock.lock()
        let matcher = self.matcher
        let entries = self.entries
        lock.unlock()

        guard let matcher, !entries.isEmpty, !text.isEmpty else { return text }

        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = matcher.matches(in: text, options: [], range: full)
        guard !matches.isEmpty else { return text }

        // Rebuild back-to-front so earlier ranges stay valid, and so a replacement
        // can never itself be re-matched by another rule in the same pass.
        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let matched = String(result[range]).lowercased()
            guard let replacement = entries[matched] else { continue }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    // MARK: - Loading

    private func reloadIfNeeded() {
        guard let fileURL else { return }

        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            writeSeedFile(to: fileURL)
        }

        let modified = (try? fm.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date

        lock.lock(); defer { lock.unlock() }
        guard modified != loadedModified else { return }
        loadedModified = modified

        guard let data = try? Data(contentsOf: fileURL),
              let raw = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            // A malformed file must not take dictation down with it — keep whatever
            // was loaded last and let the user fix their JSON.
            return
        }

        // Keys are matched case-insensitively, so normalise them once here.
        var normalised: [String: String] = [:]
        for (key, value) in raw where !key.isEmpty && !value.isEmpty {
            normalised[key.lowercased()] = value
        }
        entries = normalised
        matcher = Self.buildMatcher(for: normalised)
    }

    private func writeSeedFile(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Self.seed) else { return }
        try? data.write(to: url)
    }

    // MARK: - Matching

    /// One combined pattern rather than a substitution per term: a single pass
    /// cannot cascade, so "justin" -> "Justyn" can never be re-matched by a later
    /// rule keyed on "justyn".
    private static func buildMatcher(for entries: [String: String]) -> NSRegularExpression? {
        guard !entries.isEmpty else { return nil }

        // Longest first, because regex alternation takes the leftmost alternative
        // that matches — without this, "pager" would win over "pager duty".
        let alternatives = entries.keys
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }

        // Lookarounds rather than \b, which misbehaves on terms ending in
        // punctuation such as "c++".
        let pattern = "(?<!\\w)(?:" + alternatives.joined(separator: "|") + ")(?!\\w)"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}
