import Foundation

/// How the cleaned text is going to be used. Prose is the default everywhere;
/// code turns on the symbol vocabulary, which would otherwise eat real words
/// like "pipe" and "dash" out of a sentence. Identifier modes ("camel case…")
/// are explicit enough to be on in both.
enum CleanupProfile: String {
    case prose, code
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

    static func apply(_ text: String, profile: CleanupProfile) -> Result {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var out: [Piece] = []
        var i = 0
        var endsWithCode = false
        var sawCode = false

        while i < tokens.count {
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
