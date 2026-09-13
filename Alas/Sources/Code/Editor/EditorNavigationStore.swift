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
    private(set) var results: [EditorNavigationTarget] = []
    private(set) var snippets: [EditorNavigationTarget: String] = [:]
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    var isPresented = false
    var isExpanded = true
    var height: CGFloat = 220
    private var loadingSnippets = Set<EditorNavigationTarget>()
    private let snippetCache = DefinitionSnippetCache()

    var groupedResults: [EditorDocumentID: [EditorNavigationTarget]] {
        Dictionary(grouping: results, by: \.document)
    }

    func beginLoading() {
        snippets = [:]
        loadingSnippets = []
        isLoading = true
        errorMessage = nil
        isPresented = true
    }

    func replaceResults(_ targets: [EditorNavigationTarget]) {
        var seen = Set<EditorNavigationTarget>()
        results = targets.filter { seen.insert($0).inserted }
        snippets = [:]
        loadingSnippets = []
        isLoading = false
        errorMessage = nil
        isPresented = true
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
        isPresented = true
    }

    func cancelLoading() {
        isLoading = false
    }

    func close() {
        isPresented = false
        isLoading = false
        errorMessage = nil
    }

    private static func url(for target: EditorNavigationTarget) -> URL {
        URL(string: target.document.uri)
            ?? URL(fileURLWithPath: target.document.uri.removingPercentEncoding ?? target.document.uri)
    }
}
