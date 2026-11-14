import AlasRemoteKit
import Foundation
import Observation

/// Seeded so every run renders the same transcript.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private let words = [
    "transcript", "window", "render", "stream", "layout", "scroll", "anchor", "message", "update", "diff",
    "session", "viewport", "cache", "measure", "prepend", "token", "markdown", "revision", "commit", "build",
]

private func sentence(_ rng: inout SplitMix64) -> String {
    let text = (0 ..< Int.random(in: 6 ... 18, using: &rng)).map { _ in words.randomElement(using: &rng)! }
        .joined(separator: " ")
    return text.prefix(1).uppercased() + text.dropFirst() + "."
}

private func codeLines(_ count: Int, _ rng: inout SplitMix64) -> String {
    (0 ..< count).map { i in
        "    let value\(i) = \(words.randomElement(using: &rng)!)(\(Int.random(in: 0 ... 999, using: &rng)))"
    }.joined(separator: "\n")
}

private func encode(_ value: some Encodable) -> String {
    // Encoding these plain value types cannot fail.
    String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
}

enum SpikeTranscriptGenerator {
    /// Per 20 rows: 2 user, 6 agent, 3 thought, 5 toolCall, 2 fileEdit, 1 plan, 1 systemNotice.
    private static let pattern = [
        "user", "agent", "agent", "thought", "toolCall", "agent", "toolCall", "fileEdit", "agent", "thought",
        "toolCall", "agent", "user", "toolCall", "plan", "agent", "thought", "toolCall", "fileEdit", "systemNotice",
    ]

    static func messages(count: Int, seed: UInt64) -> [RemoteWireMessage] {
        var rng = SplitMix64(state: seed)
        var agentOrdinal = 0
        return (0 ..< count).map { index in
            var kind = pattern[index % pattern.count]
            let isHuge = index == count / 2
            if isHuge { kind = "agent" }
            var text: String?
            var json: String?
            switch kind {
            case "agent":
                agentOrdinal += 1
                text = isHuge ? hugeCodeBlock(&rng) : agentMarkdown(ordinal: agentOrdinal, &rng)
            case "user", "thought":
                text = (0 ..< Int.random(in: 1 ... 3, using: &rng)).map { _ in sentence(&rng) }.joined(separator: " ")
            case "systemNotice":
                text = "Session resumed."
            case "toolCall":
                let lines = Int.random(in: 5 ... 80, using: &rng)
                json = encode(ACPToolCall(
                    toolCallId: "call\(index)", title: "Run \(words.randomElement(using: &rng)!)", kind: "execute",
                    status: "completed", content: codeLines(lines, &rng), contentLanguage: "swift"))
            case "fileEdit":
                let added = Int.random(in: 1 ... 40, using: &rng)
                json = encode(ACPFileEdit(
                    path: "Sources/File\(index).swift", added: added, removed: added / 2,
                    oldText: codeLines(added / 2, &rng), newText: codeLines(added, &rng)))
            default:
                json = encode([
                    ACPPlanItem(content: "Read the code", status: "completed"),
                    ACPPlanItem(content: "Write the fix", status: "in_progress"),
                    ACPPlanItem(content: "Verify", status: "pending"),
                ])
            }
            return RemoteWireMessage(stableId: "m\(index)", kind: kind, text: text, json: json, index: index)
        }
    }

    private static func hugeCodeBlock(_ rng: inout SplitMix64) -> String {
        "A very long listing:\n\n```swift\n\(codeLines(2000, &rng))\n```"
    }

    private static func agentMarkdown(ordinal: Int, _ rng: inout SplitMix64) -> String {
        var blocks = (0 ..< Int.random(in: 1 ... 5, using: &rng)).map { _ in
            (0 ..< Int.random(in: 1 ... 4, using: &rng)).map { _ in sentence(&rng) }.joined(separator: " ")
        }
        if ordinal % 3 == 0 { blocks.insert("```swift\n\(codeLines(Int.random(in: 4 ... 20, using: &rng), &rng))\n```", at: 1) }
        if ordinal % 5 == 0 { blocks.append((0 ..< 3).map { _ in "- \(sentence(&rng))" }.joined(separator: "\n")) }
        if ordinal % 10 == 0 {
            blocks.append("| Name | Value |\n| --- | --- |\n" + (0 ..< 3).map { "| \(words[$0]) | \(Int.random(in: 0 ... 99, using: &rng)) |" }.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }
}

@MainActor @Observable
final class SpikeTranscriptModel {
    private(set) var rows: [TranscriptItem]
    var expanded: Set<String> = []
    var isStreaming = false {
        didSet {
            guard isStreaming != oldValue else { return }
            isStreaming ? startStreaming() : stopStreaming()
        }
    }

    @ObservationIgnored private var older: [TranscriptItem]
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var rng = SplitMix64(state: 42)
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var streamed = 0
    @ObservationIgnored private var inFence = false

    var canLoadOlder: Bool { !older.isEmpty }

    init(totalCount: Int, windowSize: Int = 200) {
        let all = SpikeTranscriptGenerator.messages(count: totalCount, seed: 1).map(TranscriptItem.init(message:))
        let split = max(0, all.count - windowSize)
        older = Array(all[..<split])
        rows = Array(all[split...])
    }

    func loadOlder(pageSize: Int = 100) {
        let page = older.suffix(pageSize)
        older.removeLast(page.count)
        rows.insert(contentsOf: page, at: 0)
    }

    private func startStreaming() {
        streamTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard !Task.isCancelled, let self else { return }
                tick()
            }
        }
    }

    private func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
    }

    private func tick() {
        tickCount += 1
        if tickCount % 90 == 0 {
            streamed += 1
            let call = ACPToolCall(
                toolCallId: "stream\(streamed)", title: "Run stream", kind: "execute", status: "completed",
                content: codeLines(Int.random(in: 5 ... 80, using: &rng), &rng))
            if inFence { appendToLastAgent("\n```\n") }
            inFence = false
            let index = (rows.last?.message.index ?? -1) + 1
            rows.append(TranscriptItem(message: RemoteWireMessage(
                stableId: "s\(streamed)t", kind: "toolCall", text: nil, json: encode(call), index: index)))
            rows.append(TranscriptItem(message: RemoteWireMessage(
                stableId: "s\(streamed)a", kind: "agent", text: "", json: nil, index: index + 1)))
            return
        }
        appendToLastAgent(nextChunk())
    }

    private func appendToLastAgent(_ chunk: String) {
        guard let last = rows.lastIndex(where: { $0.message.kind == "agent" }) else { return }
        let old = rows[last].message
        rows[last] = TranscriptItem(message: RemoteWireMessage(
            stableId: old.stableId, kind: "agent", text: (old.text ?? "") + chunk, json: nil, index: old.index))
    }

    /// 6-40 characters; sometimes ends a line, sometimes opens or closes a code fence.
    private func nextChunk() -> String {
        var chunk = ""
        let target = Int.random(in: 6 ... 40, using: &rng)
        while chunk.count < target { chunk += words.randomElement(using: &rng)! + " " }
        chunk = String(chunk.prefix(target))
        switch Int.random(in: 0 ..< 6, using: &rng) {
        case 0: chunk += "\n"
        case 1:
            chunk += inFence ? "\n```\n" : "\n```swift\n"
            inFence.toggle()
        default: break
        }
        return chunk
    }
}
