import AppKit
import SwiftUI

@MainActor
final class CompletionFeature {
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
    private var prefix: CompletionPrefix?
    private var candidatePrefix: CompletionPrefix?
    private var selection: Int = 0
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
        textView.completionChangeHandler = { [weak self] in
            self?.scheduleAutomatic()
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
        prefix = nil
        candidatePrefix = nil
        selection = 0
        isRefreshing = false
        closeUI()
    }

    private func triggerManual() {
        debounceTask?.cancel()
        debounceTask = nil
        startCompletion(trigger: .invoked, triggerCharacter: nil, allowEmptyPrefix: true, allowBufferFallback: true)
    }

    private func scheduleAutomatic() {
        guard hasSessionPreconditions() else {
            cancelAndDismiss()
            return
        }

        debounceTask?.cancel()
        invalidateActiveSessionForChange()
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
        allowBufferFallback: Bool,
        memberAccessOnly: Bool
    ) {
        var next = CompletionEngine.lspCandidates(
            from: items,
            prefix: prefix,
            memberAccessOnly: memberAccessOnly
        )
        if allowBufferFallback {
            let buffer = CompletionEngine.bufferWordCandidates(in: bufferText, prefix: prefix)
            next.append(contentsOf: buffer.filter { bufferCandidate in
                !next.contains { $0.label == bufferCandidate.label }
            })
        }

        guard !next.isEmpty else {
            cancelAndDismiss()
            return
        }

        let selectedCandidate = candidates.indices.contains(selection) ? candidates[selection] : nil
        candidates = next
        self.prefix = prefix
        candidatePrefix = prefix
        isRefreshing = false
        selection = selectedCandidate.flatMap { selected in
            next.firstIndex {
                $0.label == selected.label &&
                    $0.kind == selected.kind &&
                    $0.detail == selected.detail &&
                    $0.source == selected.source &&
                    $0.replacementText == selected.replacementText &&
                    $0.additionalTextEdits.map(\.newText) == selected.additionalTextEdits.map(\.newText)
            }
        } ?? 0
        showPopup()
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
            originalPrefix: candidatePrefix,
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

    private func invalidateActiveSessionForChange() {
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
              !updatedPrefix.text.isEmpty,
              previousPrefix?.range.location == updatedPrefix.range.location else {
            candidates.removeAll()
            prefix = nil
            candidatePrefix = nil
            selection = 0
            closeUI()
            return
        }

        let selectedCandidateID = candidates.indices.contains(selection) ? candidates[selection].id : nil
        candidates.removeAll { candidate in
            let filter = candidate.filterText ?? candidate.label
            return !CompletionEngine.hasCaseInsensitivePrefix(filter, updatedPrefix.text) &&
                !CompletionEngine.hasCaseInsensitivePrefix(candidate.label, updatedPrefix.text)
        }
        isRefreshing = candidates.isEmpty
        prefix = candidates.isEmpty ? nil : updatedPrefix
        selection = selectedCandidateID.flatMap { id in candidates.firstIndex { $0.id == id } } ?? 0

        if candidates.isEmpty {
            closeUI()
        } else if suggestionWindow.isVisible {
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
        replacementTexts: [String]? = nil,
        prefix: CompletionPrefix,
        selection: Int = 0
    ) {
        candidates = labels.enumerated().map { index, label in
            CompletionCandidate(
                label: label,
                detail: nil,
                kind: nil,
                documentation: nil,
                sortText: nil,
                filterText: label,
                replacementText: replacementTexts?[index] ?? label,
                textEdit: nil,
                additionalTextEdits: [],
                source: .lsp
            )
        }
        self.prefix = prefix
        candidatePrefix = prefix
        self.selection = min(max(selection, 0), max(candidates.count - 1, 0))
        isRefreshing = false
    }

    func testingShowPopup() {
        showPopup()
    }

    func testingPresent(items: [LSPCompletionItem], prefix: CompletionPrefix, bufferText: String) {
        present(
            items: items,
            prefix: prefix,
            bufferText: bufferText,
            allowBufferFallback: false,
            memberAccessOnly: false
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
