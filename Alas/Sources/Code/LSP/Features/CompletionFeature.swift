import AppKit
import SwiftUI

@MainActor
final class CompletionFeature {
    private struct CandidateIdentity: Hashable {
        let label: String
        let kind: Int?
        let detail: String?
        let source: CompletionCandidateSource
        let editPlan: CompletionEditPlan
    }

    private weak var textView: CodeTextView?
    private let getClient: () -> LSPClient?
    private let getURI: () -> String?
    private let isEnabled: () -> Bool
    private let getTheme: () -> Theme
    private let getMonoFontFamily: () -> String
    private let getMonoFontSize: () -> Int
    private let prepareForCompletionRequest: @MainActor () async -> Void

    private var debounceTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var requestID: UInt64 = 0
    private var candidates: [CompletionCandidate] = []
    private var candidatePool: [CompletionCandidate] = []
    private var prefix: CompletionPrefix?
    private var candidatePrefix: CompletionPrefix?
    private var candidateOrigins: [UUID: CompletionPrefix] = [:]
    private var candidateCoordinateIndex: TextEditCoordinates.LineIndex?
    private var candidateBufferCache: [String: [CompletionCandidate]] = [:]
    private var candidateItems: [LSPCompletionItem] = []
    private var candidateAllowsBufferFallback = false
    private var candidateMemberAccessOnly = false
    private var candidateAllowsEmptyPrefix = false
    private var selection: Int = 0
    private var selectedCandidateID: UUID?
    private let suggestionWindow = CompletionWindowController()
    private var isRefreshing = false

    private let automaticDebounceNanos: UInt64 = 120_000_000
    private let requestTimeoutNanos: UInt64 = 900_000_000
    private let fallbackTriggerCharacters = [".", "->", "::"]
    private static let memberAccessTriggerCharacters: Set<String> = [".", "->", "::"]

    init(
        textView: CodeTextView,
        getClient: @escaping () -> LSPClient?,
        getURI: @escaping () -> String?,
        isEnabled: @escaping () -> Bool,
        getTheme: @escaping () -> Theme = {
            (try? Theme.loadBundled(id: "cool-slate")) ?? Theme(id: "fallback", name: "Fallback", tokens: [:])
        },
        getMonoFontFamily: @escaping () -> String = { "JetBrainsMono Nerd Font" },
        getMonoFontSize: @escaping () -> Int = { 13 },
        prepareForCompletionRequest: @escaping @MainActor () async -> Void = {}
    ) {
        self.textView = textView
        self.getClient = getClient
        self.getURI = getURI
        self.isEnabled = isEnabled
        self.getTheme = getTheme
        self.getMonoFontFamily = getMonoFontFamily
        self.getMonoFontSize = getMonoFontSize
        self.prepareForCompletionRequest = prepareForCompletionRequest

        textView.completionManualTriggerHandler = { [weak self] in
            self?.triggerManual()
        }
        textView.completionChangeHandler = { [weak self] editRange in
            self?.scheduleAutomatic(editRange: editRange)
        }
        textView.completionSelectionChangeHandler = { [weak self] in
            self?.cancelAndDismiss()
        }
        textView.completionKeyHandler = { [weak self] action in
            self?.handleKey(action) ?? false
        }
    }

    func cancelAndDismiss() {
        debounceTask?.cancel()
        requestTask?.cancel()
        debounceTask = nil
        requestTask = nil
        requestID &+= 1
        candidates.removeAll()
        candidatePool.removeAll()
        prefix = nil
        candidatePrefix = nil
        candidateOrigins.removeAll()
        candidateCoordinateIndex = nil
        candidateBufferCache.removeAll()
        candidateItems.removeAll()
        candidateAllowsBufferFallback = false
        candidateMemberAccessOnly = false
        candidateAllowsEmptyPrefix = false
        selection = 0
        selectedCandidateID = nil
        isRefreshing = false
        closeUI()
    }

    private func triggerManual() {
        debounceTask?.cancel()
        debounceTask = nil
        startCompletion(trigger: .invoked, triggerCharacter: nil, allowEmptyPrefix: true, allowBufferFallback: true)
    }

    private func scheduleAutomatic(editRange: NSRange?) {
        guard hasSessionPreconditions() else {
            cancelAndDismiss()
            return
        }

        debounceTask?.cancel()
        invalidateActiveSessionForChange(editRange: editRange)
        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: automaticDebounceNanos)
            guard !Task.isCancelled else { return }
            debounceTask = nil
            let triggerCharacter = await automaticTriggerCharacter()
            guard !Task.isCancelled else { return }
            startCompletion(
                trigger: triggerCharacter == nil ? .invoked : .triggerCharacter,
                triggerCharacter: triggerCharacter,
                allowEmptyPrefix: triggerCharacter != nil,
                allowBufferFallback: triggerCharacter == nil,
                memberAccessOnly: Self.isMemberAccessTriggerCharacter(triggerCharacter)
            )
        }
    }

    static func isMemberAccessTriggerCharacter(_ triggerCharacter: String?) -> Bool {
        guard let triggerCharacter else { return false }
        return memberAccessTriggerCharacters.contains(triggerCharacter)
    }

    private func automaticTriggerCharacter() async -> String? {
        guard let textView,
              let client = getClient() else { return nil }

        let configuredTriggers = await client.completionTriggerCharacters
        let triggers = configuredTriggers.isEmpty ? fallbackTriggerCharacters : configuredTriggers
        return CompletionEngine.completionTriggerSuffix(
            in: textView.string,
            caret: textView.selectedRange().location,
            triggers: triggers
        )
    }

    private func startCompletion(
        trigger: LSPCompletionTriggerKind,
        triggerCharacter: String?,
        allowEmptyPrefix: Bool,
        allowBufferFallback: Bool,
        memberAccessOnly: Bool = false
    ) {
        guard hasSessionPreconditions(),
              let textView,
              let uri = getURI() else {
            cancelAndDismiss()
            return
        }

        let caret = textView.selectedRange().location
        let bufferText = textView.string
        guard let prefix = CompletionEngine.prefix(in: bufferText, caret: caret),
              allowEmptyPrefix || !prefix.text.isEmpty else {
            cancelAndDismiss()
            return
        }

        self.prefix = prefix
        requestTask?.cancel()
        requestID &+= 1
        let currentRequestID = requestID
        let timeoutNanos = requestTimeoutNanos
        let position = TextEditCoordinates.lspPosition(utf16Offset: caret, in: bufferText)
        let client = getClient()
        let context = LSPCompletionContext(triggerKind: trigger, triggerCharacter: triggerCharacter)

        requestTask = Task { [weak self] in
            await self?.prepareForCompletionRequest()
            guard !Task.isCancelled else { return }

            let lspItems: [LSPCompletionItem]
            if let client, let position {
                lspItems = await Self.requestCompletionWithTimeout(
                    client: client,
                    uri: uri,
                    position: position,
                    context: context,
                    timeoutNanos: timeoutNanos
                )
            } else {
                lspItems = []
            }

            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self,
                      self.requestID == currentRequestID,
                      self.getURI() == uri,
                      let activeTextView = self.textView,
                      self.hasSessionPreconditions(),
                      activeTextView.selectedRange().location == caret,
                      CompletionEngine.prefix(in: activeTextView.string, caret: caret) == prefix else {
                    return
                }
                self.present(
                    items: lspItems,
                    prefix: prefix,
                    bufferText: activeTextView.string,
                    allowEmptyPrefix: allowEmptyPrefix,
                    allowBufferFallback: allowBufferFallback,
                    memberAccessOnly: memberAccessOnly
                )
            }
        }
    }

    private nonisolated static func requestCompletionWithTimeout(
        client: LSPClient,
        uri: String,
        position: LSPPosition,
        context: LSPCompletionContext,
        timeoutNanos: UInt64
    ) async -> [LSPCompletionItem] {
        await withTaskGroup(of: [LSPCompletionItem].self) { group in
            group.addTask {
                ((try? await client.completion(uri: uri, position: position, context: context))?.items) ?? []
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanos)
                return []
            }

            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
    }

    private func present(
        items: [LSPCompletionItem],
        prefix: CompletionPrefix,
        bufferText: String,
        allowEmptyPrefix: Bool,
        allowBufferFallback: Bool,
        memberAccessOnly: Bool
    ) {
        let coordinateIndex = TextEditCoordinates.LineIndex(bufferText)
        let retainedMemberAccessOnly = candidateMemberAccessOnly || memberAccessOnly
        let retainedBufferFallback = allowBufferFallback && !retainedMemberAccessOnly
        let bufferCache = retainedBufferFallback
            ? CompletionEngine.bufferWordCandidateCache(in: bufferText, prefix: prefix)
            : [:]
        let next = Self.candidates(
            items: items,
            prefix: prefix,
            bufferCandidates: bufferCache[prefix.text] ?? [],
            allowBufferFallback: retainedBufferFallback,
            memberAccessOnly: retainedMemberAccessOnly
        )

        let selectedCandidate = candidates.indices.contains(selection)
            ? candidates[selection]
            : candidatePool.first { $0.id == selectedCandidateID }
        let selectedEditPlan = selectedCandidate.flatMap { candidate in
            CompletionEngine.editPlan(
                accepting: candidate,
                prefix: prefix,
                originalPrefix: candidateOrigins[candidate.id],
                in: bufferText,
                coordinateIndex: coordinateIndex
            )
        }
        let merged = Self.mergingCandidates(
            next,
            originPrefix: prefix,
            with: candidatePool,
            origins: candidateOrigins,
            prefix: prefix,
            text: bufferText,
            coordinateIndex: coordinateIndex
        )
        let visible = merged.candidates.filter { Self.isVisible($0, for: prefix) }

        candidates = visible
        candidatePool = merged.candidates
        self.prefix = prefix
        candidateOrigins = merged.origins
        candidateCoordinateIndex = coordinateIndex
        let keepsBroaderResponse = candidatePrefix.map {
            $0.range.location == prefix.range.location && $0.range.length < prefix.range.length
        } ?? false
        candidateBufferCache.merge(bufferCache) { _, latest in latest }
        if !keepsBroaderResponse {
            candidatePrefix = prefix
            candidateItems = items
        }
        candidateAllowsBufferFallback = retainedBufferFallback
        candidateMemberAccessOnly = retainedMemberAccessOnly
        candidateAllowsEmptyPrefix = candidateAllowsEmptyPrefix || allowEmptyPrefix
        isRefreshing = false
        selection = selectedCandidate.flatMap { selected in
            visible.firstIndex {
                $0.label == selected.label &&
                    $0.kind == selected.kind &&
                    $0.detail == selected.detail &&
                    $0.source == selected.source &&
                    selectedEditPlan != nil &&
                    CompletionEngine.editPlan(
                        accepting: $0,
                        prefix: prefix,
                        originalPrefix: candidateOrigins[$0.id],
                        in: bufferText,
                        coordinateIndex: coordinateIndex
                    ) == selectedEditPlan
            }
        } ?? 0
        if candidates.indices.contains(selection) {
            selectedCandidateID = candidates[selection].id
        }
        if candidates.isEmpty {
            closeUI()
        } else {
            showPopup()
        }
    }

    private static func candidates(
        items: [LSPCompletionItem],
        prefix: CompletionPrefix,
        bufferCandidates: [CompletionCandidate],
        allowBufferFallback: Bool,
        memberAccessOnly: Bool
    ) -> [CompletionCandidate] {
        var candidates = CompletionEngine.lspCandidates(
            from: items,
            prefix: prefix,
            memberAccessOnly: memberAccessOnly
        )
        if allowBufferFallback {
            candidates.append(contentsOf: bufferCandidates.filter { bufferCandidate in
                !candidates.contains { $0.label == bufferCandidate.label }
            })
        }
        return candidates
    }

    private static func mergingCandidates(
        _ candidates: [CompletionCandidate],
        originPrefix: CompletionPrefix,
        with retained: [CompletionCandidate],
        origins: [UUID: CompletionPrefix],
        prefix: CompletionPrefix,
        text: String,
        coordinateIndex: TextEditCoordinates.LineIndex
    ) -> (candidates: [CompletionCandidate], origins: [UUID: CompletionPrefix]) {
        var merged = candidates
        var mergedOrigins = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, originPrefix) })
        var identities = Set(merged.compactMap {
            candidateIdentity(
                for: $0,
                origin: mergedOrigins[$0.id],
                prefix: prefix,
                text: text,
                coordinateIndex: coordinateIndex
            )
        })
        for candidate in retained {
            let identity = candidateIdentity(
                for: candidate,
                origin: origins[candidate.id],
                prefix: prefix,
                text: text,
                coordinateIndex: coordinateIndex
            )
            guard identity.map({ !identities.contains($0) }) ?? true else { continue }
            merged.append(candidate)
            mergedOrigins[candidate.id] = origins[candidate.id]
            if let identity { identities.insert(identity) }
        }
        return (merged, mergedOrigins)
    }

    private static func candidateIdentity(
        for candidate: CompletionCandidate,
        origin: CompletionPrefix?,
        prefix: CompletionPrefix,
        text: String,
        coordinateIndex: TextEditCoordinates.LineIndex
    ) -> CandidateIdentity? {
        guard let editPlan = CompletionEngine.editPlan(
            accepting: candidate,
            prefix: prefix,
            originalPrefix: origin,
            in: text,
            coordinateIndex: coordinateIndex
        ) else { return nil }
        return CandidateIdentity(
            label: candidate.label,
            kind: candidate.kind,
            detail: candidate.detail,
            source: candidate.source,
            editPlan: editPlan
        )
    }

    private static func isVisible(_ candidate: CompletionCandidate, for prefix: CompletionPrefix) -> Bool {
        if candidate.source == .buffer,
           (prefix.text as NSString).length < CompletionEngine.bufferWordMinimumPrefixLength {
            return false
        }
        let filter = candidate.filterText ?? candidate.label
        return CompletionEngine.hasCaseInsensitivePrefix(filter, prefix.text) ||
            CompletionEngine.hasCaseInsensitivePrefix(candidate.label, prefix.text)
    }

    private func showPopup() {
        guard let textView,
              let anchor = textView.completionAnchorRect() else {
            cancelAndDismiss()
            return
        }

        let rows = candidates.map {
            CompletionPopupRow(
                id: $0.id,
                label: $0.label,
                detail: $0.detail,
                kind: $0.kind,
                source: $0.source
            )
        }
        let documentationText = candidates.indices.contains(selection) ? candidates[selection].documentation : nil
        let theme = getTheme()
        let documentation = documentationText.flatMap { text -> MarkdownRenderResult? in
            guard !text.isEmpty else { return nil }
            return CompletionDocumentationRenderer.render(
                text,
                theme: theme,
                monospacedFontFamily: getMonoFontFamily(),
                monospacedFontSize: getMonoFontSize()
            )
        }
        suggestionWindow.show(
            rows: rows,
            selection: selection,
            documentation: documentation,
            theme: theme,
            anchor: anchor,
            in: textView
        ) { [weak self] index in
            self?.accept(index: index)
        }
    }

    private func handleKey(_ action: CodeTextView.CompletionKeyAction) -> Bool {
        if case .dismiss = action, suggestionWindow.isVisible || !candidates.isEmpty || isRefreshing {
            cancelAndDismiss()
            return true
        }

        guard !isRefreshing, !candidates.isEmpty else { return false }
        guard suggestionWindow.isVisible else {
            cancelAndDismiss()
            return false
        }

        switch action {
        case .acceptTop:
            accept(index: 0)
            return true
        case .acceptSelected:
            accept(index: selection)
            return true
        case .moveSelection(let delta):
            selection = min(max(0, selection + delta), candidates.count - 1)
            selectedCandidateID = candidates[selection].id
            showPopup()
            return true
        case .dismiss:
            return false
        }
    }

    private func accept(index: Int) {
        guard let textView,
              candidates.indices.contains(index),
              let prefix,
              canAcceptCompletion(prefix: prefix, in: textView) else {
            cancelAndDismiss()
            return
        }

        let candidate = candidates[index]
        guard let plan = CompletionEngine.editPlan(
            accepting: candidate,
            prefix: prefix,
            originalPrefix: candidateOrigins[candidate.id],
            in: textView.string
        ) else {
            cancelAndDismiss()
            return
        }

        textView.applyCompletionEdits(plan.edits, finalSelection: plan.finalSelection)
        cancelAndDismiss()
    }

    private func closeUI() {
        suggestionWindow.hide()
    }

    private func invalidateActiveSessionForChange(editRange: NSRange?) {
        let previousPrefix = prefix
        requestTask?.cancel()
        requestTask = nil
        requestID &+= 1
        isRefreshing = true

        guard let textView,
              let updatedPrefix = CompletionEngine.prefix(
                in: textView.string,
                caret: textView.selectedRange().location
              ),
              candidateAllowsEmptyPrefix || !updatedPrefix.text.isEmpty,
              previousPrefix?.range.location == updatedPrefix.range.location,
              let previousPrefix,
              let editRange,
              editRange.location >= previousPrefix.range.location,
              NSMaxRange(editRange) <= NSMaxRange(previousPrefix.range) else {
            candidates.removeAll()
            candidatePool.removeAll()
            prefix = nil
            candidatePrefix = nil
            candidateOrigins.removeAll()
            candidateCoordinateIndex = nil
            candidateBufferCache.removeAll()
            candidateItems.removeAll()
            candidateAllowsBufferFallback = false
            candidateMemberAccessOnly = false
            candidateAllowsEmptyPrefix = false
            selection = 0
            selectedCandidateID = nil
            closeUI()
            return
        }

        let bufferText = textView.string
        let prefixDelta = updatedPrefix.range.length - previousPrefix.range.length
        let coordinateIndex = candidateCoordinateIndex?
            .adjustingOffsets(after: editRange.location, by: prefixDelta) ?? TextEditCoordinates.LineIndex(bufferText)
        candidateCoordinateIndex = coordinateIndex
        let selectedCandidate = candidates.indices.contains(selection)
            ? candidates[selection]
            : candidatePool.first { $0.id == selectedCandidateID }
        let selectedEditPlan = selectedCandidate.flatMap { candidate in
            CompletionEngine.editPlan(
                accepting: candidate,
                prefix: updatedPrefix,
                originalPrefix: candidateOrigins[candidate.id],
                in: bufferText,
                coordinateIndex: coordinateIndex
            )
        }
        if let candidatePrefix,
           updatedPrefix.range.length < previousPrefix.range.length,
           !candidateItems.isEmpty || candidateAllowsBufferFallback {
            let rebuilt = Self.candidates(
                items: candidateItems,
                prefix: updatedPrefix,
                bufferCandidates: candidateBufferCache[updatedPrefix.text] ?? [],
                allowBufferFallback: candidateAllowsBufferFallback,
                memberAccessOnly: candidateMemberAccessOnly
            )
            let merged = Self.mergingCandidates(
                rebuilt,
                originPrefix: candidatePrefix,
                with: candidatePool,
                origins: candidateOrigins,
                prefix: updatedPrefix,
                text: bufferText,
                coordinateIndex: coordinateIndex
            )
            candidatePool = merged.candidates
            candidateOrigins = merged.origins
        }

        candidates = candidatePool.filter { Self.isVisible($0, for: updatedPrefix) }
        isRefreshing = candidates.isEmpty
        prefix = updatedPrefix
        selection = selectedCandidate.flatMap { selected in
            candidates.firstIndex {
                $0.label == selected.label &&
                    $0.kind == selected.kind &&
                    $0.detail == selected.detail &&
                    $0.source == selected.source &&
                    selectedEditPlan != nil &&
                    CompletionEngine.editPlan(
                        accepting: $0,
                        prefix: updatedPrefix,
                        originalPrefix: candidateOrigins[$0.id],
                        in: bufferText,
                        coordinateIndex: coordinateIndex
                    ) == selectedEditPlan
            }
        } ?? 0
        if candidates.indices.contains(selection) {
            selectedCandidateID = candidates[selection].id
        }

        if candidates.isEmpty {
            closeUI()
        } else {
            showPopup()
        }
    }

    private func canAcceptCompletion(prefix: CompletionPrefix, in textView: CodeTextView) -> Bool {
        let text = textView.string
        let length = (text as NSString).length
        let currentSelection = textView.selectedRange()
        let caret = NSMaxRange(prefix.range)

        guard prefix.range.location != NSNotFound,
              prefix.range.location >= 0,
              prefix.range.length >= 0,
              caret <= length,
              currentSelection.location == caret,
              currentSelection.length == 0 else {
            return false
        }

        return CompletionEngine.prefix(in: text, caret: caret) == prefix
    }

    private func hasSessionPreconditions() -> Bool {
        guard isEnabled(),
              let textView,
              textView.isEditable,
              textView.selectedRanges.count == 1,
              textView.selectedRange().length == 0 else {
            return false
        }
        return true
    }
}

#if DEBUG
extension CompletionFeature {
    struct TestingSnapshot: Equatable {
        let candidateLabels: [String]
        let prefix: CompletionPrefix?
        let selection: Int
        let isRefreshing: Bool
    }

    func testingSeedVisibleCandidates(
        labels: [String],
        prefix: CompletionPrefix,
        selection: Int = 0,
        memberAccessOnly: Bool = false
    ) {
        candidates = labels.map { label in
            CompletionCandidate(
                label: label,
                detail: nil,
                kind: nil,
                documentation: nil,
                sortText: nil,
                filterText: label,
                replacementText: label,
                textEdit: nil,
                additionalTextEdits: [],
                source: .lsp
            )
        }
        candidatePool = candidates
        self.prefix = prefix
        candidatePrefix = prefix
        candidateOrigins = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, prefix) })
        candidateCoordinateIndex = textView.map { TextEditCoordinates.LineIndex($0.string) }
        candidateBufferCache.removeAll()
        candidateMemberAccessOnly = memberAccessOnly
        candidateAllowsEmptyPrefix = prefix.text.isEmpty
        self.selection = min(max(selection, 0), max(candidates.count - 1, 0))
        selectedCandidateID = candidates.indices.contains(self.selection) ? candidates[self.selection].id : nil
        isRefreshing = false
    }

    func testingShowPopup() {
        showPopup()
    }

    func testingSetSelection(_ selection: Int) {
        self.selection = min(max(selection, 0), max(candidates.count - 1, 0))
        selectedCandidateID = candidates.indices.contains(self.selection) ? candidates[self.selection].id : nil
    }

    func testingPresent(
        items: [LSPCompletionItem],
        prefix: CompletionPrefix,
        bufferText: String,
        allowEmptyPrefix: Bool = false,
        allowBufferFallback: Bool = false,
        memberAccessOnly: Bool = false
    ) {
        present(
            items: items,
            prefix: prefix,
            bufferText: bufferText,
            allowEmptyPrefix: allowEmptyPrefix,
            allowBufferFallback: allowBufferFallback,
            memberAccessOnly: memberAccessOnly
        )
    }

    var testingSnapshot: TestingSnapshot {
        TestingSnapshot(
            candidateLabels: candidates.map(\.label),
            prefix: prefix,
            selection: selection,
            isRefreshing: isRefreshing
        )
    }
}
#endif
