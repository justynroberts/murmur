import AppKit
import Foundation

/// One meeting transcript on disk, with what can be read off its header
/// and footer without parsing the body.
struct TranscriptItem: Identifiable, Equatable {
    let url: URL
    let title: String          // "Meeting — Thursday 11 September 2026"
    let started: Date          // from the file name, so sorting never depends on the header
    let startedClock: String?  // "09:00"
    let endedClock: String?    // "09:47"
    let length: String?        // "47 min"
    let segments: Int?
    let bytes: Int
    let modified: Date

    var id: URL { url }
    var fileName: String { url.lastPathComponent }
    var isComplete: Bool { endedClock != nil }
}

/// The transcript folder as a list, plus the few file operations the window
/// offers. Re-read on demand; the window refreshes while it is visible so a
/// meeting in progress grows in place.
@MainActor
final class TranscriptStore: ObservableObject {
    @Published private(set) var items: [TranscriptItem] = []
    @Published private(set) var folder: URL

    init(folder: URL) {
        self.folder = folder
    }

    func setFolder(_ url: URL) {
        folder = url
        reload()
    }

    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        items = urls
            .filter { $0.pathExtension == "md" && $0.lastPathComponent.hasPrefix("Meeting ") }
            .compactMap { Self.item(at: $0) }
            .sorted { $0.started > $1.started }
    }

    func contents(of item: TranscriptItem) -> String {
        (try? String(contentsOf: item.url, encoding: .utf8)) ?? ""
    }

    func copyMarkdown(_ item: TranscriptItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(contents(of: item), forType: .string)
    }

    /// The transcript without the header and footer furniture: what you paste
    /// into a document or a message.
    func copyPlainText(_ item: TranscriptItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(Self.plainText(of: contents(of: item)), forType: .string)
    }

    func trash(_ item: TranscriptItem) throws {
        try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        reload()
    }

    // MARK: - Parsing (pure, tested by MeetingTest)

    nonisolated static let fileStamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm"; return f
    }()

    nonisolated static func item(at url: URL) -> TranscriptItem? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("Meeting "),
              let started = fileStamp.date(from: String(name.dropFirst("Meeting ".count)))
        else { return nil }
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let bytes = (attrs[.size] as? Int) ?? 0
        let modified = (attrs[.modificationDate] as? Date) ?? started

        // Only the head and tail are read; a long meeting is not parsed to list it.
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let head = text.prefix(400), tail = text.suffix(400)
        let title = head.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? name
        let startedClock = match(#"\*\*Started\*\* (\d\d:\d\d)"#, in: String(head))
        let footer = match(#"\*\*Ended\*\* (\d\d:\d\d) · ([^·]+) · (\d+) segments? · "#, in: String(tail), groups: 3)
        return TranscriptItem(url: url, title: title, started: started, startedClock: startedClock,
                              endedClock: footer?[0], length: footer?[1].trimmingCharacters(in: .whitespaces),
                              segments: footer.flatMap { Int($0[2]) }, bytes: bytes, modified: modified)
    }

    nonisolated static func plainText(of markdown: String) -> String {
        markdown.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("# ") && !$0.hasPrefix("## ") && !$0.hasPrefix("**Started**")
                      && !$0.hasPrefix("**Ended**") && $0 != "---" && !($0.hasPrefix("_") && $0.hasSuffix("_")) }
            .joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func match(_ pattern: String, in s: String, groups: Int = 1) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1...groups).compactMap { Range(m.range(at: $0), in: s).map { String(s[$0]) } }
    }
    nonisolated private static func match(_ pattern: String, in s: String) -> String? {
        match(pattern, in: s, groups: 1)?.first
    }
}

/// The subset of Markdown a transcript uses, as blocks the window can draw.
/// Inline emphasis inside a block is handled by AttributedString.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case rule
    case note(String)          // _italic line_ — recovery notes
    case paragraph(String)

    nonisolated static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph.removeAll() }
        }
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line == "---" { flush(); blocks.append(.rule); continue }
            if line.hasPrefix("## ") { flush(); blocks.append(.heading(level: 2, text: String(line.dropFirst(3)))); continue }
            if line.hasPrefix("# ") { flush(); blocks.append(.heading(level: 1, text: String(line.dropFirst(2)))); continue }
            if line.count > 2, line.hasPrefix("_"), line.hasSuffix("_") { flush(); blocks.append(.note(String(line.dropFirst().dropLast()))); continue }
            paragraph.append(line)
        }
        flush()
        return blocks
    }
}
