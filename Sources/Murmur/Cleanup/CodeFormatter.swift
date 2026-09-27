import Foundation

/// How the cleaned text is going to be used. Prose is the default everywhere;
/// code turns on the symbol vocabulary, which would otherwise eat real words
/// like "pipe" and "dash" out of a sentence. Identifier modes ("camel case…")
/// are explicit enough to be on in both.
enum CleanupProfile: String {
    case prose, code
}

/// "…send" at the end of an utterance presses Enter after the paste, in any
/// app. Stripped from the raw text before cleaning, so "send." from the model
/// is handled too. "Send" on its own presses Enter and inserts nothing.
enum SendSuffix {
    static func strip(_ raw: String) -> (text: String, send: Bool) {
        var tokens = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let last = tokens.last else { return (raw, false) }
        let bare = last.trimmingCharacters(in: CharacterSet(charactersIn: ",.?!;:")).lowercased()
        guard bare == "send" else { return (raw, false) }
        tokens.removeLast()
        return (tokens.joined(separator: " "), true)
    }
}

/// Spoken formatting for developers: identifier casing modes and a symbol
/// vocabulary, as a rule pass so it stays instant and lossless.
///
///   "rename it to camel case user session token, then save"
///     → "rename it to userSessionToken, then save"
///   "snake case max retry count equals three"          (code profile)
///     → "max_retry_count = three"
///
/// An identifier runs from the mode phrase to the next punctuation, the word
/// "end", or the end of the utterance. The speech model puts a comma where you
/// pause, so pausing is how you close an identifier.
enum CodeFormatter {

    struct Result {
        let text: String
        /// True when the utterance ends in an identifier or symbol, which must
        /// not get a full stop stuck on it.
        let endsWithCode: Bool
    }

    private enum Mode: String, CaseIterable {
        case camel, snake, kebab, constant, pascal, dot, slash
        var trigger: String { self == .slash ? "path" : "case" }   // "slash path usr local bin"
        func join(_ words: [String]) -> String {
            switch self {
            case .camel:
                guard let first = words.first else { return "" }
                return lowerFirst(first) + words.dropFirst().map(upperFirst).joined()
            case .pascal:   return words.map(upperFirst).joined()
            case .snake:    return words.map { $0.lowercased() }.joined(separator: "_")
            case .kebab:    return words.map { $0.lowercased() }.joined(separator: "-")
            case .constant: return words.map { $0.uppercased() }.joined(separator: "_")
            case .dot:      return words.map { $0.lowercased() }.joined(separator: ".")
            case .slash:    return words.map { $0.lowercased() }.joined(separator: "/")
            }
        }
        private func lowerFirst(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }
        private func upperFirst(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
    }

    private enum Attach { case left, right, both, spaced, line }

    /// Longest phrases first, so "double equals" wins over "equals".
    private static let symbols: [(phrase: [String], glyph: String, attach: Attach)] = [
        (["triple", "equals"], "===", .spaced), (["double", "equals"], "==", .spaced),
        (["not", "equals"], "!=", .spaced), (["plus", "equals"], "+=", .spaced),
        (["minus", "equals"], "-=", .spaced), (["fat", "arrow"], "=>", .spaced),
        (["double", "pipe"], "||", .spaced), (["double", "ampersand"], "&&", .spaced),
        (["double", "colon"], "::", .both), (["open", "paren"], "(", .both), (["close", "paren"], ")", .left),
        (["open", "brace"], "{", .right), (["close", "brace"], "}", .left),
        (["open", "bracket"], "[", .both), (["close", "bracket"], "]", .left),
        (["open", "angle"], "<", .right), (["close", "angle"], ">", .left),
        (["at", "sign"], "@", .right), (["double", "quote"], "\"", .both), (["single", "quote"], "'", .both),
        (["question", "mark"], "?", .left), (["new", "line"], "\n", .line),
        (["arrow"], "->", .spaced), (["equals"], "=", .spaced), (["pipe"], "|", .spaced),
        (["ampersand"], "&", .spaced), (["slash"], "/", .both), (["backslash"], "\\", .both),
        (["colon"], ":", .left), (["semicolon"], ";", .left), (["comma"], ",", .left),
        (["hash"], "#", .right), (["dollar"], "$", .right), (["percent"], "%", .left),
        (["caret"], "^", .spaced), (["tilde"], "~", .right), (["underscore"], "_", .both),
        (["asterisk"], "*", .both), (["star"], "*", .both), (["backtick"], "`", .both),
        (["dash"], "-", .right), (["hyphen"], "-", .right), (["plus"], "+", .spaced), (["minus"], "-", .spaced),
        (["dot"], ".", .both), (["bang"], "!", .left), (["tab"], "\t", .line),
    ]

    /// Letter names the model tends to write for spoken letters.
    private static let letterNames: [String: String] = [
        "a": "a", "ay": "a", "b": "b", "bee": "b", "be": "b", "c": "c", "see": "c", "sea": "c", "d": "d", "dee": "d",
        "e": "e", "ee": "e", "f": "f", "ef": "f", "g": "g", "gee": "g", "h": "h", "aitch": "h", "i": "i", "eye": "i",
        "j": "j", "jay": "j", "k": "k", "kay": "k", "l": "l", "el": "l", "m": "m", "em": "m", "n": "n", "en": "n",
        "o": "o", "oh": "o", "p": "p", "pee": "p", "pea": "p", "q": "q", "queue": "q", "cue": "q", "r": "r", "are": "r",
        "s": "s", "ess": "s", "t": "t", "tee": "t", "tea": "t", "u": "u", "you": "u", "v": "v", "vee": "v",
        "w": "w", "x": "x", "ex": "x", "y": "y", "why": "y", "z": "z", "zed": "z", "zee": "z",
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7",
        "eight": "8", "nine": "9", "dash": "-", "underscore": "_", "dot": ".",
    ]

    /// "spell k u b e" → "kube"; "spell capital k u b e" → "Kube". Digits and
    /// dash, underscore and dot are spelled too, so "spell my dash app" works.
    private static func spell(_ tokens: [String], from start: Int) -> (String, Int)? {
        var j = start; var out = ""; var capitalNext = false
        while j < tokens.count {
            let t = tokens[j]; let w = bare(t).lowercased()
            if w == "end" { j += 1; break }
            if w == "capital" || w == "cap" { capitalNext = true; j += 1; continue }
            // "k-u-b-e" or "kube" written as one token of letters is accepted as-is.
            let piece: String?
            if let l = letterNames[w] { piece = l }
            else if w.count > 1, w.allSatisfy({ $0.isLetter || $0 == "-" }), w.contains("-") { piece = w.replacingOccurrences(of: "-", with: "") }
            else { piece = nil }
            guard let p = piece else { break }
            out += capitalNext ? p.uppercased() : p
            capitalNext = false
            j += 1
            if let last = t.last, ",.?!;:".contains(last) { break }
        }
        return out.isEmpty ? nil : (out, j)
    }

    private static let smallNumbers: [String: Int] = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let multipliers: [String: Int] = ["hundred": 100, "thousand": 1_000, "million": 1_000_000]

    /// "number one dot two dot three" → "1.2.3"; "number twenty five" → "25";
    /// "number two thousand and four" → "2004". A run of number words with
    /// dot/point between groups. Digits already written by the model pass through.
    private static func number(_ tokens: [String], from start: Int, digitsOnly: Bool = false) -> (String, Int)? {
        var j = start; var groups: [String] = []; var current: Int? = nil; var pending = 0
        func flush() { if let c = current { groups.append(String(c + pending)); current = nil; pending = 0 } else if pending > 0 { groups.append(String(pending)); pending = 0 } }
        var any = false
        while j < tokens.count {
            let t = tokens[j]; let w = bare(t).lowercased()
            if w == "end" { j += 1; break }
            if w == "and" && (current != nil || pending > 0) { j += 1; continue }
            if w == "dot" || w == "point" { flush(); groups.append("."); any = true; j += 1; continue }
            if digitsOnly, let n = smallNumbers[w], n < 10 { groups.append(String(n)); any = true }
            else if let n = smallNumbers[w] { pending += n; any = true }
            else if let m = multipliers[w] { let base = pending == 0 ? 1 : pending; if m >= 1000 { current = (current ?? 0) + base * m; pending = 0 } else { pending = base * m }; any = true }
            else if !w.isEmpty, w.allSatisfy({ $0.isNumber }) { flush(); groups.append(w); any = true }
            else { break }
            j += 1
            if let last = t.last, ",.?!;:".contains(last) { break }
        }
        flush()
        guard any else { return nil }
        // Joined without spaces: "1.2.3", "2004", "255".
        return (groups.joined(), j)
    }

    static func apply(_ text: String, profile: CleanupProfile) -> Result {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var out: [Piece] = []
        var i = 0
        var endsWithCode = false
        var sawCode = false

        while i < tokens.count {
            // Spell and number modes: "spell …", "number …" / "digits …".
            let head = bare(tokens[i]).lowercased()
            if head == "spell" || head == "number" || head == "digits", !tokens[i].hasSuffix(","), i + 1 < tokens.count {
                let run = head == "spell" ? spell(tokens, from: i + 1) : number(tokens, from: i + 1, digitsOnly: head == "digits")
                if let (word, next) = run {
                    let lastToken = tokens[next - 1]
                    sawCode = true
                    out.append(Piece(word, .spaced))
                    if let p = lastToken.last, ",.?!;:".contains(p), bare(lastToken).lowercased() != "end" {
                        out.append(Piece(String(p), .left)); endsWithCode = false
                    } else { endsWithCode = true }
                    i = next
                    continue
                }
            }

            // Identifier mode: "<mode> case …" / "slash path …".
            if i + 1 < tokens.count, let mode = Mode(rawValue: bare(tokens[i]).lowercased()),
               bare(tokens[i + 1]).lowercased() == mode.trigger, !tokens[i].hasSuffix(",") {
                var j = i + 2
                var words: [String] = []
                var trailing = ""
                while j < tokens.count {
                    let t = tokens[j]
                    let word = bare(t)
                    if word.lowercased() == "end" { j += 1; break }
                    if profile == .code, matchSymbol(tokens, at: j) != nil { break }
                    if !word.isEmpty { words.append(word) }
                    if let last = t.last, ",.?!;:".contains(last) {
                        trailing = String(last); j += 1; break
                    }
                    j += 1
                }
                if !words.isEmpty {
                    sawCode = true
                    out.append(Piece(mode.join(words), .spaced))
                    if !trailing.isEmpty { out.append(Piece(trailing, .left)) }
                    endsWithCode = trailing.isEmpty
                    i = j
                    continue
                }
            }

            // Symbol vocabulary, code profile only.
            if profile == .code, let (glyph, attach, length) = matchSymbol(tokens, at: i) {
                let lastToken = tokens[i + length - 1]
                sawCode = true
                out.append(Piece(glyph, attach))
                if let punct = lastToken.last, ",.?!".contains(punct), glyph != "." {
                    out.append(Piece(String(punct), .left))
                    endsWithCode = false
                } else {
                    endsWithCode = true
                }
                i += length
                continue
            }

            out.append(Piece(tokens[i], .spaced))
            endsWithCode = false
            i += 1
        }
        return Result(text: render(out), endsWithCode: endsWithCode || (profile == .code && sawCode))
    }

    private struct Piece {
        let text: String
        let attach: Attach
        init(_ t: String, _ a: Attach) { text = t; attach = a }
    }

    private static func matchSymbol(_ tokens: [String], at i: Int) -> (String, Attach, Int)? {
        for entry in symbols {
            let n = entry.phrase.count
            guard i + n <= tokens.count else { continue }
            var ok = true
            for k in 0..<n {
                let word = bare(tokens[i + k]).lowercased()
                // Interior words may not carry punctuation; the last one may.
                if word != entry.phrase[k] || (k < n - 1 && tokens[i + k].last.map { ",.?!".contains($0) } == true) { ok = false; break }
            }
            if ok { return (entry.glyph, entry.attach, n) }
        }
        return nil
    }

    private static func render(_ pieces: [Piece]) -> String {
        var s = ""
        var previous: Attach? = nil
        for p in pieces {
            let glueToPrevious: Bool
            switch (previous, p.attach) {
            case (nil, _): glueToPrevious = true
            case (.right?, _), (.both?, _), (.line?, _): glueToPrevious = true
            case (_, .left), (_, .both), (_, .line): glueToPrevious = true
            default: glueToPrevious = false
            }
            if !glueToPrevious && !s.isEmpty { s.append(" ") }
            s.append(p.text)
            previous = p.attach
        }
        return s
    }

    private static func bare(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet(charactersIn: ",.?!;:"))
    }
}
