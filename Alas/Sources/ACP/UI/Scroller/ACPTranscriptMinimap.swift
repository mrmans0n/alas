import AppKit

/// Conversation turns have their own scale, independent of text and tool output length.
struct ACPTranscriptMinimapLayout {
    enum Role {
        case user, assistant, notice, history
    }

    struct Block {
        let role: Role
        var messages: Range<Int>
        let y: CGFloat
        let height: CGFloat
    }

    private(set) var blocks: [Block] = []
    private(set) var height: CGFloat = 0

    init(messages: [ACPMessage], offset: Int) {
        if offset > 0 {
            append(role: .history, messages: 0..<offset)
        }
        for (index, message) in messages.enumerated() {
            let role: Role
            switch message {
            case .user: role = .user
            case .systemNotice: role = .notice
            case .agent, .thought, .toolCall, .fileEdit, .plan: role = .assistant
            }
            let globalIndex = offset + index
            if role != .user, let last = blocks.last, last.role == role {
                blocks[blocks.count - 1].messages = last.messages.lowerBound..<(globalIndex + 1)
            } else {
                append(role: role, messages: globalIndex..<(globalIndex + 1))
            }
        }
    }

    private mutating func append(role: Role, messages: Range<Int>) {
        let extent: CGFloat = role == .user || role == .notice ? 24 : 48
        blocks.append(Block(role: role, messages: messages, y: height, height: extent))
        height += extent
    }

    /// Convert a fractional global message index to a fraction of the turn map.
    func fraction(at messagePosition: CGFloat) -> CGFloat {
        guard height > 0, !blocks.isEmpty else { return 0 }
        let index = blockIndex { CGFloat($0.messages.upperBound) <= messagePosition }
        let block = blocks[index]
        let progress = min(1, max(0, (messagePosition - CGFloat(block.messages.lowerBound)) / CGFloat(block.messages.count)))
        return (block.y + progress * block.height) / height
    }

    func messagePosition(at fraction: CGFloat) -> CGFloat {
        guard height > 0, !blocks.isEmpty else { return 0 }
        let y = min(1, max(0, fraction)) * height
        let index = blockIndex { $0.y + $0.height <= y }
        let block = blocks[index]
        let progress = min(1, max(0, (y - block.y) / block.height))
        return CGFloat(block.messages.lowerBound) + progress * CGFloat(block.messages.count)
    }

    private func blockIndex(before position: (Block) -> Bool) -> Int {
        var low = 0
        var high = blocks.count
        while low < high {
            let middle = (low + high) / 2
            if position(blocks[middle]) { low = middle + 1 } else { high = middle }
        }
        return min(low, blocks.count - 1)
    }
}

@MainActor
final class ACPTranscriptMinimap {
    private var theme: Theme?
    private var generation: UInt64?
    private var offset: Int?
    private var transcriptID: ObjectIdentifier?
    private var cachedDrawing = MinimapDrawing()
    private(set) var layout = ACPTranscriptMinimapLayout(messages: [], offset: 0)

    func needsUpdate(transcript: ACPTranscript, theme: Theme) -> Bool {
        self.theme != theme || generation != transcript.messagesGeneration
            || offset != transcript.messageIndexOffset
            || transcriptID != ObjectIdentifier(transcript)
    }

    func drawing(transcript: ACPTranscript, theme: Theme) -> MinimapDrawing {
        guard needsUpdate(transcript: transcript, theme: theme) else { return cachedDrawing }
        transcriptID = ObjectIdentifier(transcript)
        self.theme = theme
        generation = transcript.messagesGeneration
        offset = transcript.messageIndexOffset
        layout = ACPTranscriptMinimapLayout(messages: transcript.messages, offset: transcript.messageIndexOffset)
        let userColor = NSColor(theme.color("accent")).withAlphaComponent(0.65)
        let assistantColor = NSColor(theme.color("fg-muted")).withAlphaComponent(0.38)
        let noticeColor = NSColor(theme.color("fg-faint")).withAlphaComponent(0.2)
        var drawing = MinimapDrawing(height: layout.height)
        for block in layout.blocks {
            let x: CGFloat
            let width: CGFloat
            let color: NSColor
            switch block.role {
            case .user:
                x = 24
                width = 64
                color = userColor
            case .assistant:
                x = 0
                width = 64
                color = assistantColor
            case .notice, .history:
                x = 0
                width = 88
                color = noticeColor
            }
            drawing.marks.append(.init(
                rect: CGRect(x: x, y: block.y + 2, width: width, height: block.height - 4),
                color: color
            ))
        }
        cachedDrawing = drawing
        return drawing
    }
}
