import Foundation

/// Tier one cleanup: instant, deterministic, and lossless by design.
///
/// Deliberately conservative. Benchmarking a 1.7B local model showed it silently
/// deleting whole clauses, which is far worse than leaving a stray "um" in place,
/// so this pass only removes things it can prove are noise.
enum RuleCleaner {

    /// Non-lexical vocalisations, matched as patterns rather than a word list so
    /// that elongations come free — "uhhhh", "errrr" and "aaaah" all match without
    /// having to enumerate every spelling a speaker might stretch a sound into.
    ///
    /// Every pattern here is a sound that is never a word in its own right. Real
    /// words that merely *feel* like filler — "so", "well", "like", "right", "oh" —
    /// are deliberately absent: they carry meaning often enough that removing them
    /// would change what the speaker said.
    private static let fillerPattern: NSRegularExpression = {
        let sounds = [
            "u+m+",       // um, umm, ummm
            "u+h+",       // uh, uhh, uhhhh
            "u+h+m+",     // uhm
            "e+r+m+",     // erm, errm
            "e+r+",       // er, err, errrr
            "a+h+",       // ah, ahh, aaah
            "o{2,}h*",    // ooh, oooh, oo — two or more o's, so "oh" is left alone
            "h+m+",       // hm, hmm, hmmm
            "m{2,}",      // mm, mmm
            "m+h+m+",     // mhm, mhmm
            "e+h+",       // eh, ehh
            "h+u+h+",     // huh
            "u+g+h+",     // ugh
            "a+r+g+h+",   // argh
            "p+f+t*",     // pff, pfft
            "t+s+k+",     // tsk
        ]
        let pattern = "^(?:" + sounds.joined(separator: "|") + ")$"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// True when a bare word is nothing but a vocal noise.
    static func isFiller(_ word: String) -> Bool {
        let bare = word.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted)
        guard !bare.isEmpty else { return false }
        let range = NSRange(bare.startIndex..<bare.endIndex, in: bare)
        return fillerPattern.firstMatch(in: bare, options: [], range: range) != nil
    }

    static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        text = stripFillers(text)

        // An utterance that was nothing but noise leaves nothing to insert. Return
        // empty rather than a lone full stop.
        guard !text.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).isEmpty else {
            return ""
        }

        text = tidyPunctuation(text)
        text = capitaliseSentences(text)

        if let last = text.last, !".!?".contains(last) {
            text.append(".")
        }
        return text
    }

    private static func stripFillers(_ text: String) -> String {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true)
        var kept: [Substring] = []
        var atSentenceStart = true

        for token in tokens {
            defer {
                if let last = token.last, ".!?".contains(last) {
                    atSentenceStart = true
                } else {
                    atSentenceStart = false
                }
            }

            // "Ah" and "Er" are names. A capitalised token in the middle of a
            // sentence is a proper noun, not a noise — the speech model only
            // capitalises mid-sentence words when it believes they are one.
            // At a sentence start the capital says nothing, so filler still goes.
            let isProperNoun = !atSentenceStart && (token.first?.isUppercase ?? false)

            if isFiller(String(token)) && !isProperNoun { continue }
            kept.append(token)
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
