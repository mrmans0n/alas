import Foundation
import Observation

private actor EditorNavigationSnippetLimiter {
    static let shared = EditorNavigationSnippetLimiter(limit: 4)

    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        guard active >= limit else {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            active -= 1
        }
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
    private var loadingSnippets = Set<EditorNavigationTarget>()
    private let snippetCache = DefinitionSnippetCache()
    private var history: [EditorNavigationTarget] = []
    private var historyIndex: Int?
    private var pendingHistoryActivation: (from: Int, to: Int)?
    private var onHistoryChange: (() -> Void)?

    var groupedResults: [EditorDocumentID: [EditorNavigationTarget]] {
        Dictionary(grouping: results, by: \.document)
    }

    func beginLoading() {
        snippets = [:]
        loadingSnippets = []
        isLoading = true
        errorMessage = nil
        statusMessage = nil
        resultsAreStale = false
        isPresented = true
    }

    func replaceResults(_ targets: [EditorNavigationTarget]) {
        var seen = Set<EditorNavigationTarget>()
        results = targets.filter { seen.insert($0).inserted }
        snippets = [:]
        loadingSnippets = []
        isLoading = false
        errorMessage = nil
        statusMessage = nil
        resultsAreStale = false
        isPresented = true
    }

    func markResultsStale() {
        guard !results.isEmpty else { return }
        resultsAreStale = true
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

    func loadSnippet(for target: EditorNavigationTarget) {
        guard snippets[target] == nil, loadingSnippets.insert(target).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            await EditorNavigationSnippetLimiter.shared.acquire()
            let contents: String
            let freshness: Date?
            if let host = target.document.host {
                switch try? await RemoteFileAccess.read(host: host, path: Self.url(for: target).path) {
                case .file(let data, let mtime):
                    contents = String(decoding: data, as: UTF8.self)
                    freshness = mtime
                default:
                    contents = ""
                    freshness = nil
                }
            } else {
                let url = Self.url(for: target)
                contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                freshness = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? nil
            }
            await EditorNavigationSnippetLimiter.shared.release()
            snippets[target] = snippetCache.line(
                host: target.document.host,
                uri: target.document.uri,
                freshness: freshness,
                contents: contents,
                line: target.position.line
            )
            loadingSnippets.remove(target)
        }
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
