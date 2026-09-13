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
        var height: CGFloat
        var bandCount: Int
    }

    private(set) var blocks: [Block] = []
    private(set) var height: CGFloat = 0

    @MainActor
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
                let count = min(4, last.bandCount + bandCount(for: message))
                blocks[blocks.count - 1].messages = last.messages.lowerBound..<(globalIndex + 1)
                blocks[blocks.count - 1].bandCount = count
                let newHeight = extent(for: role, bandCount: count)
                height += newHeight - last.height
                blocks[blocks.count - 1].height = newHeight
            } else {
                append(role: role, messages: globalIndex..<(globalIndex + 1), bandCount: bandCount(for: message))
            }
        }
    }

    private mutating func append(role: Role, messages: Range<Int>, bandCount: Int = 0) {
        let blockHeight = extent(for: role, bandCount: bandCount)
        blocks.append(Block(role: role, messages: messages, y: height, height: blockHeight, bandCount: bandCount))
        height += blockHeight
    }

    @MainActor
    private func bandCount(for message: ACPMessage) -> Int {
        switch message {
        case .agent(_, _, let text):
            switch text.utf8Length {
            case 0..<320: return 1
            case 320..<1_600: return 2
            case 1_600..<6_400: return 3
            default: return 4
            }
        case .thought, .toolCall, .fileEdit, .plan:
            return 1
        case .user, .systemNotice:
            return 0
        }
    }

    private func extent(for role: Role, bandCount: Int) -> CGFloat {
        switch role {
        case .assistant:
            return CGFloat(max(1, bandCount) * 5 - 2)
        case .user, .notice, .history:
            return 10
        }
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
    private var streamingState: ACPSession.StreamingState?
    private var offset: Int?
    private var transcriptID: ObjectIdentifier?
    private var cachedDrawing = MinimapDrawing()
    private(set) var layout = ACPTranscriptMinimapLayout(messages: [], offset: 0)

    func needsUpdate(transcript: ACPTranscript, theme: Theme) -> Bool {
        self.theme != theme || generation != transcript.messagesGeneration
            || streamingState != transcript.streamingState
            || offset != transcript.messageIndexOffset
            || transcriptID != ObjectIdentifier(transcript)
    }

    func drawing(transcript: ACPTranscript, theme: Theme) -> MinimapDrawing {
        guard needsUpdate(transcript: transcript, theme: theme) else { return cachedDrawing }
        transcriptID = ObjectIdentifier(transcript)
        self.theme = theme
        generation = transcript.messagesGeneration
        streamingState = transcript.streamingState
        offset = transcript.messageIndexOffset
        layout = ACPTranscriptMinimapLayout(messages: transcript.messages, offset: transcript.messageIndexOffset)
        let userColor = NSColor(theme.color("accent")).withAlphaComponent(0.65)
        let assistantColor = NSColor(theme.color("fg-muted")).withAlphaComponent(0.38)
        let noticeColor = NSColor(theme.color("fg-faint")).withAlphaComponent(0.2)
        var drawing = MinimapDrawing(height: layout.height)
        // Dense histories share drawing buckets while navigation retains every turn.
        let bucketSize = max(1, Int(ceil(Double(layout.blocks.count) / 512)))
        let roles: [ACPTranscriptMinimapLayout.Role] = [.history, .notice, .assistant, .user]
        for start in stride(from: 0, to: layout.blocks.count, by: bucketSize) {
            let bucket = layout.blocks[start..<min(layout.blocks.count, start + bucketSize)]
            if bucketSize == 1, let block = bucket.first, block.role == .assistant {
                for band in 0..<block.bandCount {
                    drawing.marks.append(.init(
                        rect: CGRect(x: 0, y: block.y + CGFloat(band * 5), width: 64, height: 3),
                        color: assistantColor
                    ))
                }
                continue
            }
            for role in roles {
                guard let first = bucket.first(where: { $0.role == role }),
                      let last = bucket.last(where: { $0.role == role }) else { continue }
                let x: CGFloat
                let width: CGFloat
                let color: NSColor
                switch role {
                case .user:
                    x = bucketSize > 1 ? 56 : 64
                    width = bucketSize > 1 ? 32 : 24
                    color = userColor
                case .assistant:
                    x = 0
                    width = bucketSize > 1 ? 48 : 64
                    color = assistantColor
                case .notice, .history:
                    x = 0
                    width = 88
                    color = noticeColor
                }
                let inset: CGFloat = role == .assistant ? 0 : 1
                drawing.marks.append(.init(
                    rect: CGRect(x: x, y: first.y + inset, width: width, height: last.y + last.height - first.y - (inset * 2)),
                    color: color
                ))
            }
        }
        cachedDrawing = drawing
        return drawing
    }
}
