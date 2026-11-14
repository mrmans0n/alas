import Foundation

/// Text rules for the remote composer: `@` mentions and `/` commands.
public enum RemoteComposerText {
    /// The `@` token the caret is in: an `@` at the start or after
    /// whitespace, then no whitespace up to the caret. Paths and
    /// `File.swift#name` drill-downs are single tokens.
    public static func activeMentionToken(in text: NSString, caret: Int) -> (start: Int, query: String)? {
        guard caret <= text.length else { return nil }
        var index = caret
        while index > 0 {
            let unit = text.character(at: index - 1)
            if unit == 0x40 {
                guard index == 1 || isSpace(text.character(at: index - 2)) else { return nil }
                return (index - 1, text.substring(with: NSRange(location: index, length: caret - index)))
            }
            if isSpace(unit) { return nil }
            index -= 1
        }
        return nil
    }

    /// The `/word` the caret is typing: the slash starts the text or follows
    /// whitespace, and only command characters sit between it and the caret.
    public static func slashToken(in text: NSString, caret: Int) -> (start: Int, query: String)? {
        guard caret >= 0, caret <= text.length else { return nil }
        var index = caret
        while index > 0 {
            let unit = text.character(at: index - 1)
            if unit == 0x2F {
                guard index == 1 || isSpace(text.character(at: index - 2)) else { return nil }
                return (index - 1, text.substring(with: NSRange(location: index, length: caret - index)))
            }
            guard isCommandCharacter(unit) else { return nil }
            index -= 1
        }
        return nil
    }

    /// Exact > prefix > contains > subsequence, shorter names first; an empty
    /// query keeps the host's order. Duplicates keep their first occurrence.
    public static func filterSlashCommands(_ commands: [RemoteSlashCommand], query: String) -> [RemoteSlashCommand] {
        var seen = Set<String>()
        let unique = commands.filter { seen.insert($0.command).inserted }
        let q = query.lowercased()
        guard !q.isEmpty else { return unique }
        func isSubsequence(_ name: String) -> Bool {
            var rest = q[...]
            for ch in name where ch == rest.first { rest = rest.dropFirst() }
            return rest.isEmpty
        }
        var scored: [(offset: Int, command: RemoteSlashCommand, score: Int)] = []
        for (offset, command) in unique.enumerated() {
            let name = (command.command.hasPrefix("/") ? String(command.command.dropFirst()) : command.command)
                .lowercased()
            let score: Int? = if name == q { 1000 }
            else if name.hasPrefix(q) { 900 - name.count }
            else if name.contains(q) { 600 - name.count }
            else if isSubsequence(name) { 300 - name.count }
            else { nil }
            if let score { scored.append((offset, command, score)) }
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }.map(\.command)
    }

    /// The picked mentions whose `@name` is still in `text` as a whole
    /// token. Each marker counts for one mention: longer names claim theirs
    /// first, so `@App.` stays `App.` rather than also keeping `App`, and
    /// mentions sharing a name take markers in pick order.
    public static func liveMentions(_ mentions: [RemoteMention], in text: String) -> [RemoteMention] {
        let text = text as NSString
        let claimOrder = mentions.indices.sorted {
            let (a, b) = ((mentions[$0].name as NSString).length, (mentions[$1].name as NSString).length)
            return a != b ? a > b : $0 < $1
        }
        var claimed: [NSRange] = []
        var live = Set<Int>()
        for index in claimOrder {
            let free = markerRanges(mentions[index].name, in: text).first { range in
                !claimed.contains { NSIntersectionRange($0, range).length > 0 }
            }
            if let free {
                claimed.append(free)
                live.insert(index)
            }
        }
        return mentions.indices.filter(live.contains).map { mentions[$0] }
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0x0D
    }

    /// `[A-Za-z0-9_:$-]`
    private static func isCommandCharacter(_ unit: unichar) -> Bool {
        switch unit {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F, 0x3A, 0x24, 0x2D: true
        default: false
        }
    }

    /// `@name` occurrences that start a token and end it, allowing trailing
    /// punctuation before whitespace or the end: `@App.swift.` matches
    /// `App.swift`, while `@App` matches neither `@Apple` nor `@App.swift`.
    private static func markerRanges(_ name: String, in text: NSString) -> [NSRange] {
        let marker = "@" + name
        let punctuation = CharacterSet(charactersIn: ".,;:!?)]}\"'")
        func scalar(at index: Int) -> UnicodeScalar { UnicodeScalar(text.character(at: index)) ?? "a" }
        func endsToken(at start: Int) -> Bool {
            var index = start
            while index < text.length, punctuation.contains(scalar(at: index)) { index += 1 }
            return index == text.length || CharacterSet.whitespacesAndNewlines.contains(scalar(at: index))
        }
        var ranges: [NSRange] = []
        var search = NSRange(location: 0, length: text.length)
        while true {
            let found = text.range(of: marker, options: [], range: search)
            guard found.location != NSNotFound else { return ranges }
            let end = NSMaxRange(found)
            let starts = found.location == 0
                || CharacterSet.whitespacesAndNewlines.contains(scalar(at: found.location - 1))
            if starts && endsToken(at: end) { ranges.append(found) }
            search = NSRange(location: end, length: text.length - end)
        }
    }
}

public struct RemoteQueueMoveTargets: Equatable, Sendable {
    public var up: String?
    public var down: String?

    public init(up: String? = nil, down: String? = nil) {
        self.up = up
        self.down = down
    }
}

/// Rules for the remote prompt queue, shared by the Mac peer view and the phone.
public enum RemoteQueueRules {
    /// The wire carries attachments only as counts. Without a marker an
    /// image-only or resource-only item would render as "(empty prompt)".
    public static func displayText(for item: RemoteQueuedPrompt) -> String {
        var markers: [String] = []
        if item.imageCount > 0 { markers.append("🖼 ×\(item.imageCount)") }
        if item.resourceCount > 0 { markers.append("📎 ×\(item.resourceCount)") }
        guard !markers.isEmpty else { return item.text }
        let summary = markers.joined(separator: " ")
        return item.text.isEmpty ? summary : item.text + "\n" + summary
    }

    /// The host refuses to edit an item holding images or mentions, so the
    /// row hides Edit for them, as the web queue does.
    public static func canEdit(_ item: RemoteQueuedPrompt) -> Bool {
        item.canRemove != false && item.imageCount == 0 && item.resourceCount == 0
    }

    /// Clear only helps when it can remove something: host-protected entries
    /// (`canRemove == false`) survive it.
    public static func canClear(_ items: [RemoteQueuedPrompt]) -> Bool {
        items.contains { $0.canRemove != false }
    }

    /// Items still waiting; the in-flight head is `"sending"`.
    public static func waiting(_ items: [RemoteQueuedPrompt]) -> [RemoteQueuedPrompt] {
        items.filter { $0.status != "sending" }
    }

    /// The neighbour each row's Move up / Move down swaps with, keyed by item
    /// id: a move never passes the in-flight head, and scheduled items
    /// neither move nor get passed. The host re-checks against its full queue.
    public static func moveTargets(_ items: [RemoteQueuedPrompt]) -> [String: RemoteQueueMoveTargets] {
        let firstScheduled = items.firstIndex { $0.status == "pending" && $0.scheduledAt != nil }
        func canMove(_ src: Int, _ dst: Int) -> Bool {
            if src == dst || dst < 0 || dst > items.count { return false }
            if items[src].status == "sending" { return false }
            if items.first?.status == "sending", dst == 0 { return false }
            if src == items.count - 1, dst == items.count { return false }
            if let firstScheduled, items[src].scheduledAt != nil || dst >= firstScheduled { return false }
            return true
        }
        func neighbour(_ index: Int, _ step: Int) -> Int? {
            var candidate = index + step
            while items.indices.contains(candidate) {
                if items[candidate].status != "sending" { return candidate }
                candidate += step
            }
            return nil
        }
        var targets: [String: RemoteQueueMoveTargets] = [:]
        for (index, item) in items.enumerated() where item.status != "sending" {
            let up = neighbour(index, -1).flatMap { canMove(index, $0) ? items[$0].id : nil }
            let down = neighbour(index, 1).flatMap { canMove(index, $0) ? items[$0].id : nil }
            targets[item.id] = RemoteQueueMoveTargets(up: up, down: down)
        }
        return targets
    }
}

/// Caps the host enforces on one prompt, so clients refuse before sending.
public enum RemoteAttachmentLimits {
    public static let maxCount = 10
    public static let maxTotalBytes = 10_000_000
    /// Caps the mentions one prompt resolves, as the image cap does.
    public static let maxMentionCount = 50
    public static let maxMentionQueryLength = 256

    /// Why a file of `size` bytes can't join the staged attachments, judged
    /// from sizes alone so it can be checked before the file is read.
    public static func refusal(adding size: Int, to stagedSizes: [Int]) -> String? {
        guard stagedSizes.count < maxCount else { return "Attachments are limited to \(maxCount) per prompt." }
        guard stagedSizes.reduce(size, +) <= maxTotalBytes else { return "Attachments are limited to 10 MB per prompt." }
        return nil
    }
}
