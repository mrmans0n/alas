import Foundation

@MainActor
protocol WorkspaceEditFileAccess {
    func snapshot(_ document: EditorDocumentID) async throws -> WorkspaceFileSnapshot
    func replace(_ before: WorkspaceFileSnapshot, with after: WorkspaceFileSnapshot) async throws
    func move(from: EditorDocumentID, to: EditorDocumentID, expectedSource: WorkspaceFileSnapshot, expectedDestination: WorkspaceFileSnapshot) async throws
}

enum WorkspaceEditAccessError: LocalizedError {
    case conflict(EditorDocumentID)
    case unsupportedTarget(EditorDocumentID)
    case ambiguousMutation(EditorDocumentID)

    var errorDescription: String? {
        switch self {
        case .conflict: return "A workspace edit target changed. No conflicting content was overwritten."
        case .unsupportedTarget: return "This workspace edit path is unsupported. Targets must use the worktree's exact canonical path spelling; aliases such as /tmp versus /private/tmp are not supported."
        case .ambiguousMutation: return "The workspace edit result could not be confirmed. Explicit recovery is required."
        }
    }
}

struct WorkspaceEditBufferGeneration: Equatable {
    let identity: ObjectIdentifier
    let edit: Int
    let watch: Int

    init(identity: ObjectIdentifier, edit: Int, watch: Int) {
        self.identity = identity
        self.edit = edit
        self.watch = watch
    }

    @MainActor init(_ buffer: EditorBuffer) {
        identity = ObjectIdentifier(buffer)
        edit = buffer.editGeneration
        watch = buffer.fileWatchGeneration
    }
}

/// A descriptor fingerprint also detects replacement or modification while a
/// bounded read is in flight. Final path checks still have an external-writer race.
struct WorkspaceEditLocalSnapshot: Sendable {
    struct Fingerprint: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let mode: mode_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ value: stat) {
            device = value.st_dev
            inode = value.st_ino
            size = value.st_size
            mode = value.st_mode
            modifiedSeconds = value.st_mtimespec.tv_sec
            modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec
            changedNanoseconds = value.st_ctimespec.tv_nsec
        }
    }

    let snapshot: WorkspaceFileSnapshot
    let fingerprint: Fingerprint?

    static func fingerprint(at url: URL) throws -> Fingerprint? {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return Fingerprint(value)
    }

    func revalidate(at url: URL) throws {
        guard try Self.fingerprint(at: url) == fingerprint else { throw WorkspaceEditAccessError.conflict(snapshot.document) }
    }

    static func read(_ url: URL, _ document: EditorDocumentID) throws -> Self {
        guard let before = try fingerprint(at: url) else {
            return Self(snapshot: WorkspaceFileSnapshot(document: document, content: nil), fingerprint: nil)
        }
        guard before.mode & S_IFMT == S_IFREG else { throw WorkspaceEditAccessError.unsupportedTarget(document) }
        try WorkspaceEditSnapshotBudget.validateSize(Int(before.size))
        // O_NONBLOCK prevents a replaced FIFO from blocking open before fstat.
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var value = stat()
        guard fstat(descriptor, &value) == 0, Fingerprint(value) == before else { throw WorkspaceEditAccessError.conflict(document) }
        var data = Data()
        let cap = WorkspaceEditSnapshotBudget.fileBytes + 1
        while data.count < cap {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: min(64 * 1024, cap - data.count)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        try WorkspaceEditSnapshotBudget.validateSize(data.count)
        guard fstat(descriptor, &value) == 0, Fingerprint(value) == before else { throw WorkspaceEditAccessError.conflict(document) }
        let result = Self(snapshot: WorkspaceFileSnapshot(document: document, content: data, permissions: Int(before.mode & 0o7777)), fingerprint: before)
        try result.revalidate(at: url)
        return result
    }
}

/// Local replacements use a same-directory temporary and preserve permissions.
/// Content guards cannot close the final check-to-rename race with unrelated
/// writers. Neither local filesystems nor SSH provide a multi-file transaction.
@MainActor
final class HostWorkspaceEditFileAccess: WorkspaceEditFileAccess {
    private let tabs: TabsManager
    private let rootForDocument: (EditorDocumentID) -> URL?
    private let localRead: @Sendable (URL, EditorDocumentID) throws -> WorkspaceEditLocalSnapshot

    init(tabs: TabsManager,
         localRead: @escaping @Sendable (URL, EditorDocumentID) throws -> WorkspaceEditLocalSnapshot = { try WorkspaceEditLocalSnapshot.read($0, $1) },
         rootForDocument: @escaping (EditorDocumentID) -> URL?) {
        self.tabs = tabs
        self.localRead = localRead
        self.rootForDocument = rootForDocument
    }

    func validateRequestGenerations(_ generations: [EditorDocumentID: WorkspaceEditBufferGeneration]) throws {
        for (document, expected) in generations {
            guard let buffer = tabs.workspaceEditBuffer(for: document), WorkspaceEditBufferGeneration(buffer) == expected else {
                throw WorkspaceEditAccessError.conflict(document)
            }
        }
    }

    func snapshot(_ document: EditorDocumentID) async throws -> WorkspaceFileSnapshot {
        let buffer = tabs.workspaceEditBuffer(for: document)
        let generation = buffer.map(WorkspaceEditBufferGeneration.init)
        await buffer?.awaitWorkspaceEditLifecycle()
        guard tabs.workspaceEditBuffer(for: document) === buffer,
              buffer.map(WorkspaceEditBufferGeneration.init) == generation else { throw WorkspaceEditAccessError.conflict(document) }
        let disk = try await diskSnapshot(document)
        guard tabs.workspaceEditBuffer(for: document) === buffer,
              buffer.map(WorkspaceEditBufferGeneration.init) == generation else { throw WorkspaceEditAccessError.conflict(document) }
        guard let buffer else { return disk }
        guard buffer.initialLoadFinished, buffer.loadKind == .loaded else { throw WorkspaceEditAccessError.unsupportedTarget(document) }
        try WorkspaceEditSnapshotBudget.validateSize(buffer.storage.length)
        let content = try WorkspaceEditSnapshotBudget.data(buffer.storage.string)
        let original = try WorkspaceEditSnapshotBudget.data(buffer.originalText)
        return WorkspaceFileSnapshot(
            document: document, content: buffer.workspaceEditDeleted ? nil : content,
            bufferVersion: tabs.workspaceEditVersion(for: document, buffer: buffer),
            isOpen: true, isDirty: buffer.dirty, isDirectory: disk.isDirectory, isSymbolicLink: disk.isSymbolicLink,
            diskContent: disk.content, originalContent: original, permissions: disk.permissions,
            bufferGeneration: buffer.editGeneration, fileWatchGeneration: buffer.fileWatchGeneration,
            tombstoneContent: buffer.workspaceEditDeleted ? content : nil
        )
    }

    func replace(_ before: WorkspaceFileSnapshot, with after: WorkspaceFileSnapshot) async throws {
        guard before.document == after.document else { throw WorkspaceEditAccessError.unsupportedTarget(before.document) }
        let document = before.document
        let buffer = tabs.workspaceEditBuffer(for: document)
        if let buffer, buffer.readOnly || buffer.isExternal && !buffer.externalEditable {
            throw WorkspaceEditAccessError.unsupportedTarget(document)
        }
        let current = try await snapshot(document)
        guard WorkspaceEditExecutor.matches(current, before), tabs.workspaceEditBuffer(for: document) === buffer else {
            throw WorkspaceEditAccessError.conflict(document)
        }
        try validateRegular(current)
        try buffer?.beginWorkspaceEditMutation()
        defer { buffer?.endWorkspaceEditMutation() }
        if let buffer, before.content != nil, after.content != nil {
            try buffer.applyWorkspaceEditContent(after.content, expectedGeneration: current.bufferGeneration!)
            return
        }
        // Open deletion/restoration changes the disk as well as the buffer's
        // tombstone. The journal retains both unsaved bytes and disk bytes.
        let diskBefore = WorkspaceFileSnapshot(document: document, content: current.isOpen ? current.diskContent : current.content, permissions: current.permissions)
        // Simulated ownership may describe an earlier resource location. Only
        // an actual buffer at this URI owns a separate saved disk baseline.
        let diskAfter = WorkspaceFileSnapshot(document: document, content: buffer != nil ? after.diskContent : after.content, permissions: after.permissions)
        let effectiveAfter = after.content == nil ? diskAfter.replacing(content: nil) : diskAfter
        let modifiedAt = try await replaceDisk(diskBefore, with: effectiveAfter) {
            guard self.tabs.workspaceEditBuffer(for: document) === buffer,
                  buffer?.editGeneration == current.bufferGeneration,
                  buffer?.fileWatchGeneration == current.fileWatchGeneration else { throw WorkspaceEditAccessError.conflict(document) }
        }
        guard tabs.workspaceEditBuffer(for: document) === buffer,
              buffer?.editGeneration == current.bufferGeneration else { throw WorkspaceEditAccessError.conflict(document) }
        if let buffer {
            try buffer.applyWorkspaceEditContent(after.content, expectedGeneration: current.bufferGeneration!)
            if after.content != nil { buffer.refreshWorkspaceEditDiskMetadata(modifiedAt: modifiedAt) }
        }
    }

    func move(from: EditorDocumentID, to: EditorDocumentID, expectedSource: WorkspaceFileSnapshot, expectedDestination: WorkspaceFileSnapshot) async throws {
        guard from.host == to.host, from.worktreeID == to.worktreeID,
              expectedSource.document == from, expectedDestination.document == to else { throw WorkspaceEditAccessError.unsupportedTarget(from) }
        let sourceBuffer = tabs.workspaceEditBuffer(for: from)
        // Replacing a separately open destination would merge two owners.
        // Refuse until the editor has an explicit owner-transfer contract.
        guard tabs.workspaceEditBuffer(for: to) == nil, sourceBuffer?.isExternal != true else { throw WorkspaceEditAccessError.unsupportedTarget(to) }
        let source = try await snapshot(from)
        let destination = try await snapshot(to)
        guard WorkspaceEditExecutor.matches(source, expectedSource), WorkspaceEditExecutor.matches(destination, expectedDestination),
              tabs.workspaceEditBuffer(for: from) === sourceBuffer,
              tabs.workspaceEditBuffer(for: to) == nil,
              sourceBuffer?.fileWatchGeneration == source.fileWatchGeneration,
              sourceBuffer?.editGeneration == source.bufferGeneration else { throw WorkspaceEditAccessError.conflict(from) }
        try validateRegular(source)
        try validateRegular(destination)
        try sourceBuffer?.beginWorkspaceEditMutation()
        defer { sourceBuffer?.endWorkspaceEditMutation() }
        let sourceURL = try validatedURL(from)
        let destinationURL = try validatedURL(to)
        let sourceDisk = source.isOpen ? source.diskContent : source.content
        guard let sourceDisk else { throw WorkspaceEditAccessError.unsupportedTarget(from) }
        func revalidateBuffer() throws {
            guard tabs.workspaceEditBuffer(for: from) === sourceBuffer,
                  tabs.workspaceEditBuffer(for: to) == nil,
                  sourceBuffer?.editGeneration == source.bufferGeneration,
                  sourceBuffer?.fileWatchGeneration == source.fileWatchGeneration else { throw WorkspaceEditAccessError.conflict(from) }
        }
        if let host = from.host {
            try await executeRemote(host: host, document: from, command: RemoteFileOps.guardedMoveCommand(
                from: sourceURL.path, to: destinationURL.path, expectedSource: sourceDisk, expectedDestination: destination.content
            ))
        } else {
            let checkedSource = try await localSnapshot(from)
            try revalidateBuffer()
            let checkedDestination = try await localSnapshot(to)
            try revalidateBuffer()
            guard checkedSource.snapshot.content == sourceDisk,
                  checkedDestination.snapshot.content == destination.content else { throw WorkspaceEditAccessError.conflict(from) }
            try checkedSource.revalidate(at: validatedURL(from))
            try checkedDestination.revalidate(at: validatedURL(to))
            guard Darwin.rename(sourceURL.path, destinationURL.path) == 0 else { throw POSIXError(.EIO) }
        }
        guard tabs.workspaceEditBuffer(for: from) === sourceBuffer,
              tabs.workspaceEditBuffer(for: to) == nil,
              sourceBuffer?.editGeneration == source.bufferGeneration else { throw WorkspaceEditAccessError.conflict(from) }
        if let sourceBuffer { try sourceBuffer.rebindWorkspaceEdit(to: to, expectedGeneration: source.bufferGeneration!) }
    }

    private func diskSnapshot(_ document: EditorDocumentID) async throws -> WorkspaceFileSnapshot {
        let url = try validatedURL(document)
        guard let host = document.host else { return try await localSnapshot(document).snapshot }
        guard let root = rootForDocument(document) else { throw WorkspaceEditAccessError.unsupportedTarget(document) }
        try await RemotePathContainment.verifyRemoteContainment(host: host, path: url.path, worktreeRoot: root.path)
        let result: RemoteReadResult
        do { result = try await RemoteFileAccess.read(host: host, path: url.path, maxBytes: WorkspaceEditSnapshotBudget.fileBytes) }
        catch RemoteFileAccessError.fileTooLarge { throw WorkspaceEditSnapshotBudget.Error.oversizedFile }
        switch result {
        case .file(let data, _):
            let permissions = try await RemoteFileAccess.permissions(host: host, path: url.path)
            return WorkspaceFileSnapshot(document: document, content: data, permissions: permissions)
        case .missing: return WorkspaceFileSnapshot(document: document, content: nil)
        case .directory: throw WorkspaceEditAccessError.unsupportedTarget(document)
        case .symlink: throw WorkspaceEditAccessError.unsupportedTarget(document)
        case .unreadable: throw WorkspaceEditAccessError.unsupportedTarget(document)
        }
    }

    private func localSnapshot(_ document: EditorDocumentID) async throws -> WorkspaceEditLocalSnapshot {
        let url = try validatedURL(document)
        let read = localRead
        let result = try await Task.detached { try read(url, document) }.value
        try Task.checkCancellation()
        return result
    }

    private func replaceDisk(_ before: WorkspaceFileSnapshot, with after: WorkspaceFileSnapshot, revalidateBuffer: @MainActor () throws -> Void) async throws -> Date? {
        let document = before.document
        let url = try validatedURL(document)
        let checkedLocal = document.host == nil ? try await localSnapshot(document) : nil
        let current: WorkspaceFileSnapshot
        if let checkedLocal { current = checkedLocal.snapshot }
        else { current = try await diskSnapshot(document) }
        guard current.content == before.content else { throw WorkspaceEditAccessError.conflict(document) }
        try revalidateBuffer()
        if let host = document.host {
            if let content = after.content, let expected = before.content,
               let text = String(data: content, encoding: .utf8), let expectedText = String(data: expected, encoding: .utf8) {
                return try await RemoteFileAccess.write(host: host, path: url.path, content: text, expectedContent: expectedText, revalidateBeforeWrite: revalidateBuffer)
            } else {
                let text = after.content.flatMap { String(data: $0, encoding: .utf8) }
                guard after.content == nil || text != nil else { throw WorkspaceEditAccessError.unsupportedTarget(document) }
                let output = try await executeRemote(host: host, document: document, command: RemoteFileOps.guardedReplaceCommand(path: url.path, expected: before.content, replacement: after.content, permissions: after.permissions), input: text)
                return TimeInterval(output.trimmingCharacters(in: .whitespacesAndNewlines)).map(Date.init(timeIntervalSince1970:))
            }
        }
        guard let content = after.content else {
            try checkedLocal?.revalidate(at: validatedURL(document))
            if before.content != nil { try FileManager.default.removeItem(at: url) }
            return nil
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".alas-workspace-edit-\(UUID()).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: content, attributes: [.posixPermissions: after.permissions ?? before.permissions ?? 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let checked = try await localSnapshot(document)
        try revalidateBuffer()
        guard checked.snapshot.content == before.content else { throw WorkspaceEditAccessError.conflict(document) }
        try checked.revalidate(at: validatedURL(document))
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw POSIXError(.EIO) }
        return (try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    @discardableResult
    private func executeRemote(host: String, document: EditorDocumentID, command: String, input: String? = nil) async throws -> String {
        let invocation = RemoteExec.invocation(host: host, cwd: nil, command: command)
        let result = try await Process.run(invocation.executable, args: invocation.args, stdin: input, timeout: 60)
        guard result.exitCode == 0 else {
            if result.exitCode == 42 { throw WorkspaceEditAccessError.conflict(document) }
            throw WorkspaceEditAccessError.ambiguousMutation(document)
        }
        return result.stdout
    }

    private func validatedURL(_ document: EditorDocumentID) throws -> URL {
        guard let url = URL(string: document.uri), url.isFileURL,
              url.host == nil || url.host == "" || url.host == "localhost",
              let root = rootForDocument(document), url.standardizedFileURL == url,
              url.path.hasPrefix(root.standardizedFileURL.path + "/"),
              !url.pathComponents.contains(where: { $0.lowercased() == ".git" }) else { throw WorkspaceEditAccessError.unsupportedTarget(document) }
        if document.host == nil {
            let relative = String(url.path.dropFirst(root.standardizedFileURL.path.count))
            guard url.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path + relative else {
                throw WorkspaceEditAccessError.unsupportedTarget(document)
            }
        }
        return url
    }

    private func validateRegular(_ snapshot: WorkspaceFileSnapshot) throws {
        guard !snapshot.isDirectory, !snapshot.isSymbolicLink else { throw WorkspaceEditAccessError.unsupportedTarget(snapshot.document) }
    }
}
