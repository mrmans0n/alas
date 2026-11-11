import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasACP

/// Text-only views of a session transcript for `session_read`,
/// `session_search`, and `session_wait`. Pure: no I/O, no session access.
///
/// A transcript becomes a flat list of entries: user and agent messages
/// verbatim, tool calls and file edits as one-line summaries, system notices
/// and failure incidents as text. A Markdown or file plan is agent output (Codex sends its plan
/// only that way once plans are negotiated), so it reads as an agent entry;
/// thoughts and checklists are internal state and are left out. Entry
/// indices only grow as a session runs, so a caller can page with them.
///
/// Reading an agent message's text touches `StreamingText.value`, which is
/// `@MainActor`-isolated.
public enum ACPSessionTranscriptReader: Sendable {
    public typealias Entry = ACPTranscriptEntry

    public struct Page: Equatable, Sendable {
        public let entries: [Entry]
        /// Index of the first returned entry, or the requested offset when
        /// nothing was returned.
        public let start: Int
        /// One past the last returned entry; pass it as `offset` to continue.
        public let end: Int
        public let total: Int

        public init(entries: [Entry], start: Int, end: Int, total: Int) {
            self.entries = entries
            self.start = start
            self.end = end
            self.total = total
        }
    }

    public struct Match: Equatable, Sendable {
        public let index: Int
        public let role: String
        public let snippet: String

        public init(index: Int, role: String, snippet: String) {
            self.index = index
            self.role = role
            self.snippet = snippet
        }
    }

    public static let snippetRadius = 80

    @MainActor
    public static func entries(_ messages: [ACPMessage]) -> [Entry] {
        var entries: [Entry] = []
        // Text stays verbatim (an indented code block keeps its indent);
        // trimming only drops entries with nothing to read.
        func append(_ role: String, _ text: String) {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            entries.append(Entry(index: entries.count, role: role, text: text))
        }
        for message in messages {
            switch message {
            case .user(_, _, let text, _, _, _):
                append("user", text)
            case .agent(_, _, let buffer):
                append("agent", buffer.value)
            case .toolCall(let call):
                append("tool", "\(call.nonEmptyName ?? call.title) [\(call.status)]")
            case .fileEdit(_, let edit):
                append("tool", "Edited \(edit.path) (+\(edit.added) -\(edit.removed))")
            case .systemNotice(_, let text):
                append("system", text)
            case .questionAnswer(let answer):
                append("system", answer.displayText)
            case .outcomeCard(let card):
                append("system", card.text)
            case .visualAid(let visual):
                append("tool", visual.transcriptSummary)
            case .planDocument(_, let document):
                // A removed plan keeps its slot, so paged reads that
                // started before the removal don't skip the next entry.
                append(document.hidden ? "system" : "agent", planText(document) ?? "Plan removed.")
            case .failureIncident(_, let incident):
                // A new revision rewrites this row in place, so offsets hold.
                append("system", incident.displayText)
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
    public static func page(
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
    public static func search(_ entries: [Entry], query: String) -> [Match] {
        entries.compactMap { entry in
            guard let range = entry.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
                return nil
            }
            return Match(index: entry.index, role: entry.role, snippet: snippet(entry.text, around: range))
        }
    }

    /// Tail of the latest agent message, or of a plan with no agent text
    /// after it, capped like a turn completion's.
    @MainActor
    public static func lastAgentText(_ messages: [ACPMessage]) -> String? {
        for message in messages.reversed() {
            guard let text = agentText(message)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { continue }
            return String(text.suffix(ACPTurnCompletion.lastAgentTextLimit))
        }
        return nil
    }

    /// The title of the latest row after the last user row that reports a
    /// turn failure: a stored transcript's record that its last turn failed.
    /// A background error never set `endedTurn`, so it does not count, and a
    /// later turn that the agent took clears it.
    public static func trailingTurnFailure(_ messages: [ACPMessage]) -> String? {
        for message in messages.reversed() {
            switch message {
            case .user:
                return nil
            case .failureIncident(_, let incident) where incident.reportsTurnFailure:
                return incident.record.title
            default:
                continue
            }
        }
        return nil
    }

    /// The text an agent message or a shown plan contributes as agent
    /// output, untrimmed; nil for any other message.
    @MainActor
    public static func agentText(_ message: ACPMessage) -> String? {
        switch message {
        case .agent(_, _, let buffer): buffer.value
        case .planDocument(_, let document): planText(document)
        default: nil
        }
    }

    /// A plan's Markdown, or "Plan file: <path>" for a file plan; nil once
    /// `plan_removed` hid it, or with neither.
    static func planText(_ document: ACPPlanDocument) -> String? {
        guard !document.hidden else { return nil }
        switch document.kind {
        case .markdown: return document.markdown
        case .file: return document.file.map { "Plan file: \($0.path)" }
        }
    }

    private static func snippet(_ text: String, around range: Range<String.Index>) -> String {
        let lower = text.index(range.lowerBound, offsetBy: -snippetRadius, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: snippetRadius, limitedBy: text.endIndex) ?? text.endIndex
        let body = text[lower..<upper].replacingOccurrences(of: "\n", with: " ")
        return (lower > text.startIndex ? "…" : "") + body + (upper < text.endIndex ? "…" : "")
    }
}
