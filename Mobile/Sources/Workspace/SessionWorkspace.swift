import AlasRemoteKit
import Foundation
import Observation

enum Load<T> {
    case idle, loading, loaded(T), failed(String)
}

struct DiffKey: Hashable {
    let path: String
    let stage: String?
}

struct ChangeListReply {
    let comparisonRef: String?
    let metricsAvailable: Bool
    let files: [RemoteChangedFile]
    let staged: [RemoteChangedFile]
    let unstaged: [RemoteChangedFile]
    let commits: [RemoteCommit]
    let truncated: Bool
    let commitsTruncated: Bool
}

struct DiffReply {
    let hunks: [RemoteDiffHunk]
    let truncated: Bool
    let metadataNote: String?
}

struct FileReply {
    let text: String
    let truncated: Bool
}

/// What one session's Changes and Files tabs show. Lives next to its `TranscriptSession` so a tab
/// switch or a reconnect keeps the open diff and tree. Replies are applied only for this session
/// and, for a diff, only for the key still open.
@MainActor @Observable
final class SessionWorkspace {
    private(set) var changes: Load<ChangeListReply> = .idle
    private(set) var diff: (key: DiffKey, Load<DiffReply>)?
    private(set) var tree = RemoteFileTree()
    private(set) var file: (path: String, Load<FileReply>)?
    /// Directories the host cut short, and the last listing failure.
    private(set) var truncatedDirs: Set<String> = []
    private(set) var treeError: String?
    var error: String?

    let hostID: UUID
    let sessionId: String
    @ObservationIgnored private let hub: HostHub
    @ObservationIgnored private var listener: ListenerToken?
    @ObservationIgnored private var streaming = "idle"
    /// An idle refresh that arrived while a diff was open; it runs when the diff closes.
    @ObservationIgnored private var refreshDeferred = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var watchGeneration = 0
    @ObservationIgnored private var hostWasOnline = false

    init(hub: HostHub, hostID: UUID, sessionId: String) {
        self.hub = hub
        self.hostID = hostID
        self.sessionId = sessionId
    }

    /// True while a view pushed from the session screen (diff; Task 5's file viewer) is open.
    var hasPushedChild: Bool { diff != nil || file != nil }

    // MARK: Lifecycle

    func activate() {
        guard listener == nil else { return }
        listener = hub.addListener(hostID) { [weak self] in self?.receive($0) }
        hostWasOnline = hub.state(of: hostID) == .online
        watchGeneration += 1
        watchHost(generation: watchGeneration)
    }

    func deactivate() {
        listener = nil
        watchGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func watchHost(generation: Int) {
        guard generation == watchGeneration else { return }
        let online = withObservationTracking {
            hub.state(of: hostID) == .online
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.watchHost(generation: generation) }
        }
        defer { hostWasOnline = online }
        if online, !hostWasOnline { replay() }
    }

    /// Asks again for whatever is open; the host forgot everything it was asked while away.
    private func replay() {
        if case .idle = changes {} else { refreshChanges() }
        if let diff { send(.fileDiff(sessionId: sessionId, path: diff.key.path, stage: diff.key.stage)) }
        if !tree.children.isEmpty { loadTree() }
        if let file { openFile(file.path) }
    }

    // MARK: Changes

    func refreshChanges() {
        if case .loaded = changes {} else { changes = .loading }
        send(.listChanges(sessionId: sessionId))
    }

    func openDiff(_ path: String, stage: String?) {
        diff = (DiffKey(path: path, stage: stage), .loading)
        send(.fileDiff(sessionId: sessionId, path: path, stage: stage))
    }

    func closeDiff() {
        diff = nil
        if refreshDeferred { scheduleRefresh() }
    }

    /// Refreshes the list when the agent goes idle, once the Changes tab has been opened.
    func noteStreaming(_ state: String) {
        defer { streaming = state }
        guard state == "idle", streaming != "idle" else { return }
        if case .idle = changes { return }
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard diff == nil else {
            refreshDeferred = true
            return
        }
        refreshDeferred = false
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.refreshChanges()
        }
    }

    // MARK: Files (Task 5)

    func loadTree() {
        send(.listFiles(sessionId: sessionId, path: nil, comparisonMode: nil))
    }

    func toggle(_ dir: String) {
        if tree.expanded.remove(dir) != nil { return }
        tree.expanded.insert(dir)
        if tree.children[dir] == nil { send(.listFiles(sessionId: sessionId, path: dir, comparisonMode: nil)) }
    }

    func openFile(_ path: String) {
        file = (path, .loading)
        send(.readFile(sessionId: sessionId, path: path))
    }

    func closeFile() {
        file = nil
    }

    // MARK: Replies

    private func send(_ message: PhoneClientMessage) {
        hub.send(message, to: hostID)
    }

    private func receive(_ message: PhoneServerMessage) {
        switch message {
        case .changeList(let id, let ref, let metrics, let files, let staged, let unstaged, let commits,
                         let truncated, let commitsTruncated, _, _) where id == sessionId:
            changes = .loaded(ChangeListReply(
                comparisonRef: ref, metricsAvailable: metrics, files: files, staged: staged, unstaged: unstaged,
                commits: commits, truncated: truncated, commitsTruncated: commitsTruncated))
        case .changeListFailed(let id, let reason, let message) where id == sessionId:
            changes = .failed(RemoteChangesRules.accessMessage(reason, message: message, byteSize: nil))
        case .fileDiffResult(let id, let path, let stage, let hunks, let truncated, let note) where id == sessionId:
            guard diff?.key == DiffKey(path: path, stage: stage) else { return }
            diff = (DiffKey(path: path, stage: stage), .loaded(DiffReply(hunks: hunks, truncated: truncated, metadataNote: note)))
        case .fileDiffFailed(let id, let path, let stage, let reason, let message) where id == sessionId:
            guard diff?.key == DiffKey(path: path, stage: stage) else { return }
            diff = (DiffKey(path: path, stage: stage), .failed(RemoteChangesRules.accessMessage(reason, message: message, byteSize: nil)))
        case .fileTree(let id, let path, let nodes, let truncated) where id == sessionId:
            tree.apply(path: path, nodes: nodes)
            treeError = nil
            if truncated { truncatedDirs.insert(path ?? "") } else { truncatedDirs.remove(path ?? "") }
            if path == nil { for dir in tree.pathsToRefresh() { send(.listFiles(sessionId: sessionId, path: dir, comparisonMode: nil)) } }
        case .fileTreeFailed(let id, let path, let reason, let message) where id == sessionId:
            // A directory that failed to list must not stay open and empty.
            if let path, tree.children[path] == nil { tree.expanded.remove(path) }
            treeError = RemoteChangesRules.accessMessage(reason, message: message, byteSize: nil)
        case .fileContents(let id, let path, let text, let truncated, _) where id == sessionId:
            guard file?.path == path else { return }
            file = (path, .loaded(FileReply(text: text, truncated: truncated)))
        case .fileUnavailable(let id, let path, let reason, let byteSize, let message) where id == sessionId:
            guard file?.path == path else { return }
            file = (path, .failed(RemoteChangesRules.accessMessage(reason, message: message, byteSize: byteSize)))
        default:
            break
        }
    }
}
