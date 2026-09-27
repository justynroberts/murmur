import Foundation

/// Spoken phrase → text. Say the phrase on its own and the text is inserted
/// instead: a signature, a standard reply, a block of boilerplate. Lives in
/// macros.json next to the word list; re-read when the file changes.
///
/// `{date}` and `{time}` in the text are filled in; `\n` in the JSON is a
/// real newline by the time it is pasted.
final class UserMacros {

    static let shared = UserMacros(fileURL: UserMacros.defaultFileURL)

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur/macros.json")
    }

    private let fileURL: URL?
    private let lock = NSLock()
    private var entries: [String: String] = [:]
    private var loadedModified: Date?

    private static let seed: [String: String] = [
        "sign off": "Thanks,\nJustyn",
        "standup": "Yesterday: \nToday: \nBlocked: ",
        "commit template": "type(scope): summary\n\nWhy this change:\n",
    ]

    init(entries: [String: String]) {
        self.fileURL = nil
        self.entries = Self.normalised(entries)
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        reloadIfNeeded()
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    /// The expansion for an utterance that is exactly a macro phrase, else nil.
    func expand(_ utterance: String, now: Date = Date()) -> String? {
        reloadIfNeeded()
        let key = Self.key(utterance)
        lock.lock(); let text = entries[key]; lock.unlock()
        guard let text else { return nil }
        let date = DateFormatter(); date.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter(); time.dateFormat = "HH:mm"
        return text.replacingOccurrences(of: "{date}", with: date.string(from: now))
                   .replacingOccurrences(of: "{time}", with: time.string(from: now))
    }

    /// Lowercased, punctuation stripped, single spaces — what the model's
    /// "Sign off." and the file's "sign off" both become.
    nonisolated static func key(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined()
            .split(separator: " ").joined(separator: " ")
    }

    private static func normalised(_ raw: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in raw where !key(k).isEmpty { out[key(k)] = v }
        return out
    }

    private func reloadIfNeeded() {
        guard let fileURL else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: Self.seed, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: fileURL)
            }
        }
        let modified = (try? fm.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date
        lock.lock(); let stale = modified != loadedModified; lock.unlock()
        guard stale else { return }
        guard let data = try? Data(contentsOf: fileURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        lock.lock()
        entries = Self.normalised(raw)
        loadedModified = modified
        lock.unlock()
    }
}
