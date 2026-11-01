// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-06, AC-06.02, AC-06.05; US-33, AC-33.05.
import Foundation

/// Channel-neutral shaping of the text a completion notice carries: the request excerpt and the agent's
/// final reply. Each channel escapes the result for its own format; nothing here grants input authority.
public enum NoticeText {
    /// The closing line of a reply shortened to fit a channel.
    public static let truncationNotice = "… The rest is on your Mac."
    /// Bytes of a final reply an adapter keeps; a notice shows at most `SessionNotice.resultLimit` of them.
    public static let captureLimit = 36_864

    /// One line: whitespace collapsed, control and invisible formatting characters removed, and text over
    /// `limit` characters cut at a word boundary with an ellipsis. Empty text yields nil.
    public static func excerpt(_ text: String, limit: Int) -> String? {
        let words = visible(text).split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let line = words.joined(separator: " ")
        guard !line.isEmpty, limit > 1 else { return nil }
        guard line.count > limit else { return line }
        let characters = Array(line)
        var cut = limit - 1
        // Prefer the last word boundary near the limit; unspaced scripts are cut at the limit.
        if let space = characters[..<cut].lastIndex(of: " "), space >= cut - 30, space > 0 { cut = space }
        let kept = String(characters[..<cut]).trimmingCharacters(in: .whitespaces.union(.init(charactersIn: ",;:")))
        return kept + "…"
    }

    /// Agent Markdown with its line structure kept: line endings normalized, control and invisible
    /// formatting characters removed, trailing spaces and repeated blank lines collapsed. Outside code, a
    /// heading becomes a bold line and a link to a local file becomes its label in code, so the reply reads
    /// like a message rather than a document and never offers a link that cannot open on a phone.
    public static func cleanMarkdown(_ text: String) -> String {
        let normalized = visible(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var lines: [String] = [], fenced = false
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            var trimmed = line
            while trimmed.last?.isWhitespace == true { trimmed.removeLast() }
            if trimmed.isEmpty, lines.last?.isEmpty ?? true { continue }
            if isFence(trimmed) { fenced.toggle(); lines.append(String(trimmed)); continue }
            lines.append(fenced ? String(trimmed) : calm(String(trimmed)))
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static let heading = try! NSRegularExpression(pattern: #"^ {0,3}#{1,6}[ \t]+(.+?)(?:[ \t]+#+)?$"#)
    private static let localLink = try! NSRegularExpression(pattern: #"\[([^\]`\n]+)\]\((?![a-zA-Z][a-zA-Z0-9+.-]*://|mailto:)[^)\s]+\)"#)

    private static func calm(_ line: String) -> String {
        var value = line
        var range = NSRange(value.startIndex..., in: value)
        if heading.firstMatch(in: value, range: range) != nil {
            value = heading.stringByReplacingMatches(in: value, range: range, withTemplate: "**$1**")
            range = NSRange(value.startIndex..., in: value)
        }
        // Links inside inline code stay as written; elsewhere a local target keeps only its label.
        guard !value.contains("`") else { return value }
        return localLink.stringByReplacingMatches(in: value, range: range, withTemplate: "`$1`")
    }

    /// Hides secret-looking values and hidden reasoning, and shortens home folders to `~`.
    /// `hidSensitive` reports whether anything other than a home folder was hidden. A heuristic
    /// cannot recognize every secret; adapters still forward only final replies.
    public static func redact(_ text: String) -> (text: String, hidSensitive: Bool) {
        var value = text, hidden = false
        for (pattern, replacement) in sensitivePatterns {
            let range = NSRange(value.startIndex..., in: value)
            guard pattern.firstMatch(in: value, range: range) != nil else { continue }
            hidden = true
            value = pattern.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
        }
        let range = NSRange(value.startIndex..., in: value)
        value = homeFolder.stringByReplacingMatches(in: value, range: range, withTemplate: "~")
        return (value, hidden)
    }

    /// `text` itself when it fits; otherwise its longest word-boundary prefix that still fits once an open
    /// code fence is closed and the truncation notice is appended. `alreadyShortened` always appends the
    /// notice. Nil when not even the notice fits.
    public static func fitting(_ text: String, alreadyShortened: Bool = false, _ fits: (String) -> Bool) -> String? {
        if !alreadyShortened, fits(text) { return text }
        let characters = Array(text)
        let whole = shortened(characters[...], whole: true)
        if alreadyShortened, fits(whole) { return whole }
        guard fits(shortened(characters[..<0], whole: false)) else { return nil }
        var low = 0, high = characters.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if fits(shortened(characters[..<middle], whole: false)) { low = middle } else { high = middle - 1 }
        }
        return shortened(characters[..<low], whole: false)
    }

    /// At most `limit` UTF-8 bytes, cut on a character boundary.
    public static func prefix(_ text: String, utf8Limit limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var count = 0, end = text.startIndex
        for index in text.indices {
            let size = text[index].utf8.count
            guard count + size <= limit else { break }
            count += size; end = text.index(after: index)
        }
        return String(text[..<end])
    }

    /// Whether the line opens or closes a fenced code block.
    public static func isFence(_ line: Substring) -> Bool {
        let trimmed = line.drop(while: { $0 == " " })
        return line.count - trimmed.count <= 3 && (trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~"))
    }

    private static func shortened(_ characters: ArraySlice<Character>, whole: Bool) -> String {
        var cut = characters.endIndex
        if !whole, let space = characters.lastIndex(where: { $0 == " " || $0 == "\n" }),
           space >= characters.endIndex - 40, space > characters.startIndex { cut = space }
        var body = String(characters[..<cut])
        while body.last?.isWhitespace == true { body.removeLast() }
        if body.split(separator: "\n", omittingEmptySubsequences: false).filter(isFence).count % 2 == 1 { body += "\n```" }
        return body.isEmpty ? truncationNotice : body + "\n\n" + truncationNotice
    }

    /// Removes control characters other than line feeds, turns tabs into spaces, and drops invisible
    /// characters that can reorder or hide text; joiners used by emoji are kept.
    private static func visible(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A: scalars.append(scalar)
            case 0x09: scalars.append(contentsOf: "    ".unicodeScalars)
            case 0x00...0x1F, 0x7F...0x9F, 0x200B, 0x200E, 0x200F, 0x202A...0x202E, 0x2060, 0x2066...0x2069, 0xFEFF: continue
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    private static let homeFolder = try! NSRegularExpression(pattern: #"/(?:Users|home)/[^/\s`'"),;]+"#)
    private static let sensitivePatterns: [(NSRegularExpression, String)] = [
        (#"(?is)<(think|thinking|analysis)\b[^>]*>.*?(?:</\1\s*>|\z)"#, ""),
        (#"(?s)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\z)"#, "[private key hidden]"),
        (#"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{12,}"#, "$1 [hidden]"),
        (#"\b(?:sk|rk|pk)-[A-Za-z0-9_-]{16,}"#, "[hidden]"),
        (#"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{16,})"#, "[hidden]"),
        (#"\bx(?:ox[abposre]|app)-[A-Za-z0-9-]{10,}"#, "[hidden]"),
        (#"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#, "[hidden]"),
        (#"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{8,}"#, "[hidden]"),
        (#"\b[0-9]{6,12}:[A-Za-z0-9_-]{30,}\b"#, "[hidden]"),
        (#"(://)[^/\s:@]+:[^/\s@]+@"#, "$1[hidden]@"),
        (#"(?i)\b((?:password|passwd|secret|client[_-]?secret|app[_-]?secret|token|access[_-]?token|refresh[_-]?token|api[_-]?key|private[_-]?key)["']?\s*[:=]\s*["']?)[^\s"'`,;]{4,}"#,
         "$1[hidden]"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
}
