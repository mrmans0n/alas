import CryptoKit
import Foundation

enum CheckpointSnapshotError: Error, Equatable, Sendable {
    case remoteTarget
    case lineageChanged
    case invalidGitOutput
    case unsupportedPaths([String])
    case payloadTooLarge(path: String, byteCount: Int64, limit: Int64)
    case missingPayload(String)
    case stateChanged
}

extension CheckpointSnapshotError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .remoteTarget:
            return "Checkpoints are only available for local worktrees."
        case .lineageChanged:
            return "This worktree identity changed. Refresh before using checkpoints."
        case .invalidGitOutput:
            return "Git returned checkpoint data Alas could not understand."
        case .unsupportedPaths(let paths):
            return "Checkpoint capture does not support: \(paths.joined(separator: ", "))."
        case .payloadTooLarge(let path, let byteCount, let limit):
            return "\(path) is too large to capture safely (\(CheckpointPresentation.bytes(byteCount)); limit \(CheckpointPresentation.bytes(limit)))."
        case .missingPayload(let hash):
            return "Checkpoint payload is missing: \(hash)."
        case .stateChanged:
            return "The worktree changed while Alas was creating the checkpoint. Try again."
        }
    }
}

struct WorktreeStateSnapshot: Equatable, Sendable {
    let lineageID: String
    let headOID: String
    let branch: String
    let indexChecksum: String
    let paths: [String: CheckpointPathState]
    let groups: [CheckpointFileGroup]
    let exclusions: [CheckpointExclusion]
    let payloads: [String: Data]
    let fingerprint: String

    func payload(_ state: CheckpointFileState) throws -> Data? {
        guard let blob = state.blob else { return nil }
        guard let bytes = payloads[blob.sha256] else { throw CheckpointSnapshotError.missingPayload(blob.sha256) }
        return bytes
    }
}

struct CheckpointCaptureAttempt: Equatable, Sendable {
    let snapshot: WorktreeStateSnapshot
    let capturedAt: Date
}

struct WorktreeStateSnapshotter: Sendable {
    static let live = Self()
    static let defaultRetainedPayloadByteLimit: Int64 = 100 * 1024 * 1024
    let git: any CheckpointGitRunning
    let fileSystem: any CheckpointFileSystem
    let retainedPayloadByteLimit: Int64

    init(git: any CheckpointGitRunning = LiveCheckpointGitRunner(),
         fileSystem: any CheckpointFileSystem = LiveCheckpointFileSystem(),
         retainedPayloadByteLimit: Int64 = Self.defaultRetainedPayloadByteLimit) {
        self.git = git
        self.fileSystem = fileSystem
        self.retainedPayloadByteLimit = retainedPayloadByteLimit
    }

    func snapshot(target: CheckpointWorktreeTarget, includingPaths: Set<String> = [],
                  ignoringRestoreOperation: UUID? = nil, onlyIncludedPaths: Bool = false,
                  retainingPayloads: Bool = true) async throws -> WorktreeStateSnapshot {
        guard !target.path.isRemoteAlasPath else { throw CheckpointSnapshotError.remoteTarget }
        try validateLineage(target)
        let head = try await headOID(target)
        let branchResult = try await git.runData(["symbolic-ref", "--short", "-q", "HEAD"], cwd: target.path, environment: [:])
        guard branchResult.exitCode == 0 || branchResult.exitCode == 1 else {
            throw ProcessError.nonZeroExit(branchResult.exitCode, branchResult.stderr)
        }
        let branch = branchResult.exitCode == 1 ? "(detached)" : try line(branchResult.stdout)
        let indexChecksum = try await checksum(target)
        let status = try await data(["status", "--porcelain=v2", "-z", "--untracked-files=all"], target)
        let index = try entries(try await data(["ls-files", "--stage", "-z"], target), tree: false)
        let headEntries = try entries(try await data(["ls-tree", "-r", "-z", head], target), tree: true)
        // Lowercase tags identify assume-unchanged entries, whose disk edits
        // can be hidden from both status and diff. S marks skip-worktree.
        let hidden = try records(try await data(["ls-files", "-v", "-z"], target))
            .filter { $0.hasPrefix("S ") || $0.first?.isLowercase == true }
            .map { String($0.dropFirst(2)) }
        let intentToAdd = try await intentToAddPaths(target)
        let unsupported = Set(hidden + intentToAdd + index.unsupported + headEntries.unsupported)
        guard unsupported.isEmpty else { throw CheckpointSnapshotError.unsupportedPaths(unsupported.sorted()) }

        var candidates = try statusPaths(status)
        candidates.formUnion(includingPaths)
        var renames: [(String, String)] = []
        for args in [["diff", "--cached", "--name-status", "-z", "--find-renames", "--no-ext-diff", head, "--"],
                     ["diff", "--name-status", "-z", "--find-renames", "--no-ext-diff", "--"]] {
            // Git diff can refresh stat entries even with GIT_OPTIONAL_LOCKS=0.
            // Snapshot reads must preserve the exact index bytes being verified.
            let changes = try parseDiff(try await data(["-c", "diff.autoRefreshIndex=false"] + args, target))
            candidates.formUnion(changes.paths)
            renames += changes.renames
        }
        let caseOnlyRenamePairs: [(String, String)] = renames.compactMap { source, destination in
            guard source != destination, source.caseInsensitiveCompare(destination) == .orderedSame else { return nil }
            return (destination, source)
        }
        let caseOnlyRenameSources = Dictionary(uniqueKeysWithValues: caseOnlyRenamePairs)
        let caseOnlyRenameSourcePaths = Set(caseOnlyRenamePairs.map(\.1))
        let untracked = Set(try records(try await data(["ls-files", "--others", "--exclude-standard", "-z"], target)))
        candidates.formUnion(untracked)
        if onlyIncludedPaths { candidates.formIntersection(includingPaths) }
        var payloads: [String: Data] = [:]
        var states: [String: CheckpointPathState] = [:]
        var exclusions: [CheckpointExclusion] = []
        for path in candidates.sorted() {
            if let operation = ignoringRestoreOperation,
               path.hasPrefix(".alas-checkpoint-restore-\(operation.uuidString.lowercased())/") { continue }
            if caseOnlyRenameSourcePaths.contains(path) {
                let headState = try await gitState(headEntries.values[path], target, path: path,
                                                   payloads: &payloads,
                                                   retainingPayloads: retainingPayloads)
                states[path] = .init(relativePath: path, head: headState, index: .absent, worktree: .absent)
                continue
            }
            let headPath = path
            let indexPath = index.values[path] == nil ? (caseOnlyRenameSources[path] ?? path) : path
            let isUntracked = untracked.contains(path) && index.values[indexPath] == nil && headEntries.values[headPath] == nil
            if isUntracked, !includingPaths.contains(path), let reason = try exclusion(path, root: target.path) {
                exclusions.append(.init(relativePath: path, reason: reason))
                continue
            }
            let headState = try await gitState(headEntries.values[headPath], target, path: headPath,
                                               payloads: &payloads,
                                               retainingPayloads: retainingPayloads)
            let indexState = try await gitState(index.values[indexPath], target, path: indexPath,
                                                payloads: &payloads,
                                                retainingPayloads: retainingPayloads)
            let diskState: CheckpointFileState
            do {
                _ = try fileSystem.validateRelativePath(path, under: target.path)
                diskState = try self.diskState(
                    path: path,
                    root: target.path,
                    directoryAsAbsent: headState.kind != .absent || indexState.kind != .absent || includingPaths.contains(path),
                    relativePath: path,
                    payloads: &payloads,
                    retainingPayloads: retainingPayloads
                )
            } catch CheckpointFileSystemError.unsafePath where headState.kind == .absent && indexState.kind == .absent && includingPaths.contains(path) {
                diskState = .absent
            }
            states[path] = .init(relativePath: path, head: headState, index: indexState, worktree: diskState)
        }
        try validateLineage(target)
        guard try await headOID(target) == head,
              try await checksum(target) == indexChecksum else { throw CheckpointSnapshotError.stateChanged }
        let groups = makeGroups(paths: Set(states.keys), renames: renames)
        // JSON encodes path delimiters unambiguously, including tabs and newlines.
        let fingerprintRecord = Fingerprint(lineageID: target.lineageID, headOID: head, branch: branch,
                                            indexChecksum: indexChecksum, paths: states.values.sorted { $0.relativePath < $1.relativePath },
                                            exclusions: exclusions)
        let fingerprint = CheckpointBlobReference.make(for: try JSONEncoder.checkpoints.encode(fingerprintRecord)).sha256
        return .init(lineageID: target.lineageID, headOID: head, branch: branch, indexChecksum: indexChecksum,
                     paths: states, groups: groups, exclusions: exclusions, payloads: payloads, fingerprint: fingerprint)
    }

    private struct Fingerprint: Encodable {
        let lineageID: String
        let headOID: String
        let branch: String
        let indexChecksum: String
        let paths: [CheckpointPathState]
        let exclusions: [CheckpointExclusion]
    }

    private struct Entry { let mode: String
    let oid: String }
    private struct Entries { var values: [String: Entry] = [:]
    var unsupported: [String] = [] }

    private func entries(_ bytes: Data, tree: Bool) throws -> Entries {
        var result = Entries()
        for record in try records(bytes) {
            guard let tab = record.firstIndex(of: "\t") else { throw CheckpointSnapshotError.invalidGitOutput }
            let fields = record[..<tab].split(separator: " ")
            guard fields.count == 3 else { throw CheckpointSnapshotError.invalidGitOutput }
            let path = String(record[record.index(after: tab)...])
            let mode = String(fields[0])
            if !["100644", "100755", "120000"].contains(mode) || (!tree && fields[2] != "0") {
                result.unsupported.append(path)
            }
            result.values[path] = Entry(mode: mode, oid: String(fields[tree ? 2 : 1]))
        }
        return result
    }

    private func statusPaths(_ bytes: Data) throws -> Set<String> {
        let records = try records(bytes)
        var paths = Set<String>()
        var offset = 0
        while offset < records.count {
            let record = records[offset]
            offset += 1
            let count: Int
            switch record.first {
            case "1": count = 8
            case "2": count = 9
            case "u": throw CheckpointSnapshotError.unsupportedPaths([String(record.split(separator: " ", maxSplits: 10).last ?? "")])
            case "?": continue // Untracked candidates come exclusively from ls-files.
            default: throw CheckpointSnapshotError.invalidGitOutput
            }
            let fields = record.split(separator: " ", maxSplits: count, omittingEmptySubsequences: false)
            guard fields.count == count + 1 else { throw CheckpointSnapshotError.invalidGitOutput }
            paths.insert(String(fields[count]))
            if record.first == "2" {
                guard offset < records.count else { throw CheckpointSnapshotError.invalidGitOutput }
                paths.insert(records[offset])
                offset += 1
            }
        }
        return paths
    }

    private func parseDiff(_ bytes: Data) throws -> (paths: Set<String>, renames: [(String, String)]) {
        let parts = try records(bytes)
        var paths = Set<String>()
        var renames: [(String, String)] = []
        var offset = 0
        while offset < parts.count {
            let status = parts[offset]
            guard offset + 1 < parts.count else { throw CheckpointSnapshotError.invalidGitOutput }
            let first = parts[offset + 1]
            paths.insert(first)
            offset += 2
            if status.hasPrefix("R") || status.hasPrefix("C") {
                guard offset < parts.count else { throw CheckpointSnapshotError.invalidGitOutput }
                paths.insert(parts[offset])
                if status.hasPrefix("R") { renames.append((first, parts[offset])) }
                offset += 1
            }
        }
        return (paths, renames)
    }

    private func makeGroups(paths: Set<String>, renames: [(String, String)]) -> [CheckpointFileGroup] {
        var remaining = paths
        var groups: [CheckpointFileGroup] = []
        // Rename chains can overlap between HEAD -> index and index -> disk.
        for path in paths.sorted() where remaining.contains(path) {
            var members: Set<String> = [path]
            var changed = true
            while changed {
                let previous = members
                for (source, destination) in renames where members.contains(source) || members.contains(destination) {
                    members.formUnion([source, destination].filter { paths.contains($0) })
                }
                changed = previous != members
            }
            let rename = renames.last { members.contains($0.1) && (!paths.contains($0.0) || members.contains($0.0)) }
            groups.append(.init(id: UUID(), primaryPath: rename?.1 ?? path, renameSource: rename?.0,
                                memberPaths: members.sorted()))
            remaining.subtract(members)
        }
        return groups.sorted { $0.primaryPath < $1.primaryPath }
    }

    private func exclusion(_ path: String, root: URL) throws -> CheckpointExclusionReason? {
        let components = path.split(separator: "/").map(String.init)
        if components.contains(where: { $0.hasPrefix(".alas-checkpoint-restore-") && UUID(uuidString: String($0.dropFirst(25))) != nil }) {
            return .internalRestoreDirectory
        }
        let ignored: Set<String> = [".git", ".build", "build", "DerivedData", "node_modules", ".swiftpm", ".gradle", "Pods", "Carthage"]
        if components.contains(where: { ignored.contains($0) }) { return .ignoredByPolicy }
        let basename = components.last ?? ""
        if [".env", ".netrc", "credentials", "credentials.json"].contains(basename) || basename.hasPrefix(".env.") ||
            ["key", "pem", "p12", "pfx", "mobileprovision", "keystore"].contains((basename as NSString).pathExtension.lowercased()) {
            return .likelySecret
        }
        do {
            if let metadata = try fileSystem.metadata(root: root, relativePath: path),
               metadata.kind == .regular, metadata.byteCount > 10 * 1024 * 1024 { return .tooLarge }
        } catch CheckpointFileSystemError.unsupportedLeaf { return .specialFile
        } catch CheckpointFileSystemError.unsafePath { return .unsafePath
        } catch CheckpointFileSystemError.invalidRelativePath { return .unsafePath }
        return nil
    }

    private func gitState(_ entry: Entry?, _ target: CheckpointWorktreeTarget,
                          path: String,
                          payloads: inout [String: Data], retainingPayloads: Bool = true) async throws -> CheckpointFileState {
        guard let entry else { return .absent }
        if !retainingPayloads {
            let blob = try await git.blobReference(oid: entry.oid, cwd: target.path, environment: [:])
            return entry.mode == "120000" ? .symlink(blob: blob) : .regular(blob: blob, executable: entry.mode == "100755")
        }
        let byteCount = try await gitBlobSize(oid: entry.oid, target)
        guard byteCount <= retainedPayloadByteLimit else {
            throw CheckpointSnapshotError.payloadTooLarge(path: path, byteCount: byteCount, limit: retainedPayloadByteLimit)
        }
        let blob = add(try await data(["cat-file", "blob", entry.oid], target), to: &payloads,
                       retainingPayload: retainingPayloads)
        return entry.mode == "120000" ? .symlink(blob: blob) : .regular(blob: blob, executable: entry.mode == "100755")
    }

    private func diskState(path: String, root: URL, directoryAsAbsent: Bool, relativePath: String, payloads: inout [String: Data],
                           retainingPayloads: Bool) throws -> CheckpointFileState {
        do {
            guard let metadata = try fileSystem.metadata(root: root, relativePath: path) else { return .absent }
            if !retainingPayloads, metadata.kind == .regular {
                let url = try fileSystem.validateRelativePath(path, under: root)
                return .regular(blob: try streamFileReference(at: url), executable: metadata.executable)
            }
            if retainingPayloads, metadata.kind == .regular, metadata.byteCount > retainedPayloadByteLimit {
                throw CheckpointSnapshotError.payloadTooLarge(
                    path: relativePath,
                    byteCount: metadata.byteCount,
                    limit: retainedPayloadByteLimit
                )
            }
            switch try fileSystem.readLeaf(root: root, relativePath: path) {
            case .regular(let bytes, let executable):
                return .regular(blob: add(bytes, to: &payloads, retainingPayload: retainingPayloads), executable: executable)
            case .symlink(let bytes):
                return .symlink(blob: add(bytes, to: &payloads, retainingPayload: retainingPayloads))
            }
        } catch CheckpointFileSystemError.unsupportedLeaf where directoryAsAbsent {
            var isDirectory: ObjCBool = false
            let url = try fileSystem.validateRelativePath(path, under: root)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return .absent
            }
            throw CheckpointFileSystemError.unsupportedLeaf
        }
    }

    private func gitBlobSize(oid: String, _ target: CheckpointWorktreeTarget) async throws -> Int64 {
        let size = try await text(["cat-file", "-s", oid], target)
        guard let byteCount = Int64(size) else { throw CheckpointSnapshotError.invalidGitOutput }
        return byteCount
    }

    private func streamFileReference(at url: URL) throws -> CheckpointBlobReference {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount: Int64 = 0
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            byteCount += Int64(chunk.count)
            hasher.update(data: chunk)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return CheckpointBlobReference(sha256: hash, byteCount: byteCount)
    }

    private func add(_ data: Data, to payloads: inout [String: Data], retainingPayload: Bool = true) -> CheckpointBlobReference {
        let reference = CheckpointBlobReference.make(for: data)
        if retainingPayload { payloads[reference.sha256] = data }
        return reference
    }

    private func checksum(_ target: CheckpointWorktreeTarget) async throws -> String {
        let path = try await text(["rev-parse", "--path-format=absolute", "--git-path", "index"], target)
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: url.path) { return CheckpointBlobReference.make(for: Data()).sha256 }
        return CheckpointBlobReference.make(for: try fileSystem.fileData(url)).sha256
    }

    private func headOID(_ target: CheckpointWorktreeTarget) async throws -> String {
        let result = try await git.run(["rev-parse", "--verify", "HEAD"], cwd: target.path, environment: [:])
        if result.exitCode == 0 { return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
        let unborn = try await git.run(["rev-parse", "--verify", "--quiet", "HEAD"], cwd: target.path, environment: [:])
        guard unborn.exitCode == 1 else { throw ProcessError.nonZeroExit(result.exitCode, result.stderr) }
        return try await emptyTreeOID(target)
    }

    private func emptyTreeOID(_ target: CheckpointWorktreeTarget) async throws -> String {
        let result = try await git.run(["hash-object", "-t", "tree", "/dev/null"], cwd: target.path, environment: [:])
        guard result.exitCode == 0 else { throw ProcessError.nonZeroExit(result.exitCode, result.stderr) }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func intentToAddPaths(_ target: CheckpointWorktreeTarget) async throws -> [String] {
        let output = try await data(["ls-files", "--debug"], target)
        guard let text = String(data: output, encoding: .utf8) else { throw CheckpointSnapshotError.invalidGitOutput }
        var result: [String] = []
        var currentPath: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.first?.isWhitespace != true {
                currentPath = line
                continue
            }
            guard let path = currentPath else { continue }
            if line.trimmingCharacters(in: .whitespaces).contains("flags: 2000") {
                result.append(path)
                currentPath = nil
            }
        }
        return result
    }

    private func validateLineage(_ target: CheckpointWorktreeTarget) throws {
        guard WorktreeService.existingLocalLineageID(forWorktreeAt: target.path) == target.lineageID else {
            throw CheckpointSnapshotError.lineageChanged
        }
    }

    private func records(_ bytes: Data) throws -> [String] {
        guard bytes.isEmpty || bytes.last == 0 else { throw CheckpointSnapshotError.invalidGitOutput }
        return try bytes.split(separator: 0).map {
            guard let value = String(data: Data($0), encoding: .utf8) else { throw CheckpointSnapshotError.invalidGitOutput }
            return value
        }
    }

    private func line(_ bytes: Data) throws -> String {
        guard var value = String(data: bytes, encoding: .utf8) else { throw CheckpointSnapshotError.invalidGitOutput }
        if value.hasSuffix("\n") { value.removeLast() }
        return value
    }

    private func text(_ args: [String], _ target: CheckpointWorktreeTarget) async throws -> String {
        try await line(data(args, target))
    }

    private func data(_ args: [String], _ target: CheckpointWorktreeTarget) async throws -> Data {
        let result = try await git.runData(args, cwd: target.path, environment: [:])
        guard result.exitCode == 0 else { throw ProcessError.nonZeroExit(result.exitCode, result.stderr) }
        return result.stdout
    }
}
