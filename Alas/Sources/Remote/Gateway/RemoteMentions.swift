import Foundation

/// The host side of a viewer's `@` mentions: ranking candidates the way the
/// local picker does, and turning the mentions a prompt carries back into
/// the attachments the local composer would have sent.
enum RemoteMentions {
    static let fileLimit = 20
    static let symbolLimit = 20
    /// Longer names are cut, so a crafted mention can't bloat the prompt.
    static let maxNameLength = 200

    /// Sessions above files for a plain query. A `File.swift#name` query
    /// drills into that file's symbols alone, which the caller looks up and
    /// passes as `fileSymbols`.
    /// `fileExists` drops listed files missing from the working tree, such
    /// as tracked files deleted since the last commit.
    static func candidates(
        query: String, root: URL, filePaths: [String], sessions: [ACPSessionMentionCandidate],
        fileSymbols: [SymbolEntry], fileExists: (URL) -> Bool = { _ in true }
    ) -> [RemoteMention] {
        let query = query.trimmingCharacters(in: .whitespaces)
        if case .file(_, let symbol) = MentionSymbolQuery.parse(query) {
            return MentionSymbolRanking.rank(fileSymbols, query: symbol, limit: symbolLimit).map(mention)
        }
        let sessionRows = MentionSessionRanking.rank(sessions, query: query).map {
            RemoteMention(kind: RemoteMention.session, value: $0.id, name: $0.title,
                          detail: "\($0.agentName) · \($0.worktreeName)")
        }
        let files = filePaths.map { root.appendingPathComponent($0) }
        let directories = MentionFuzzy.pickerDirectories(
            forEntries: filePaths.map { ($0, $0.hasSuffix("/")) }, root: root)
        // Ranked past the limit so missing files don't leave the list short.
        let ranked = MentionFuzzy.rank(files: files + directories, query: query, limit: fileLimit * 3, relativeTo: root)
        let fileRows = ranked.filter(fileExists).prefix(fileLimit)
            .compactMap { url -> RemoteMention? in
                guard url.path.count > root.path.count else { return nil }
                let path = String(url.path.dropFirst(root.path.count + 1))
                let parent = (path as NSString).deletingLastPathComponent
                // A trailing slash marks a directory, for the viewer's icon.
                return RemoteMention(kind: RemoteMention.file, value: url.hasDirectoryPath ? path + "/" : path,
                                     name: url.lastPathComponent,
                                     detail: parent.isEmpty ? nil : parent)
            }
        return sessionRows + fileRows
    }

    static func mention(_ entry: SymbolEntry) -> RemoteMention {
        let target = ACPSymbolReference.Target(entry: entry, includeCode: false)
        return RemoteMention(kind: RemoteMention.symbol, value: ACPSymbolReference.uri(for: target),
                             name: target.displayName,
                             detail: "\(entry.relativePath):\(entry.lineRange.lowerBound + 1)")
    }

    /// The attachment for one mention, or nil when it names nothing inside
    /// the session's project: a path `isContainedFile` rejects, the session
    /// itself, a session `isProjectSession` doesn't confirm, or a malformed
    /// symbol link.
    @MainActor
    static func attachment(
        for mention: RemoteMention, worktreeRoot: URL, sessionId: String,
        isContainedFile: (_ relativePath: String) async -> Bool,
        isProjectSession: (String) async -> Bool
    ) async -> ACPMessage.Attachment? {
        let name = String(mention.name.prefix(maxNameLength))
        switch mention.kind {
        case RemoteMention.file:
            guard let path = RemoteWorktreeFileAccess.normalizedRelativePath(mention.value),
                  await isContainedFile(path)
            else { return nil }
            let url = worktreeRoot.appendingPathComponent(path, isDirectory: mention.value.hasSuffix("/"))
            return .init(uri: url.absoluteString, name: name, mimeType: nil)
        case RemoteMention.session:
            guard mention.value != sessionId, await isProjectSession(mention.value) else { return nil }
            return .init(uri: ACPSessionReference.uri(sessionId: mention.value), name: name, mimeType: nil)
        case RemoteMention.symbol:
            // Re-encoded, so only the fields the parser accepted reach the
            // runner. The path gets the file check too: a symbol badge opens
            // its file.
            guard let target = ACPSymbolReference.target(fromURI: mention.value),
                  let path = RemoteWorktreeFileAccess.normalizedRelativePath(target.path),
                  await isContainedFile(path)
            else { return nil }
            return .init(uri: ACPSymbolReference.uri(for: target), name: name, mimeType: nil)
        default:
            return nil
        }
    }
}
