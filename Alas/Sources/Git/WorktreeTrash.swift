import Foundation

struct WorktreeTrashDirectoryIdentity: Equatable, Sendable {
    let systemNumber: UInt64
    let fileNumber: UInt64
}

struct WorktreeTrashCleanupTicket: Equatable, Sendable {
    let trashRoot: URL
    let stagedPath: URL
    let directoryIdentity: WorktreeTrashDirectoryIdentity
}

enum WorktreeRemovalOutcome: Equatable, Sendable {
    case synchronous
    case staged(WorktreeTrashCleanupTicket)
}

enum WorktreeTrash {
    static let relativeDirectory = "alas/trash"
    private static let marker = "alas-worktree"
    private static let committedMarkerName = ".alas-worktree-deletion-committed"
    private static let committedMarkerVersion = "1"

    private struct CommittedMetadata {
        let date: Date
        let directoryIdentity: WorktreeTrashDirectoryIdentity
    }

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
    ) throws -> WorktreeTrashCleanupTicket {
        guard let directoryIdentity = directoryIdentity(at: originalPath) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let trashRoot = root(commonGitDirectory: commonGitDirectory)
        let safeBase = sanitizedBaseName(originalPath.lastPathComponent)
        let name = "\(safeBase).\(marker).\(Int(now.timeIntervalSince1970)).\(id.uuidString.lowercased())"
        return WorktreeTrashCleanupTicket(
            trashRoot: trashRoot,
            stagedPath: URL(
                fileURLWithPath: trashRoot.appendingPathComponent(name).path,
                isDirectory: false
            ),
            directoryIdentity: directoryIdentity
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

    static func markCommitted(
        _ ticket: WorktreeTrashCleanupTicket,
        at date: Date = Date()
    ) throws {
        guard isValid(ticket) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, seconds >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        let metadata = [
            committedMarkerVersion,
            String(seconds),
            String(ticket.directoryIdentity.systemNumber),
            String(ticket.directoryIdentity.fileNumber),
            "",
        ].joined(separator: "\n")
        try Data(metadata.utf8).write(
            to: committedMarkerURL(for: ticket),
            options: .atomic
        )
    }

    static func staleTickets(
        commonGitDirectories: [URL],
        olderThan cutoff: Date,
        fileManager: FileManager = .default
    ) -> [WorktreeTrashCleanupTicket] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
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
                guard let directoryIdentity = directoryIdentity(
                    at: entry,
                    fileManager: fileManager
                ) else { continue }
                let ticket = WorktreeTrashCleanupTicket(
                    trashRoot: trashRoot,
                    stagedPath: URL(
                        fileURLWithPath: trashRoot.path + "/" + entry.lastPathComponent,
                        isDirectory: false
                    ),
                    directoryIdentity: directoryIdentity
                )
                guard isValid(ticket),
                      let values = try? entry.resourceValues(forKeys: keys),
                      values.isDirectory == true,
                      values.isSymbolicLink != true,
                      let committed = committedMetadata(ticket, fileManager: fileManager),
                      committed.directoryIdentity == directoryIdentity,
                      committed.date < cutoff
                else { continue }
                tickets.append(ticket)
            }
        }
        return tickets.sorted { $0.stagedPath.path < $1.stagedPath.path }
    }

    static func directoryIdentity(
        at path: URL,
        fileManager: FileManager = .default
    ) -> WorktreeTrashDirectoryIdentity? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              let systemNumber = attributes[.systemNumber] as? NSNumber,
              let fileNumber = attributes[.systemFileNumber] as? NSNumber
        else { return nil }
        return WorktreeTrashDirectoryIdentity(
            systemNumber: systemNumber.uint64Value,
            fileNumber: fileNumber.uint64Value
        )
    }

    static func matchesDirectoryIdentity(
        _ ticket: WorktreeTrashCleanupTicket,
        fileManager: FileManager = .default
    ) -> Bool {
        directoryIdentity(at: ticket.stagedPath, fileManager: fileManager)
            == ticket.directoryIdentity
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

    static func committedMarkerURL(for ticket: WorktreeTrashCleanupTicket) -> URL {
        let identifier = ticket.stagedPath.lastPathComponent
            .split(separator: ".", omittingEmptySubsequences: false)
            .last
            .map(String.init) ?? "invalid"
        return ticket.trashRoot.appendingPathComponent(
            "\(committedMarkerName).\(identifier)",
            isDirectory: false
        )
    }

    private static func committedMetadata(
        _ ticket: WorktreeTrashCleanupTicket,
        fileManager: FileManager
    ) -> CommittedMetadata? {
        let markerURL = committedMarkerURL(for: ticket)
        guard let attributes = try? fileManager.attributesOfItem(atPath: markerURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.uint64Value <= 256,
              let data = fileManager.contents(atPath: markerURL.path),
              let raw = String(data: data, encoding: .utf8),
              raw.utf8.count == data.count
        else { return nil }
        let fields = raw.components(separatedBy: "\n")
        guard fields.count == 5,
              fields[0] == committedMarkerVersion,
              fields[4].isEmpty,
              let seconds = TimeInterval(fields[1]),
              seconds.isFinite,
              seconds >= 0,
              let systemNumber = UInt64(fields[2]),
              let fileNumber = UInt64(fields[3])
        else { return nil }
        return CommittedMetadata(
            date: Date(timeIntervalSince1970: seconds),
            directoryIdentity: WorktreeTrashDirectoryIdentity(
                systemNumber: systemNumber,
                fileNumber: fileNumber
            )
        )
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
