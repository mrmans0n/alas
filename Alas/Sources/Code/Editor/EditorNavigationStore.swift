import Foundation
import Observation

private struct NavigationSnippetSnapshot: Sendable {
    let text: String
    let byteCount: Int
    let lines: [NSRange]

    init(_ text: String) {
        self.text = text
        byteCount = text.utf8.count
        let source = text as NSString
        var ranges: [NSRange] = []
        var offset = 0
        // Index once off-main. Extreme newline-only files stop at this prefix.
        while offset < source.length, ranges.count < 65_536 {
            let range = source.lineRange(for: NSRange(location: offset, length: 0))
            ranges.append(range)
            offset = NSMaxRange(range)
        }
        lines = ranges
    }

    func line(_ index: Int) -> String {
        guard lines.indices.contains(index), lines[index].length <= 512 else { return "Snippet unavailable" }
        return (text as NSString).substring(with: lines[index]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct EditorNavigationTarget: Hashable, Sendable {
    let document: EditorDocumentID
    let position: LSPPosition
}

@MainActor
@Observable
final class EditorNavigationStore {
    private static let historyLimit = 200

    private(set) var results: [EditorNavigationTarget] = []
    private(set) var snippets: [EditorNavigationTarget: String] = [:]
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    private(set) var resultsAreStale = false
    var isPresented = false
    var isExpanded = true
    var height: CGFloat = 220
    typealias SnippetReader = @Sendable (EditorDocumentID, Int) async -> String?
    nonisolated private static let documentByteLimit = 1_048_576
    nonisolated private static let retainedByteLimit = 8_388_608
    private let snippetReader: SnippetReader
    private let openBuffer: (EditorDocumentID) -> EditorBuffer?
    private var snippetGeneration = UUID()
    private var visibleSnippetTargets = Set<EditorNavigationTarget>()
    private var referenceSnippetTargets = Set<EditorNavigationTarget>()
    private var snippetSessions: [UUID: Set<EditorNavigationTarget>] = [:]
    private var pendingSnippetDocuments: [EditorDocumentID] = []
    private var activeSnippetDocuments: [EditorDocumentID: Task<Void, Never>] = [:]
    private var cachedSnippetDocuments: [EditorDocumentID: NavigationSnippetSnapshot] = [:]
    private var unavailableSnippetDocuments = Set<EditorDocumentID>()
    private var snippetCacheOrder: [EditorDocumentID] = []
    private var snippetBufferGenerations: [EditorDocumentID: Int] = [:]
    private var snippetBufferIdentities: [EditorDocumentID: ObjectIdentifier] = [:]
    private(set) var retainedSnippetBytes = 0
    var cachedSnippetDocumentCount: Int { snippetCacheOrder.count }
    var pendingSnippetDocumentCount: Int { pendingSnippetDocuments.count }
    var activeSnippetDocumentCount: Int { activeSnippetDocuments.count }
    private(set) var snippetRevision = 0
    private var history: [EditorNavigationTarget] = []
    private var historyIndex: Int?
    private var pendingHistoryActivation: (from: Int, to: Int)?
    private var onHistoryChange: (() -> Void)?
    private var referenceQuery: (client: LSPClient, context: EditorRequestContext, isCurrent: (EditorRequestContext) -> Bool)?
    private var rerunTask: Task<Void, Never>?
    private var queryGeneration = UUID()
    var cancelRequestHandler: (() -> Void)?
    var selectedResult: EditorNavigationTarget?

    var orderedResults: [EditorNavigationTarget] {
        results.sorted {
            if $0.document.uri != $1.document.uri { return $0.document.uri < $1.document.uri }
            if $0.document.host != $1.document.host { return ($0.document.host ?? "") < ($1.document.host ?? "") }
            if $0.position.line != $1.position.line { return $0.position.line < $1.position.line }
            return $0.position.character < $1.position.character
        }
    }

    func moveResultSelection(by delta: Int) {
        let ordered = orderedResults
        guard !ordered.isEmpty else { selectedResult = nil
            return
        }
        let index = selectedResult.flatMap { ordered.firstIndex(of: $0) } ?? (delta > 0 ? -1 : ordered.count)
        selectedResult = ordered[max(0, min(ordered.count - 1, index + delta))]
    }

    func retainReferenceQuery(client: LSPClient, context: EditorRequestContext, isCurrent: @escaping (EditorRequestContext) -> Bool) {
        referenceQuery = (client, context, isCurrent)
    }

    func rerunReferences() {
        guard let query = referenceQuery, query.isCurrent(query.context) else {
            cancelRequest()
            statusMessage = "The original reference query is stale. Run Find References on that symbol again."
            return
        }
        cancelRequest()
        beginLoading()
        let id = queryGeneration
        rerunTask = Task { [weak self] in
            do {
                let locations = try await query.client.references(uri: query.context.document.uri, position: query.context.range.start, includeDeclaration: true)
                guard let self, id == self.queryGeneration, !Task.isCancelled else { return }
                guard query.isCurrent(query.context) else {
                    self.isLoading = false
                    self.statusMessage = "The original reference query is stale. Run Find References on that symbol again."
                    return
                }
                self.replaceResults(locations.map { .init(document: .init(host: query.context.document.host, worktreeID: query.context.document.worktreeID, uri: $0.uri), position: $0.range.start) })
            } catch {
                guard let self, id == self.queryGeneration, !Task.isCancelled else { return }
                self.fail(error)
            }
        }
    }

    func cancelRequest() {
        queryGeneration = UUID()
        rerunTask?.cancel()
        rerunTask = nil
        cancelRequestHandler?()
        cancelLoading()
    }

    func showUnavailable(_ message: String) {
        isLoading = false
        errorMessage = message
    }

    init(openBuffer: @escaping (EditorDocumentID) -> EditorBuffer? = { _ in nil },
         snippetReader: @escaping SnippetReader = { document, limit in await EditorNavigationStore.readSnippetDocument(document, limit: limit) }) {
        self.openBuffer = openBuffer
        self.snippetReader = snippetReader
    }

    var groupedResults: [EditorDocumentID: [EditorNavigationTarget]] {
        Dictionary(grouping: results, by: \.document)
    }

    func beginLoading() {
        queryGeneration = UUID()
        rerunTask?.cancel()
        rerunTask = nil
        invalidateSnippets()
        isLoading = true
        errorMessage = nil
        statusMessage = nil
        isPresented = true
    }

    func replaceResults(_ targets: [EditorNavigationTarget]) {
        var seen = Set<EditorNavigationTarget>()
        results = targets.filter { seen.insert($0).inserted }
        selectedResult = orderedResults.first
        invalidateSnippets()
        isLoading = false
        errorMessage = nil
        statusMessage = nil
        resultsAreStale = false
        isPresented = true
    }

    func markResultsStale() {
        guard !results.isEmpty else { return }
        resultsAreStale = true
        invalidateSnippets()
    }

    func recordJump(from source: EditorNavigationTarget, to destination: EditorNavigationTarget) {
        guard source != destination else { return }

        if let historyIndex, history.indices.contains(historyIndex), history[historyIndex] == source {
            history.removeSubrange((historyIndex + 1) ..< history.endIndex)
        } else {
            history.removeAll()
            history.append(source)
        }
        history.append(destination)
        trimHistory()
        historyIndex = history.indices.last
        pendingHistoryActivation = nil
        statusMessage = nil
        onHistoryChange?()
    }

    var canGoBack: Bool {
        guard let historyIndex else { return false }
        return historyIndex > history.startIndex
    }

    var canGoForward: Bool {
        guard let historyIndex else { return false }
        return historyIndex < history.index(before: history.endIndex)
    }

    func goBack() -> EditorNavigationTarget? {
        guard let historyIndex, historyIndex > history.startIndex else { return nil }
        let nextIndex = historyIndex - 1
        pendingHistoryActivation = (from: historyIndex, to: nextIndex)
        self.historyIndex = nextIndex
        onHistoryChange?()
        return history[nextIndex]
    }

    func goForward() -> EditorNavigationTarget? {
        guard let historyIndex, historyIndex < history.index(before: history.endIndex) else { return nil }
        let nextIndex = historyIndex + 1
        pendingHistoryActivation = (from: historyIndex, to: nextIndex)
        self.historyIndex = nextIndex
        onHistoryChange?()
        return history[nextIndex]
    }

    func confirmHistoryActivation() {
        pendingHistoryActivation = nil
        statusMessage = nil
        onHistoryChange?()
    }

    func recordActivationFailure(for target: EditorNavigationTarget) {
        statusMessage = "Could not open navigation target"
        if let pendingHistoryActivation,
           history.indices.contains(pendingHistoryActivation.to),
           history[pendingHistoryActivation.to] == target {
            historyIndex = pendingHistoryActivation.from
        }
        pendingHistoryActivation = nil
        onHistoryChange?()
    }

    func setHistoryChangeHandler(_ handler: @escaping () -> Void) {
        onHistoryChange = handler
    }

    func beginSnippetSession() -> UUID {
        let id = UUID()
        snippetSessions[id] = []
        return id
    }

    func endSnippetSession(_ id: UUID) {
        let targets = snippetSessions.removeValue(forKey: id) ?? []
        for target in targets { releaseUndemandedSnippet(target) }
    }

    func loadSnippet(for target: EditorNavigationTarget, session: UUID? = nil) {
        if let session {
            guard snippetSessions[session] != nil else { return }
            snippetSessions[session]?.insert(target)
        } else {
            guard results.contains(target) else { return }
            referenceSnippetTargets.insert(target)
        }
        visibleSnippetTargets.insert(target)
        let document = target.document
        if snippetCacheOrder.contains(document) {
            let buffer = openBuffer(document)
            if buffer?.editGeneration != snippetBufferGenerations[document] || buffer.map(ObjectIdentifier.init) != snippetBufferIdentities[document] {
                evictSnippet(document)
                snippets = snippets.filter { $0.key.document != document }
            }
        }
        guard snippets[target] == nil else { return }
        if let cached = cachedSnippetDocuments[document] {
            snippets[target] = cached.line(target.position.line)
        } else if unavailableSnippetDocuments.contains(document) {
            snippets[target] = "Snippet unavailable"
        } else if activeSnippetDocuments[document] == nil, !pendingSnippetDocuments.contains(document), pendingSnippetDocuments.count < 64 {
            pendingSnippetDocuments.append(document)
            startSnippetLoads()
        }
    }

    func releaseSnippet(for target: EditorNavigationTarget, session: UUID? = nil) {
        if let session { snippetSessions[session]?.remove(target) }
        else { referenceSnippetTargets.remove(target) }
        releaseUndemandedSnippet(target)
    }

    private func releaseUndemandedSnippet(_ target: EditorNavigationTarget) {
        guard !referenceSnippetTargets.contains(target), !snippetSessions.values.contains(where: { $0.contains(target) }) else { return }
        visibleSnippetTargets.remove(target)
        snippets.removeValue(forKey: target)
        if !visibleSnippetTargets.contains(where: { $0.document == target.document }) {
            pendingSnippetDocuments.removeAll { $0 == target.document }
        }
    }

    private func invalidateSnippets() {
        snippetGeneration = UUID()
        snippets.removeAll()
        visibleSnippetTargets.removeAll()
        referenceSnippetTargets.removeAll()
        for id in snippetSessions.keys { snippetSessions[id] = [] }
        pendingSnippetDocuments.removeAll()
        cachedSnippetDocuments.removeAll()
        unavailableSnippetDocuments.removeAll()
        snippetCacheOrder.removeAll()
        snippetBufferGenerations.removeAll()
        snippetBufferIdentities.removeAll()
        retainedSnippetBytes = 0
        // Keep active slots until their bounded IO actually finishes. Cancelling
        // a Task alone does not end a FileHandle read or release its allocation.
        activeSnippetDocuments.values.forEach { $0.cancel() }
        snippetRevision &+= 1
    }

    private func startSnippetLoads() {
        while activeSnippetDocuments.count < 4, !pendingSnippetDocuments.isEmpty {
            let document = pendingSnippetDocuments.removeFirst()
            let generation = snippetGeneration
            let reader = snippetReader
            let buffer = openBuffer(document)
            let sourceGeneration = buffer?.editGeneration
            // Open source already exists. Copy only a bounded snapshot and never
            // ask disk for an open document, including dirty and unloaded buffers.
            let openText: String?
            if let buffer, buffer.initialLoadFinished, buffer.storage.length <= Self.documentByteLimit / 4 {
                openText = buffer.storage.mutableString.substring(with: NSRange(location: 0, length: buffer.storage.length))
            } else { openText = nil }
            let isOpen = buffer != nil
            activeSnippetDocuments[document] = Task { [weak self, weak buffer] in
                let snapshot = await Task.detached(priority: .utility) {
                    let text: String?
                    if isOpen { text = openText }
                    else { text = await reader(document, Self.documentByteLimit) }
                    guard let text, text.utf8.count <= Self.documentByteLimit else { return Optional<NavigationSnippetSnapshot>.none }
                    return NavigationSnippetSnapshot(text)
                }.value
                guard let self else { return }
                self.activeSnippetDocuments.removeValue(forKey: document)
                if generation == self.snippetGeneration,
                   (isOpen ? buffer != nil && buffer?.editGeneration == sourceGeneration && self.openBuffer(document) === buffer : self.openBuffer(document) == nil) {
                    self.cacheSnippet(snapshot, document: document)
                    self.snippetBufferGenerations[document] = sourceGeneration
                    self.snippetBufferIdentities[document] = buffer.map(ObjectIdentifier.init)
                    for target in self.visibleSnippetTargets where target.document == document {
                        self.snippets[target] = snapshot?.line(target.position.line) ?? "Snippet unavailable"
                    }
                }
                self.snippetRevision &+= 1
                self.startSnippetLoads()
            }
        }
    }

    private func cacheSnippet(_ snapshot: NavigationSnippetSnapshot?, document: EditorDocumentID) {
        let bytes = snapshot?.byteCount ?? 0
        while !snippetCacheOrder.isEmpty && (snippetCacheOrder.count >= 64 || retainedSnippetBytes + bytes > Self.retainedByteLimit) {
            evictSnippet(snippetCacheOrder[0])
        }
        snippetCacheOrder.append(document)
        if let snapshot { cachedSnippetDocuments[document] = snapshot
            retainedSnippetBytes += bytes
        } else { unavailableSnippetDocuments.insert(document) }
    }

    private func evictSnippet(_ document: EditorDocumentID) {
        snippetCacheOrder.removeAll { $0 == document }
        retainedSnippetBytes -= cachedSnippetDocuments.removeValue(forKey: document)?.byteCount ?? 0
        unavailableSnippetDocuments.remove(document)
        snippetBufferGenerations.removeValue(forKey: document)
        snippetBufferIdentities.removeValue(forKey: document)
    }

    nonisolated static func readSnippetDocument(_ document: EditorDocumentID, limit: Int) async -> String? {
        guard let url = URL(string: document.uri), url.isFileURL else { return nil }
        let data: Data?
        if let host = document.host {
            data = try? await RemoteFileAccess.readPrefix(host: host, path: url.path, maxBytes: limit + 1)
        } else {
            // This reader runs in the detached load task. The size check avoids
            // oversized allocation; the capped read also covers growth races.
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.intValue <= limit,
                  let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            data = try? handle.read(upToCount: limit + 1)
        }
        guard let data, data.count <= limit else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func fail(_ error: Error) {
        results = []
        isLoading = false
        errorMessage = error.localizedDescription
        statusMessage = nil
        isPresented = true
    }

    func cancelLoading() {
        isLoading = false
    }

    func close() {
        cancelRequest()
        invalidateSnippets()
        isPresented = false
        isLoading = false
        errorMessage = nil
        statusMessage = nil
    }

    private static func url(for target: EditorNavigationTarget) -> URL {
        URL(string: target.document.uri)
            ?? URL(fileURLWithPath: target.document.uri.removingPercentEncoding ?? target.document.uri)
    }

    private func trimHistory() {
        guard history.count > Self.historyLimit else { return }
        history.removeFirst(history.count - Self.historyLimit)
    }
}
