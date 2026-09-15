import Foundation

/// Transaction limits are separate from the editor's file-open limits.
struct WorkspaceEditSnapshotBudget {
    static let fileBytes = 16 * 1024 * 1024
    static let totalBytes = 64 * 1024 * 1024
    static let targets = 256
    private var retainedBytes = 0

    enum Error: LocalizedError {
        case oversizedFile, totalBytes, targets

        var errorDescription: String? {
            switch self {
            case .oversizedFile: "Workspace edits cannot include a file or snapshot larger than 16 MiB."
            case .totalBytes: "Workspace edit snapshots exceed the 64 MiB operation limit."
            case .targets: "Workspace edits cannot include more than 256 distinct targets."
            }
        }
    }

    static func validateSize(_ bytes: Int) throws {
        guard bytes <= fileBytes else { throw Error.oversizedFile }
    }

    static func validateTargetCount(_ count: Int) throws {
        guard count <= targets else { throw Error.targets }
    }

    static func data(_ text: String) throws -> Data {
        try validateSize(text.utf8.count)
        return Data(text.utf8)
    }

    mutating func retain(_ snapshot: WorkspaceFileSnapshot) throws {
        for data in [snapshot.content, snapshot.diskContent, snapshot.originalContent, snapshot.tombstoneContent].compactMap({ $0 }) {
            try Self.validateSize(data.count)
            guard data.count <= Self.totalBytes - retainedBytes else { throw Error.totalBytes }
            retainedBytes += data.count
        }
    }
}

struct WorkspaceFileSnapshot: Equatable, Sendable, Codable {
    let document: EditorDocumentID
    let content: Data?
    let bufferVersion: Int?
    let isOpen: Bool
    let isDirty: Bool
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let diskContent: Data?
    let originalContent: Data?
    let permissions: Int?
    let bufferGeneration: Int?
    let fileWatchGeneration: Int?
    /// Live storage retained after resource deletion, separate from absent file content.
    let tombstoneContent: Data?

    init(
        document: EditorDocumentID,
        content: Data?,
        bufferVersion: Int? = nil,
        isOpen: Bool = false,
        isDirty: Bool = false,
        isDirectory: Bool = false,
        isSymbolicLink: Bool = false,
        diskContent: Data? = nil,
        originalContent: Data? = nil,
        permissions: Int? = nil,
        bufferGeneration: Int? = nil,
        fileWatchGeneration: Int? = nil,
        tombstoneContent: Data? = nil
    ) {
        self.document = document
        self.content = content
        self.bufferVersion = bufferVersion
        self.isOpen = isOpen
        self.isDirty = isDirty
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.diskContent = diskContent
        self.originalContent = originalContent
        self.permissions = permissions
        self.bufferGeneration = bufferGeneration
        self.fileWatchGeneration = fileWatchGeneration
        self.tombstoneContent = tombstoneContent
    }

    func replacing(document: EditorDocumentID? = nil, content: Data?) -> WorkspaceFileSnapshot {
        WorkspaceFileSnapshot(
            document: document ?? self.document,
            content: content,
            bufferVersion: bufferVersion,
            isOpen: isOpen,
            isDirty: isDirty,
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            diskContent: diskContent,
            originalContent: originalContent,
            permissions: permissions,
            bufferGeneration: bufferGeneration,
            fileWatchGeneration: fileWatchGeneration,
            tombstoneContent: isOpen && content == nil ? tombstoneContent ?? self.content : nil
        )
    }

    func removingResource(keepingBuffer: Bool) -> WorkspaceFileSnapshot {
        guard keepingBuffer, isOpen else { return WorkspaceFileSnapshot(document: document, content: nil) }
        return WorkspaceFileSnapshot(
            document: document, content: nil, bufferVersion: bufferVersion, isOpen: true, isDirty: isDirty,
            originalContent: originalContent, bufferGeneration: bufferGeneration, fileWatchGeneration: fileWatchGeneration,
            tombstoneContent: tombstoneContent ?? content
        )
    }
}

struct WorkspaceEditPlan: Equatable, Sendable {
    let steps: [WorkspaceEditPlanStep]
    let finalSnapshots: [EditorDocumentID: WorkspaceFileSnapshot]
    let reviewAnnotations: [String: LSPChangeAnnotation]
    let warnings: [WorkspaceEditPlanWarning]
    let requiresPreview: Bool
}

struct WorkspaceEditPlanStep: Equatable, Sendable, Codable {
    enum Kind: String, Equatable, Sendable, Codable {
        case text
        case create
        case rename
        case delete
    }

    let kind: Kind
    let document: EditorDocumentID
    let destination: EditorDocumentID?
    let before: WorkspaceFileSnapshot
    let after: WorkspaceFileSnapshot
    let destinationBefore: WorkspaceFileSnapshot?
    let annotationID: String?
    let annotationIDs: [String]
    let resourceOptions: LSPJSONValue?
}

enum WorkspaceEditPlanWarning: Equatable, Sendable {
    case destinationOverwriteWithUnsavedContent(EditorDocumentID)
    case deleteWithUnsavedContent(EditorDocumentID)
}

enum WorkspaceEditPlanner {
    enum Error: Swift.Error, Equatable {
        case staleVersion
        case missingSnapshot
        case malformedRange
        case overlappingEdits
        case unsupportedURI
        case conflictingRepresentations
        case targetAlreadyExists
        case sourceDoesNotExist
        case unboundedDirectoryDelete
        case symbolicLinkAmbiguity
        case nonTextInput
        case unknownAnnotation
        case unsupportedResourceOwnership
    }

    static func plan(
        edit: LSPWorkspaceEdit,
        context: EditorRequestContext,
        snapshots: [EditorDocumentID: WorkspaceFileSnapshot]
    ) throws -> WorkspaceEditPlan {
        try WorkspaceEditSnapshotBudget.validateTargetCount(snapshots.count)
        var budget = WorkspaceEditSnapshotBudget()
        for snapshot in snapshots.values { try budget.retain(snapshot) }
        if let changes = edit.changes, !changes.isEmpty,
           let documentChanges = edit.documentChanges, !documentChanges.isEmpty {
            throw Error.conflictingRepresentations
        }

        let annotations = edit.changeAnnotations ?? [:]
        let changes: [LSPDocumentChange]
        if let documentChanges = edit.documentChanges {
            changes = documentChanges
        } else {
            changes = (edit.changes ?? [:]).keys.sorted().map { uri in
                .textDocument(
                    document: .init(uri: uri, version: nil), edits: edit.changes?[uri] ?? []
                )
            }
        }

        var state = snapshots
        var steps: [WorkspaceEditPlanStep] = []
        var warnings: [WorkspaceEditPlanWarning] = []

        for change in changes {
            switch change {
            case .textDocument(let textDocument, let edits):
                let document = try documentID(for: textDocument.uri, context: context)
                guard let before = state[document], before.content != nil else { throw Error.missingSnapshot }
                try validate(snapshot: before)
                let annotationIDs = Array(Set(edits.compactMap(\.annotationID))).sorted()
                for annotationID in annotationIDs {
                    try validate(annotationID: annotationID, annotations: annotations)
                }
                if let version = textDocument.version, before.bufferVersion != version { throw Error.staleVersion }
                if document == context.document, before.bufferVersion != context.version { throw Error.staleVersion }
                let after = try applying(edits, to: before)
                try budget.retain(after)
                state[document] = after
                steps.append(.init(
                    kind: .text, document: document, destination: nil, before: before, after: after,
                    destinationBefore: nil, annotationID: nil, annotationIDs: annotationIDs, resourceOptions: nil
                ))

            case .create(let uri, let options, let annotationID):
                try validate(annotationID: annotationID, annotations: annotations)
                let document = try documentID(for: uri, context: context)
                guard let before = state[document] else { throw Error.missingSnapshot }
                try validate(snapshot: before)
                let exists = before.content != nil
                if exists && !options.overwrite && !options.ignoreIfExists { throw Error.targetAlreadyExists }
                let after = options.ignoreIfExists && !options.overwrite && exists ? before : before.replacing(content: Data())
                guard !before.isOpen || before.content == after.content else { throw Error.unsupportedResourceOwnership }
                try budget.retain(after)
                state[document] = after
                if exists && options.overwrite && before.isOpen && before.isDirty {
                    warnings.append(.destinationOverwriteWithUnsavedContent(document))
                }
                steps.append(.init(
                    kind: .create, document: document, destination: nil, before: before, after: after,
                    destinationBefore: nil, annotationID: annotationID, annotationIDs: annotationID.map { [$0] } ?? [], resourceOptions: options.jsonValue
                ))

            case .rename(let oldURI, let newURI, let options, let annotationID):
                try validate(annotationID: annotationID, annotations: annotations)
                let source = try documentID(for: oldURI, context: context)
                let destination = try documentID(for: newURI, context: context)
                guard source != destination else { throw Error.sourceDoesNotExist }
                guard let before = state[source], let destinationBefore = state[destination] else { throw Error.missingSnapshot }
                guard before.content != nil else { throw Error.sourceDoesNotExist }
                try validate(snapshot: before)
                try validate(snapshot: destinationBefore)
                let destinationExists = destinationBefore.content != nil
                if destinationExists && !options.overwrite && !options.ignoreIfExists { throw Error.targetAlreadyExists }
                if options.ignoreIfExists && !options.overwrite && destinationExists {
                    try budget.retain(before)
                    steps.append(.init(
                        kind: .rename, document: source, destination: destination, before: before, after: before,
                        destinationBefore: destinationBefore, annotationID: annotationID, annotationIDs: annotationID.map { [$0] } ?? [], resourceOptions: options.jsonValue
                    ))
                    continue
                }
                let destinationAfter = before.replacing(document: destination, content: before.content)
                guard !destinationBefore.isOpen else { throw Error.unsupportedResourceOwnership }
                let sourceAfter = before.removingResource(keepingBuffer: false)
                try budget.retain(destinationAfter)
                state[source] = sourceAfter
                state[destination] = destinationAfter
                if destinationExists && destinationBefore.isOpen && destinationBefore.isDirty {
                    warnings.append(.destinationOverwriteWithUnsavedContent(destination))
                }
                steps.append(.init(
                    kind: .rename, document: source, destination: destination, before: before, after: destinationAfter,
                    destinationBefore: destinationBefore, annotationID: annotationID, annotationIDs: annotationID.map { [$0] } ?? [], resourceOptions: options.jsonValue
                ))

            case .delete(let uri, let options, let annotationID):
                try validate(annotationID: annotationID, annotations: annotations)
                let document = try documentID(for: uri, context: context)
                guard let before = state[document] else { throw Error.missingSnapshot }
                if before.content == nil && !options.ignoreIfNotExists { throw Error.sourceDoesNotExist }
                try validate(snapshot: before)
                if before.isDirectory { throw Error.unboundedDirectoryDelete }
                let after = before.removingResource(keepingBuffer: true)
                try budget.retain(after)
                state[document] = after
                if before.content != nil && before.isOpen && before.isDirty {
                    warnings.append(.deleteWithUnsavedContent(document))
                }
                steps.append(.init(
                    kind: .delete, document: document, destination: nil, before: before, after: after,
                    destinationBefore: nil, annotationID: annotationID, annotationIDs: annotationID.map { [$0] } ?? [], resourceOptions: options.jsonValue
                ))
            }
        }

        let onlyCurrentText = steps.allSatisfy { $0.kind == .text && $0.document == context.document }
        let needsAnnotationConfirmation = steps.contains { step in
            step.annotationIDs.contains { annotations[$0]?.needsConfirmation == true }
        }
        return WorkspaceEditPlan(
            steps: steps,
            finalSnapshots: state,
            reviewAnnotations: annotations,
            warnings: warnings,
            requiresPreview: !onlyCurrentText || needsAnnotationConfirmation
        )
    }

    private static func documentID(for uri: String, context: EditorRequestContext) throws -> EditorDocumentID {
        guard let url = URL(string: uri), url.isFileURL,
              url.host == nil || url.host == "" || url.host == "localhost" else {
            throw Error.unsupportedURI
        }
        return EditorDocumentID(host: context.document.host, worktreeID: context.document.worktreeID, uri: uri)
    }

    private static func validate(annotationID: String?, annotations: [String: LSPChangeAnnotation]) throws {
        if let annotationID, annotations[annotationID] == nil { throw Error.unknownAnnotation }
    }

    private static func validate(snapshot: WorkspaceFileSnapshot) throws {
        if snapshot.isSymbolicLink { throw Error.symbolicLinkAmbiguity }
        if let content = snapshot.content, String(data: content, encoding: .utf8) == nil { throw Error.nonTextInput }
    }

    static func applying(_ edits: [LSPTextEdit], to snapshot: WorkspaceFileSnapshot) throws -> WorkspaceFileSnapshot {
        guard let content = snapshot.content, let text = String(data: content, encoding: .utf8) else {
            throw Error.nonTextInput
        }
        var resolved: [(edit: LSPTextEdit, start: Int, end: Int, index: Int)] = []
        for (index, edit) in edits.enumerated() {
            let start: Int
            let end: Int
            do {
                start = try LSPPositionCodec.offset(edit.range.start, in: text)
                end = try LSPPositionCodec.offset(edit.range.end, in: text)
            } catch {
                throw Error.malformedRange
            }
            guard start <= end else { throw Error.malformedRange }
            resolved.append((edit, start, end, index))
        }
        try validateOverlaps(resolved)

        var result = text
        for item in resolved.sorted(by: { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start > rhs.start }
            return lhs.index > rhs.index
        }) {
            let start = String.Index(utf16Offset: item.start, in: result)
            let end = String.Index(utf16Offset: item.end, in: result)
            result.replaceSubrange(start..<end, with: item.edit.newText)
        }
        return try snapshot.replacing(content: WorkspaceEditSnapshotBudget.data(result))
    }

    private static func validateOverlaps(_ edits: [(edit: LSPTextEdit, start: Int, end: Int, index: Int)]) throws {
        for index in edits.indices {
            for candidateIndex in (index + 1)..<edits.count {
                let candidate = edits[candidateIndex]
                let current = edits[index]
                if current.start < candidate.end && candidate.start < current.end { throw Error.overlappingEdits }
                let currentIsInsertion = current.start == current.end
                let candidateIsInsertion = candidate.start == candidate.end
                if currentIsInsertion != candidateIsInsertion {
                    let insertion = currentIsInsertion ? current : candidate
                    let replacement = currentIsInsertion ? candidate : current
                    if replacement.start <= insertion.start, insertion.start <= replacement.end {
                        throw Error.overlappingEdits
                    }
                }
            }
        }
    }
}

private extension LSPCreateFileOptions {
    var jsonValue: LSPJSONValue {
        .object(["overwrite": .bool(overwrite), "ignoreIfExists": .bool(ignoreIfExists)])
    }
}

private extension LSPRenameFileOptions {
    var jsonValue: LSPJSONValue {
        .object(["overwrite": .bool(overwrite), "ignoreIfExists": .bool(ignoreIfExists)])
    }
}

private extension LSPDeleteFileOptions {
    var jsonValue: LSPJSONValue {
        .object(["recursive": .bool(recursive), "ignoreIfNotExists": .bool(ignoreIfNotExists)])
    }
}
