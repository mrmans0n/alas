import Foundation

// The fold itself lives in AlasRemoteKit (`ACPTranscriptFold.swift`) over
// `ACPTranscriptFoldItem`s; these overloads keep the Mac's message-based
// signatures and build a lazy, memoized, fold-only source over `messages`
// (no verbs: the fold never reads them).

private extension ACPTranscriptFoldSource {
    @MainActor
    init(
        messages: [ACPMessage],
        hiddenToolCallIds: Set<String> = [],
        createdAt: @escaping (Int) -> Date? = { _ in nil }
    ) {
        // The fold reads some indices several times per pass; map each once.
        var items: [Int: ACPTranscriptFoldItem] = [:]
        self.init(
            count: messages.count,
            item: { index in
                if let item = items[index] { return item }
                let item = ACPTranscriptFoldItem(messages[index], hiddenToolCallIds: hiddenToolCallIds, foldOnly: true)
                items[index] = item
                return item
            },
            createdAt: createdAt
        )
    }
}

extension ACPToolCallGrouping {
    @MainActor
    static func currentTurnAnswerIndex(
        messages: [ACPMessage],
        currentTurnUserIndex: Int?,
        isTurnActive: Bool
    ) -> Int? {
        currentTurnAnswerIndex(
            source: ACPTranscriptFoldSource(messages: messages),
            currentTurnUserIndex: currentTurnUserIndex,
            isTurnActive: isTurnActive
        )
    }

    @MainActor
    static func priorCurrentTurnCommentaryIndices(
        messages: [ACPMessage],
        currentTurnUserIndex: Int?,
        visibleRange: Range<Int>
    ) -> Set<Int> {
        priorCurrentTurnCommentaryIndices(
            source: ACPTranscriptFoldSource(messages: messages),
            currentTurnUserIndex: currentTurnUserIndex,
            visibleRange: visibleRange
        )
    }

    @MainActor
    static func isCollapsible(_ message: ACPMessage, hiddenToolCallIds: Set<String> = []) -> Bool {
        isCollapsible(ACPTranscriptFoldItem(message, hiddenToolCallIds: hiddenToolCallIds, foldOnly: true))
    }

    /// `hiddenToolCallIds` should be the set the rows were built with; when nil
    /// it is linked over the rows' span.
    @MainActor
    static func fold(
        rows: [ACPTranscriptVisibleRow],
        messages: [ACPMessage],
        options: Options,
        hiddenToolCallIds: Set<String>? = nil,
        messageCreatedAt: (Int) -> Date? = { _ in nil },
        isExpanded: (ACPTranscriptToolCallGroup) -> Bool = { _ in false },
        memberLimit: (ACPTranscriptToolCallGroup) -> Int? = { _ in nil }
    ) -> [ACPTranscriptRenderRow] {
        guard options.enabled else { return rows.map(ACPTranscriptRenderRow.message) }

        let hiddenToolCallIds = hiddenToolCallIds ?? {
            guard let first = rows.first?.index, let last = rows.last?.index,
                  messages.indices.contains(first), messages.indices.contains(last), first <= last
            else { return [] }
            return ACPToolCallPresentation.hiddenVisualShowToolCallIds(in: messages[first...last])
        }()
        return withoutActuallyEscaping(messageCreatedAt) { createdAt in
            fold(
                rows: rows,
                source: ACPTranscriptFoldSource(
                    messages: messages,
                    hiddenToolCallIds: hiddenToolCallIds,
                    createdAt: createdAt
                ),
                options: options,
                isExpanded: isExpanded,
                memberLimit: memberLimit
            )
        }
    }
}

extension ACPToolCallGroupSummary {
    init(
        toolCalls: [ACPMessage.ToolCall],
        kind: ACPTranscriptToolCallGroup.Kind = .activity,
        isLive: Bool = false
    ) {
        self.init(
            toolCalls: toolCalls.map {
                ACPTranscriptFoldToolCall(
                    status: $0.status,
                    joins: true,
                    verb: Self.verb(forLabel: ACPToolCallPresentation.resolve($0).label)
                )
            },
            kind: kind,
            isLive: isLive
        )
    }

    static func verb(for presentation: ACPToolCallPresentation) -> Verb {
        verb(forLabel: presentation.label)
    }
}
