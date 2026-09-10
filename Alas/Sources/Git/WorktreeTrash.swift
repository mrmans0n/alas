import Foundation

struct WorktreeTrashCleanupTicket: Equatable, Sendable {
    let trashRoot: URL
    let stagedPath: URL
}

enum WorktreeRemovalOutcome: Equatable, Sendable {
    case synchronous
    case staged(WorktreeTrashCleanupTicket)
}

enum WorktreeTrash {
    static let relativeDirectory = "alas/trash"
    private static let marker = "alas-worktree"

    static func root(commonGitDirectory: URL) -> URL {
        let path = commonGitDirectory
            .appendingPathComponent(relativeDirectory)
            .standardizedFileURL
            .path
        return URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
    }

    static func makeTicket(
        commonGitDirectory: URL,
        originalPath: URL,
        now: Date = Date(),
        id: UUID = UUID()
    ) -> WorktreeTrashCleanupTicket {
        let trashRoot = root(commonGitDirectory: commonGitDirectory)
        let safeBase = sanitizedBaseName(originalPath.lastPathComponent)
        let name = "\(safeBase).\(marker).\(Int(now.timeIntervalSince1970)).\(id.uuidString.lowercased())"
        return WorktreeTrashCleanupTicket(
            trashRoot: trashRoot,
            stagedPath: URL(
                fileURLWithPath: trashRoot.appendingPathComponent(name).path,
                isDirectory: false
            )
        )
    }

    static func isValid(_ ticket: WorktreeTrashCleanupTicket) -> Bool {
        let root = ticket.trashRoot.standardizedFileURL
        let target = ticket.stagedPath.standardizedFileURL
        return root.lastPathComponent == "trash"
            && root.deletingLastPathComponent().lastPathComponent == "alas"
            && target.deletingLastPathComponent().path == root.path
            && isRecognizedEntryName(target.lastPathComponent)
    }

    static func staleTickets(
        commonGitDirectories: [URL],
        olderThan cutoff: Date,
        fileManager: FileManager = .default
    ) -> [WorktreeTrashCleanupTicket] {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]
        let commonDirectories = Dictionary(
            commonGitDirectories.map { ($0.standardizedFileURL.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var tickets: [WorktreeTrashCleanupTicket] = []
        for commonPath in commonDirectories.keys.sorted() {
            guard let commonGitDirectory = commonDirectories[commonPath] else { continue }
            let trashRoot = root(commonGitDirectory: commonGitDirectory)
            guard let entries = try? fileManager.contentsOfDirectory(
                at: trashRoot,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries {
                let ticket = WorktreeTrashCleanupTicket(
                    trashRoot: trashRoot,
                    stagedPath: URL(
                        fileURLWithPath: trashRoot.path + "/" + entry.lastPathComponent,
                        isDirectory: false
                    )
                )
                guard isValid(ticket),
                      let values = try? entry.resourceValues(forKeys: keys),
                      values.isDirectory == true,
                      values.isSymbolicLink != true,
                      let modified = values.contentModificationDate,
                      modified < cutoff
                else { continue }
                tickets.append(ticket)
            }
        }
        return tickets.sorted { $0.stagedPath.path < $1.stagedPath.path }
    }

    private static func sanitizedBaseName(_ value: String) -> String {
        var result = ""
        var needsSeparator = false
        for scalar in value.unicodeScalars {
            let byte = scalar.value
            let allowed = (48...57).contains(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
                || byte == 45
                || byte == 95
            if allowed {
                if needsSeparator, !result.isEmpty { result.append("-") }
                result.unicodeScalars.append(scalar)
                needsSeparator = false
            } else {
                needsSeparator = true
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        let limited = String(trimmed.prefix(48))
        return limited.isEmpty ? "worktree" : limited
    }

    private static func isRecognizedEntryName(_ value: String) -> Bool {
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 4,
              fields[1] == Substring(marker),
              let epoch = Int(fields[2]),
              epoch >= 0,
              UUID(uuidString: String(fields[3])) != nil
        else { return false }
        return !fields[0].isEmpty
    }
}
