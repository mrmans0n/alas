import AppKit

@MainActor
final class ACPTranscriptMinimap {
    private struct Entry {
        let message: ACPMessage
        let revision: UInt64
        let drawing: MinimapDrawing
    }
    private var entries: [ACPMessage.StableIdentityKey: Entry] = [:]
    private var theme: Theme?
    private var generation: UInt64?
    private var tick: UInt32?
    private var offset: Int?
    private var transcriptID: ObjectIdentifier?
    private var cachedDrawing = MinimapDrawing()

    func needsUpdate(transcript: ACPTranscript, theme: Theme) -> Bool {
        self.theme != theme || generation != transcript.messagesGeneration
            || tick != transcript.streamingTick || offset != transcript.messageIndexOffset
            || transcriptID != ObjectIdentifier(transcript)
    }

    func drawing(transcript: ACPTranscript, theme: Theme) -> MinimapDrawing {
        guard needsUpdate(transcript: transcript, theme: theme) else { return cachedDrawing }
        if self.theme != theme || transcriptID != ObjectIdentifier(transcript) { entries.removeAll() }
        transcriptID = ObjectIdentifier(transcript)
        self.theme = theme
        generation = transcript.messagesGeneration
        tick = transcript.streamingTick
        offset = transcript.messageIndexOffset
        let count = transcript.logicalMessageCount
        let slot: CGFloat = max(24, 360 / CGFloat(max(1, count)))
        var result = MinimapDrawing(height: CGFloat(max(1, count)) * slot)
        if transcript.messageIndexOffset > 0 {
            result.marks.append(.init(
                rect: CGRect(x: 0, y: 0, width: 88, height: CGFloat(transcript.messageIndexOffset) * slot),
                color: NSColor(theme.color("fg-faint")).withAlphaComponent(0.12)
            ))
        }
        // Bound preview generation independently of history length. Each sample
        // keeps its global position; a hidden render window never changes the map.
        var sampleStride = 1
        while count / sampleStride > 382 { sampleStride *= 2 }
        let firstGlobal = ((transcript.messageIndexOffset + sampleStride - 1) / sampleStride) * sampleStride
        var indices = Set(stride(from: firstGlobal - transcript.messageIndexOffset, to: transcript.messages.count, by: sampleStride))
        if !transcript.messages.isEmpty {
            indices.insert(0)
            indices.insert(transcript.messages.count - 1)
        }
        let promptColor = NSColor(theme.color("accent")).withAlphaComponent(0.26)
        let cardColor = NSColor(theme.color("bg-2"))
        let textColor = NSColor(theme.color("fg-faint")).withAlphaComponent(0.6)
        for start in stride(from: 0, to: transcript.messages.count, by: sampleStride) {
            let end = min(transcript.messages.count, start + sampleStride)
            let messages = transcript.messages[start..<end]
            guard let message = messages.first(where: {
                if case .user = $0 { return true }
                return false
            }) ?? messages.first(where: {
                if case .toolCall = $0 { return true }
                if case .fileEdit = $0 { return true }
                return false
            }) ?? messages.first(where: {
                if case .plan = $0 { return false }
                return true
            }) else { continue }
            let y = CGFloat(transcript.messageIndexOffset + start) * slot
            let height = CGFloat(end - start) * slot
            let rect: CGRect
            let color: NSColor
            switch message {
            case .user:
                rect = CGRect(x: 24, y: y, width: 64, height: max(2, height))
                color = promptColor.withAlphaComponent(promptColor.alphaComponent * 0.45)
            case .toolCall, .fileEdit:
                rect = CGRect(x: 0, y: y, width: 88, height: max(2, min(8, height)))
                color = cardColor
            case .plan:
                continue
            default:
                rect = CGRect(x: 0, y: y, width: 60, height: max(1, min(2, height)))
                color = textColor
            }
            result.marks.append(.init(rect: rect, color: color))
        }
        var retained: [ACPMessage.StableIdentityKey: Entry] = [:]
        for index in indices.sorted() {
            let message = transcript.messages[index]
            let revision: UInt64
            switch message {
            case .agent(_, _, let text), .thought(_, _, let text): revision = text.revision
            default: revision = 0
            }
            let key = message.stableIdentityKey
            let entry: Entry
            if let cached = entries[key], cached.message == message, cached.revision == revision {
                entry = cached
            } else {
                entry = Entry(message: message, revision: revision, drawing: Self.preview(message, theme: theme))
            }
            retained[key] = entry
            let y = CGFloat(transcript.messageIndexOffset + index) * slot
            let scale = min(1, (slot - 4) / max(1, entry.drawing.height))
            result.marks.append(contentsOf: entry.drawing.marks.map {
                .init(rect: CGRect(x: $0.rect.minX, y: y + $0.rect.minY * scale,
                                   width: $0.rect.width, height: $0.rect.height * scale), color: $0.color)
            })
        }
        entries = retained
        cachedDrawing = result
        return result
    }

    static func preview(_ message: ACPMessage, theme: Theme) -> MinimapDrawing {
        let fg = NSColor(theme.color("fg"))
        let muted = NSColor(theme.color("fg-faint"))
        let accent = NSColor(theme.color("accent"))
        var drawing: MinimapDrawing
        switch message {
        case .user(_, _, let text, let attachments, _):
            drawing = markdown(text, theme: theme, columns: 60)
            var bubble = MinimapDrawing(height: drawing.height + 6)
            bubble.marks.append(.init(rect: CGRect(x: 24, y: 0, width: 64, height: bubble.height),
                                      color: accent.withAlphaComponent(0.26)))
            bubble.append(drawing, x: 26, y: 3)
            for index in attachments.prefix(4).indices {
                bubble.marks.append(.init(rect: CGRect(x: 26 + index * 10, y: 0, width: 8, height: 4), color: accent))
            }
            return bubble
        case .agent(_, _, let text):
            return markdown(text.value, theme: theme, columns: 84)
        case .thought(_, _, let text):
            drawing = MinimapDrawing.text(NSAttributedString(string: String(text.value.prefix(1024)), attributes: [.foregroundColor: muted]), columns: 80, wraps: true)
            drawing.marks.insert(.init(rect: CGRect(x: 0, y: 0, width: 1, height: drawing.height), color: NSColor(theme.color("bg-4"))), at: 0)
        case .toolCall(let tool):
            drawing = MinimapDrawing.text(NSAttributedString(string: String(tool.title.prefix(80)), attributes: [.foregroundColor: fg]), columns: 76)
            var card = MinimapDrawing(height: 8)
            card.marks.append(.init(rect: CGRect(x: 0, y: 0, width: 88, height: 8), color: NSColor(theme.color("bg-2"))))
            let status = tool.status == "failed" ? "del" : tool.status == "completed" ? "add" : "accent"
            card.marks.append(.init(rect: CGRect(x: 2, y: 2, width: 3, height: 3), color: NSColor(theme.color(status))))
            card.append(drawing, x: 8, y: 2)
            return card
        case .fileEdit(_, let edit):
            drawing = MinimapDrawing.text(NSAttributedString(string: String(edit.path.prefix(80)), attributes: [.foregroundColor: accent]))
            drawing.marks.append(.init(rect: CGRect(x: 0, y: 4, width: CGFloat(min(40, edit.added)), height: 2), color: NSColor(theme.color("add"))))
            drawing.marks.append(.init(rect: CGRect(x: 44, y: 4, width: CGFloat(min(40, edit.removed)), height: 2), color: NSColor(theme.color("del"))))
            drawing.height = 8
        case .systemNotice(_, let text):
            drawing = MinimapDrawing.text(NSAttributedString(string: String(text.prefix(160)), attributes: [.foregroundColor: muted]), wraps: true)
        case .plan:
            drawing = MinimapDrawing(height: 3)
        }
        return drawing
    }

    private static func markdown(_ text: String, theme: Theme, columns: Int) -> MinimapDrawing {
        var result = MinimapDrawing()
        for block in ACPMarkdownText.parse(String(text.prefix(4096))) {
            let attributed: NSAttributedString
            var background: NSColor?
            switch block {
            case .code(let language, let body), .streamingCode(let language, let body):
                attributed = ACPCodeBlockHighlighter.attributedString(code: String(body.prefix(2048)), language: language, theme: theme)
                background = NSColor(theme.color("bg-2"))
            case .heading(let level, let text):
                attributed = ACPMarkdownInlineRenderer.makeAttributedString(source: text, theme: theme, typography: .default, role: .heading(level: level))
            case .paragraph(let text):
                attributed = ACPMarkdownInlineRenderer.makeAttributedString(source: text, theme: theme, typography: .default, role: .body)
            case .quote(let text):
                attributed = ACPMarkdownInlineRenderer.makeAttributedString(source: text, theme: theme, typography: .default, role: .quote)
            case .taskList(let items):
                attributed = NSAttributedString(string: items.map { $0.text }.joined(separator: "\n"), attributes: [.foregroundColor: NSColor(theme.color("fg"))])
            case .table(let header, let rows):
                attributed = NSAttributedString(string: ([header] + rows).map { $0.joined(separator: "  ") }.joined(separator: "\n"), attributes: [.foregroundColor: NSColor(theme.color("fg"))])
            case .mermaid(let source):
                attributed = NSAttributedString(string: String(source.prefix(1024)), attributes: [.foregroundColor: NSColor(theme.color("accent"))])
            }
            let drawing = MinimapDrawing.text(attributed, columns: columns, wraps: background == nil)
            let y = result.height
            if let background {
                result.marks.append(.init(rect: CGRect(x: 0, y: y, width: CGFloat(columns), height: drawing.height), color: background))
            }
            result.append(drawing, y: y)
            result.height += 3
        }
        return result
    }
}
