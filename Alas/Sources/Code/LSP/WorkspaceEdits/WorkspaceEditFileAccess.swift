import Foundation

@MainActor
protocol WorkspaceEditFileAccess {
    func snapshot(_ document: EditorDocumentID) async throws -> WorkspaceFileSnapshot
    func replace(_ before: WorkspaceFileSnapshot, with after: WorkspaceFileSnapshot) async throws
    func move(from: EditorDocumentID, to: EditorDocumentID, expectedSource: WorkspaceFileSnapshot, expectedDestination: WorkspaceFileSnapshot) async throws
}

enum WorkspaceEditAccessError: Error {
    case conflict(EditorDocumentID)
    case unsupportedTarget(EditorDocumentID)
    case ambiguousMutation(EditorDocumentID)
}

struct WorkspaceEditBufferGeneration: Equatable {
    let identity: ObjectIdentifier
    let edit: Int
    let watch: Int

    @MainActor init(_ buffer: EditorBuffer) {
        identity = ObjectIdentifier(buffer)
        edit = buffer.editGeneration
        watch = buffer.fileWatchGeneration
    }
}

/// Local replacements use a same-directory temporary and preserve permissions.
/// Content guards cannot close the final check-to-rename race with unrelated
/// writers. Neither local filesystems nor SSH provide a multi-file transaction.
@MainActor
final class HostWorkspaceEditFileAccess: WorkspaceEditFileAccess {
    private let tabs: TabsManager
    private let rootForDocument: (EditorDocumentID) -> URL?

    init(tabs: TabsManager, rootForDocument: @escaping (EditorDocumentID) -> URL?) {
        self.tabs = tabs
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
        return WorkspaceFileSnapshot(
            document: document, content: buffer.workspaceEditDeleted ? nil : Data(buffer.storage.string.utf8),
            bufferVersion: tabs.workspaceEditVersion(for: document, buffer: buffer),
            isOpen: true, isDirty: buffer.dirty, isDirectory: disk.isDirectory, isSymbolicLink: disk.isSymbolicLink,
            diskContent: disk.content, originalContent: Data(buffer.originalText.utf8), permissions: disk.permissions,
            bufferGeneration: buffer.editGeneration, fileWatchGeneration: buffer.fileWatchGeneration
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
        let diskBefore = WorkspaceFileSnapshot(document: document, content: before.isOpen ? before.diskContent : before.content, permissions: before.permissions)
        let diskAfter = WorkspaceFileSnapshot(document: document, content: after.isOpen ? after.diskContent : after.content, permissions: after.permissions)
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
        if let host = from.host {
            try await executeRemote(host: host, document: from, command: RemoteFileOps.guardedMoveCommand(
                from: sourceURL.path, to: destinationURL.path, expectedSource: sourceDisk, expectedDestination: destination.content
            ))
        } else {
            guard try localSnapshot(from).content == sourceDisk,
                  try localSnapshot(to).content == destination.content else { throw WorkspaceEditAccessError.conflict(from) }
            guard Darwin.rename(sourceURL.path, destinationURL.path) == 0 else { throw POSIXError(.EIO) }
        }
        guard tabs.workspaceEditBuffer(for: from) === sourceBuffer,
              tabs.workspaceEditBuffer(for: to) == nil,
              sourceBuffer?.editGeneration == source.bufferGeneration else { throw WorkspaceEditAccessError.conflict(from) }
        if let sourceBuffer { try sourceBuffer.rebindWorkspaceEdit(to: to, expectedGeneration: source.bufferGeneration!) }
    }

    private func diskSnapshot(_ document: EditorDocumentID) async throws -> WorkspaceFileSnapshot {
        let url = try validatedURL(document)
        guard let host = document.host else { return try localSnapshot(document) }
        guard let root = rootForDocument(document) else { throw WorkspaceEditAccessError.unsupportedTarget(document) }
        try await RemotePathContainment.verifyRemoteContainment(host: host, path: url.path, worktreeRoot: root.path)
        switch try await RemoteFileAccess.read(host: host, path: url.path) {
        case .file(let data, _):
            let permissions = try await RemoteFileAccess.permissions(host: host, path: url.path)
            return WorkspaceFileSnapshot(document: document, content: data, permissions: permissions)
        case .missing: return WorkspaceFileSnapshot(document: document, content: nil)
        case .directory: throw WorkspaceEditAccessError.unsupportedTarget(document)
        case .symlink: throw WorkspaceEditAccessError.unsupportedTarget(document)
        case .unreadable: throw WorkspaceEditAccessError.unsupportedTarget(document)
        }
    }

    private func localSnapshot(_ document: EditorDocumentID) throws -> WorkspaceFileSnapshot {
        let url = try validatedURL(document)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw WorkspaceEditAccessError.unsupportedTarget(document) }
            return WorkspaceFileSnapshot(document: document, content: try Data(contentsOf: url), permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return WorkspaceFileSnapshot(document: document, content: nil)
        }
    }

    private func replaceDisk(_ before: WorkspaceFileSnapshot, with after: WorkspaceFileSnapshot, revalidateBuffer: @MainActor () throws -> Void) async throws -> Date? {
        let document = before.document
        let url = try validatedURL(document)
        guard try await diskSnapshot(document).content == before.content else { throw WorkspaceEditAccessError.conflict(document) }
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
            if before.content != nil { try FileManager.default.removeItem(at: url) }
            return nil
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".alas-workspace-edit-\(UUID()).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: content, attributes: [.posixPermissions: after.permissions ?? before.permissions ?? 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard try localSnapshot(document).content == before.content else { throw WorkspaceEditAccessError.conflict(document) }
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
