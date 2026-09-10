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
    private static let pendingMarkerName = ".alas-worktree-deletion-pending"
    private static let pendingMarkerVersion = "1"

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

    static func markPending(
        _ ticket: WorktreeTrashCleanupTicket,
        originalPath: URL,
        linkedGitDirectory: URL,
        at date: Date = Date()
    ) throws {
        guard isValid(ticket) else { throw CocoaError(.fileWriteInvalidFileName) }
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, seconds >= 0,
              !linkedGitDirectory.lastPathComponent.isEmpty
        else { throw CocoaError(.fileWriteUnknown) }
        let metadata = [
            pendingMarkerVersion,
            String(seconds),
            String(ticket.directoryIdentity.systemNumber),
            String(ticket.directoryIdentity.fileNumber),
            ticket.stagedPath.lastPathComponent,
            Data(originalPath.standardizedFileURL.path.utf8).base64EncodedString(),
            Data(linkedGitDirectory.lastPathComponent.utf8).base64EncodedString(),
            "",
        ].joined(separator: "\n")
        try Data(metadata.utf8).write(
            to: pendingMarkerURL(for: ticket),
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
                reconcilePendingTicket(
                    ticket,
                    commonGitDirectory: commonGitDirectory,
                    fileManager: fileManager
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

    static func pendingMarkerURL(for ticket: WorktreeTrashCleanupTicket) -> URL {
        let identifier = ticket.stagedPath.lastPathComponent
            .split(separator: ".", omittingEmptySubsequences: false)
            .last
            .map(String.init) ?? "invalid"
        return ticket.trashRoot.appendingPathComponent(
            "\(pendingMarkerName).\(identifier)",
            isDirectory: false
        )
    }

    private static func reconcilePendingTicket(
        _ ticket: WorktreeTrashCleanupTicket,
        commonGitDirectory: URL,
        fileManager: FileManager
    ) {
        guard isValid(ticket),
              matchesDirectoryIdentity(ticket, fileManager: fileManager),
              let pending = pendingMetadata(ticket, fileManager: fileManager),
              pending.directoryIdentity == ticket.directoryIdentity,
              pending.stagedName == ticket.stagedPath.lastPathComponent,
              !fileManager.fileExists(atPath: pending.originalPath.path)
        else { return }
        let registrationDirectory = commonGitDirectory
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(pending.linkedGitDirectoryName, isDirectory: true)
        if fileManager.fileExists(atPath: registrationDirectory.path) {
            restorePendingTicket(
                ticket,
                pending: pending,
                registrationDirectory: registrationDirectory,
                fileManager: fileManager
            )
            return
        }
        do {
            try markCommitted(ticket, at: pending.date)
            try fileManager.removeItem(at: pendingMarkerURL(for: ticket))
        } catch {
            return
        }
    }

    private static func restorePendingTicket(
        _ ticket: WorktreeTrashCleanupTicket,
        pending: PendingMetadata,
        registrationDirectory: URL,
        fileManager: FileManager
    ) {
        guard registrationGitFilePointsToOriginalPath(
            registrationDirectory: registrationDirectory,
            originalPath: pending.originalPath,
            fileManager: fileManager
        ) else { return }
        do {
            try fileManager.moveItem(at: ticket.stagedPath, to: pending.originalPath)
            try fileManager.removeItem(at: pendingMarkerURL(for: ticket))
        } catch {
            return
        }
    }

    private static func registrationGitFilePointsToOriginalPath(
        registrationDirectory: URL,
        originalPath: URL,
        fileManager: FileManager
    ) -> Bool {
        let gitdirFile = registrationDirectory.appendingPathComponent("gitdir", isDirectory: false)
        guard let data = fileManager.contents(atPath: gitdirFile.path),
              let raw = String(data: data, encoding: .utf8),
              raw.utf8.count == data.count
        else { return false }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        let gitdir = (value as NSString).isAbsolutePath
            ? URL(fileURLWithPath: value)
            : registrationDirectory.appendingPathComponent(value)
        let expected = originalPath.appendingPathComponent(".git", isDirectory: false)
        return pathsReferToSameFile(gitdir, expected)
            || gitdir.standardizedFileURL.path == expected.standardizedFileURL.path
    }

    private static func pathsReferToSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        let lhsPath = lhs.resolvingSymlinksInPath().standardizedFileURL.path
        let rhsPath = rhs.resolvingSymlinksInPath().standardizedFileURL.path
        return lhsPath == rhsPath
            || normalizedDarwinPath(lhsPath) == normalizedDarwinPath(rhsPath)
    }

    private static func normalizedDarwinPath(_ path: String) -> String {
        if path.hasPrefix("/private/var/") {
            return String(path.dropFirst("/private".count))
        }
        if path == "/private/var" {
            return "/var"
        }
        return path
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

    private struct PendingMetadata {
        let date: Date
        let directoryIdentity: WorktreeTrashDirectoryIdentity
        let stagedName: String
        let originalPath: URL
        let linkedGitDirectoryName: String
    }

    private static func pendingMetadata(
        _ ticket: WorktreeTrashCleanupTicket,
        fileManager: FileManager
    ) -> PendingMetadata? {
        let markerURL = pendingMarkerURL(for: ticket)
        guard let attributes = try? fileManager.attributesOfItem(atPath: markerURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.uint64Value <= 1_024,
              let data = fileManager.contents(atPath: markerURL.path),
              let raw = String(data: data, encoding: .utf8),
              raw.utf8.count == data.count
        else { return nil }
        let fields = raw.components(separatedBy: "\n")
        guard fields.count == 8,
              fields[0] == pendingMarkerVersion,
              fields[7].isEmpty,
              let seconds = TimeInterval(fields[1]), seconds.isFinite, seconds >= 0,
              let systemNumber = UInt64(fields[2]),
              let fileNumber = UInt64(fields[3]),
              isRecognizedEntryName(fields[4]),
              let originalData = Data(base64Encoded: fields[5]),
              let original = String(data: originalData, encoding: .utf8),
              original.utf8.count == originalData.count,
              original.hasPrefix("/"),
              let linkedGitDirectoryNameData = Data(base64Encoded: fields[6]),
              let linkedGitDirectoryName = String(data: linkedGitDirectoryNameData, encoding: .utf8),
              linkedGitDirectoryName.utf8.count == linkedGitDirectoryNameData.count,
              !linkedGitDirectoryName.isEmpty,
              !linkedGitDirectoryName.contains("/")
        else { return nil }
        return PendingMetadata(
            date: Date(timeIntervalSince1970: seconds),
            directoryIdentity: WorktreeTrashDirectoryIdentity(
                systemNumber: systemNumber,
                fileNumber: fileNumber
            ),
            stagedName: fields[4],
            originalPath: URL(fileURLWithPath: original).standardizedFileURL,
            linkedGitDirectoryName: linkedGitDirectoryName
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
