import Foundation

/// Tier one cleanup: instant, deterministic, and lossless by design.
///
/// Deliberately conservative. Benchmarking a 1.7B local model showed it silently
/// deleting whole clauses, which is far worse than leaving a stray "um" in place,
/// so this pass only removes things it can prove are noise.
enum RuleCleaner {

    private static let fillers: Set<String> = [
        "um", "umm", "uh", "uhh", "erm", "er", "ah", "ahh", "hmm", "mm", "mhm"
    ]

    static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        text = stripFillers(text)
        text = tidyPunctuation(text)
        text = capitaliseSentences(text)

        if let last = text.last, !".!?".contains(last) {
            text.append(".")
        }
        return text
    }

    private static func stripFillers(_ text: String) -> String {
        let kept = text.split(separator: " ", omittingEmptySubsequences: true).filter { token in
            let bare = token.lowercased().trimmingCharacters(
                in: CharacterSet.alphanumerics.inverted
            )
            return !fillers.contains(bare)
        }
        return kept.joined(separator: " ")
    }

    private static func tidyPunctuation(_ text: String) -> String {
        var s = text
        for (from, to) in [(" ,", ","), (" .", "."), (" ?", "?"), (" !", "!"),
                           (",,", ","), (".,", "."), (",.", ".")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }

        // A removed filler can strand punctuation at the very front ("um, so" -> ", so").
        while let first = s.first, ",.!? ".contains(first) {
            s.removeFirst()
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func capitaliseSentences(_ text: String) -> String {
        var out = ""
        var capitaliseNext = true
        for ch in text {
            if capitaliseNext, ch.isLetter {
                out.append(Character(ch.uppercased()))
                capitaliseNext = false
            } else {
                out.append(ch)
                if ".!?".contains(ch) { capitaliseNext = true }
            }
        }
        return out
    }
}
