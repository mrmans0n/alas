import Foundation

enum CheckpointSnapshotError: Error, Equatable, Sendable {
    case remoteTarget
    case lineageChanged
    case invalidGitOutput
    case unsupportedPaths([String])
    case missingPayload(String)
    case stateChanged
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
    let git: any CheckpointGitRunning
    let fileSystem: any CheckpointFileSystem

    init(git: any CheckpointGitRunning = LiveCheckpointGitRunner(),
         fileSystem: any CheckpointFileSystem = LiveCheckpointFileSystem()) {
        self.git = git
        self.fileSystem = fileSystem
    }

    func snapshot(target: CheckpointWorktreeTarget) async throws -> WorktreeStateSnapshot {
        guard !target.path.isRemoteAlasPath else { throw CheckpointSnapshotError.remoteTarget }
        try validateLineage(target)
        let head = try await text(["rev-parse", "--verify", "HEAD"], target)
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
        let unsupported = Set(hidden + index.unsupported + headEntries.unsupported)
        guard unsupported.isEmpty else { throw CheckpointSnapshotError.unsupportedPaths(unsupported.sorted()) }

        var candidates = try statusPaths(status)
        var renames: [(String, String)] = []
        for args in [["diff", "--cached", "--name-status", "-z", "--find-renames", "--no-ext-diff", head, "--"],
                     ["diff", "--name-status", "-z", "--find-renames", "--no-ext-diff", "--"]] {
            let changes = try parseDiff(try await data(args, target))
            candidates.formUnion(changes.paths)
            renames += changes.renames
        }
        let untracked = Set(try records(try await data(["ls-files", "--others", "--exclude-standard", "-z"], target)))
        candidates.formUnion(untracked)
        var payloads: [String: Data] = [:]
        var states: [String: CheckpointPathState] = [:]
        var exclusions: [CheckpointExclusion] = []
        for path in candidates.sorted() {
            let isUntracked = untracked.contains(path) && index.values[path] == nil && headEntries.values[path] == nil
            if isUntracked, let reason = try exclusion(path, root: target.path) {
                exclusions.append(.init(relativePath: path, reason: reason))
                continue
            }
            _ = try fileSystem.validateRelativePath(path, under: target.path)
            let headState = try await gitState(headEntries.values[path], target, payloads: &payloads)
            let indexState = try await gitState(index.values[path], target, payloads: &payloads)
            let diskState: CheckpointFileState
            if try fileSystem.metadata(root: target.path, relativePath: path) == nil {
                diskState = .absent
            } else {
                switch try fileSystem.readLeaf(root: target.path, relativePath: path) {
                case .regular(let bytes, let executable):
                    diskState = .regular(blob: add(bytes, to: &payloads), executable: executable)
                case .symlink(let bytes):
                    diskState = .symlink(blob: add(bytes, to: &payloads))
                }
            }
            states[path] = .init(relativePath: path, head: headState, index: indexState, worktree: diskState)
        }
        try validateLineage(target)
        guard try await text(["rev-parse", "--verify", "HEAD"], target) == head,
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
            let rename = renames.last { members.contains($0.0) && members.contains($0.1) }
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
                          payloads: inout [String: Data]) async throws -> CheckpointFileState {
        guard let entry else { return .absent }
        let blob = add(try await data(["cat-file", "blob", entry.oid], target), to: &payloads)
        return entry.mode == "120000" ? .symlink(blob: blob) : .regular(blob: blob, executable: entry.mode == "100755")
    }

    private func add(_ data: Data, to payloads: inout [String: Data]) -> CheckpointBlobReference {
        let reference = CheckpointBlobReference.make(for: data)
        payloads[reference.sha256] = data
        return reference
    }

    private func checksum(_ target: CheckpointWorktreeTarget) async throws -> String {
        let path = try await text(["rev-parse", "--path-format=absolute", "--git-path", "index"], target)
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: url.path) { return CheckpointBlobReference.make(for: Data()).sha256 }
        return CheckpointBlobReference.make(for: try fileSystem.fileData(url)).sha256
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
