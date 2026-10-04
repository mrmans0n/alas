import Foundation

/// Text-only views of a session transcript for `session_read`,
/// `session_search`, and `session_wait`. Pure: no I/O, no session access.
///
/// A transcript becomes a flat list of entries: user and agent messages
/// verbatim, tool calls and file edits as one-line summaries, system notices
/// as text. Thoughts and plans are internal state and are left out. Entry
/// indices only grow as a session runs, so a caller can page with them.
///
/// Reading an agent message's text touches `StreamingText.value`, which is
/// `@MainActor`-isolated.
enum ACPSessionTranscriptReader {
    struct Entry: Codable, Equatable, Sendable {
        let index: Int
        let role: String
        let text: String
        /// True when `text` was cut to fit the character budget; omitted
        /// from the wire otherwise.
        var truncated: Bool? = nil
    }

    struct Page: Equatable, Sendable {
        let entries: [Entry]
        /// Index of the first returned entry, or the requested offset when
        /// nothing was returned.
        let start: Int
        /// One past the last returned entry; pass it as `offset` to continue.
        let end: Int
        let total: Int
    }

    struct Match: Equatable, Sendable {
        let index: Int
        let role: String
        let snippet: String
    }

    static let snippetRadius = 80

    @MainActor
    static func entries(_ messages: [ACPMessage]) -> [Entry] {
        var entries: [Entry] = []
        // Text stays verbatim (an indented code block keeps its indent);
        // trimming only drops entries with nothing to read.
        func append(_ role: String, _ text: String) {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            entries.append(Entry(index: entries.count, role: role, text: text))
        }
        for message in messages {
            switch message {
            case .user(_, _, let text, _, _):
                append("user", text)
            case .agent(_, _, let buffer):
                append("agent", buffer.value)
            case .toolCall(let call):
                append("tool", "\(call.nonEmptyName ?? call.title) [\(call.status)]")
            case .fileEdit(_, let edit):
                append("tool", "Edited \(edit.path) (+\(edit.added) -\(edit.removed))")
            case .systemNotice(_, let text):
                append("system", text)
            case .thought, .plan:
                continue
            }
        }
        return entries
    }

    /// Entries from `offset` forward, or the latest ones when `offset` is
    /// nil, up to `limit` entries and `maxChars` characters of text. The
    /// first entry always fits: one longer than the budget is cut (keeping
    /// its head when reading forward, its tail when reading the latest).
    ///
    /// `lastEntryIsLive` is set while the session runs: its last entry (a
    /// streaming message, or a tool call still in progress) changes in
    /// place, so `end` stops on it and the next page reads it again.
    static func page(
        _ entries: [Entry], offset: Int?, limit: Int, maxChars: Int, lastEntryIsLive: Bool = false
    ) -> Page {
        let total = entries.count
        var budget = maxChars
        var picked: [Entry] = []

        func take(_ entry: Entry, keepTail: Bool) -> Bool {
            guard picked.count < limit else { return false }
            if entry.text.count <= budget {
                budget -= entry.text.count
                picked.append(entry)
                return true
            }
            guard picked.isEmpty else { return false }
            let cut = keepTail ? String(entry.text.suffix(budget)) : String(entry.text.prefix(budget))
            picked.append(Entry(index: entry.index, role: entry.role, text: cut, truncated: true))
            budget = 0
            return true
        }

        func resumePoint(_ end: Int) -> Int {
            lastEntryIsLive && end == total && picked.last?.index == total - 1 ? total - 1 : end
        }

        if let offset {
            let start = min(max(offset, 0), total)
            for entry in entries[start...] {
                guard take(entry, keepTail: false) else { break }
            }
            return Page(entries: picked, start: start, end: resumePoint(start + picked.count), total: total)
        }
        for entry in entries.reversed() {
            guard take(entry, keepTail: true) else { break }
        }
        picked.reverse()
        return Page(entries: picked, start: picked.first?.index ?? total, end: resumePoint(total), total: total)
    }

    /// Case-insensitive substring matches, one per entry, in transcript
    /// order, each with a snippet centered on the first occurrence.
    static func search(_ entries: [Entry], query: String) -> [Match] {
        entries.compactMap { entry in
            guard let range = entry.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
                return nil
            }
            return Match(index: entry.index, role: entry.role, snippet: snippet(entry.text, around: range))
        }
    }

    /// Tail of the latest agent message, capped like a turn completion's.
    @MainActor
    static func lastAgentText(_ messages: [ACPMessage]) -> String? {
        for message in messages.reversed() {
            guard case .agent(_, _, let buffer) = message else { continue }
            let text = buffer.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            return String(text.suffix(ACPTurnCompletion.lastAgentTextLimit))
        }
        return nil
    }

    private static func snippet(_ text: String, around range: Range<String.Index>) -> String {
        let lower = text.index(range.lowerBound, offsetBy: -snippetRadius, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: snippetRadius, limitedBy: text.endIndex) ?? text.endIndex
        let body = text[lower..<upper].replacingOccurrences(of: "\n", with: " ")
        return (lower > text.startIndex ? "…" : "") + body + (upper < text.endIndex ? "…" : "")
    }
}
