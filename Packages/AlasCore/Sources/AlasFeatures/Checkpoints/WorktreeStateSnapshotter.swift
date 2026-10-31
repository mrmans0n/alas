import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

public enum CheckpointSnapshotError: Error, Equatable, Sendable {
    case remoteTarget
    case lineageChanged
    case invalidGitOutput
    case unsupportedPaths([String])
    case payloadTooLarge(path: String, byteCount: Int64, limit: Int64)
    case missingPayload(String)
    case stateChanged
}

extension CheckpointSnapshotError: LocalizedError {
    public var errorDescription: String? {
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
            return "\(path) is too large to capture safely (\(CheckpointBytes.format(byteCount)); limit \(CheckpointBytes.format(limit)))."
        case .missingPayload(let hash):
            return "Checkpoint payload is missing: \(hash)."
        case .stateChanged:
            return "The worktree changed while Alas was creating the checkpoint. Try again."
        }
    }
}

public struct WorktreeStateSnapshot: Equatable, Sendable {
    public let lineageID: String
    public let headOID: String
    public let branch: String
    public let indexChecksum: String
    public let paths: [String: CheckpointPathState]
    public let groups: [CheckpointFileGroup]
    public let exclusions: [CheckpointExclusion]
    public let payloads: [String: Data]
    public let fingerprint: String
    /// When this snapshot started reading the worktree.
    public let startedAt: Date
    /// The stat identity of each regular worktree file, taken before reading it.
    public let diskIdentities: [String: CheckpointStatIdentity]
    /// The reference of each HEAD and index object read, by object id.
    public let gitBlobReferences: [String: CheckpointBlobReference]

    public func payload(_ state: CheckpointFileState) throws -> Data? {
        guard let blob = state.blob else { return nil }
        guard let bytes = payloads[blob.sha256] else { throw CheckpointSnapshotError.missingPayload(blob.sha256) }
        return bytes
    }

    public init(lineageID: String, headOID: String, branch: String, indexChecksum: String, paths: [String: CheckpointPathState], groups: [CheckpointFileGroup], exclusions: [CheckpointExclusion], payloads: [String: Data], fingerprint: String,
                startedAt: Date = .distantPast, diskIdentities: [String: CheckpointStatIdentity] = [:],
                gitBlobReferences: [String: CheckpointBlobReference] = [:]) {
        self.lineageID = lineageID
        self.headOID = headOID
        self.branch = branch
        self.indexChecksum = indexChecksum
        self.paths = paths
        self.groups = groups
        self.exclusions = exclusions
        self.payloads = payloads
        self.fingerprint = fingerprint
        self.startedAt = startedAt
        self.diskIdentities = diskIdentities
        self.gitBlobReferences = gitBlobReferences
    }
}

public struct CheckpointCaptureAttempt: Equatable, Sendable {
    public let snapshot: WorktreeStateSnapshot
    public let capturedAt: Date

    public init(snapshot: WorktreeStateSnapshot, capturedAt: Date) {
        self.snapshot = snapshot
        self.capturedAt = capturedAt
    }
}

public struct WorktreeStateSnapshotter: Sendable {
    public static let live = Self()
    public static let defaultRetainedPayloadByteLimit: Int64 = 100 * 1024 * 1024
    /// A leaf changed this close before a snapshot started may have changed
    /// again within the timestamp granularity, so a verifying pass re-reads it.
    /// Same limits as git's racy check: writers through mmap whose timestamps
    /// lag the write, and network file systems with coarse timestamps or a
    /// server clock more than this behind can still hide a change.
    public static let racyWindow: TimeInterval = 2
    public let git: any CheckpointGitRunning
    public let fileSystem: any CheckpointFileSystem
    public let retainedPayloadByteLimit: Int64

    public init(git: any CheckpointGitRunning = LiveCheckpointGitRunner(),
         fileSystem: any CheckpointFileSystem = LiveCheckpointFileSystem(),
         retainedPayloadByteLimit: Int64 = Self.defaultRetainedPayloadByteLimit) {
        self.git = git
        self.fileSystem = fileSystem
        self.retainedPayloadByteLimit = retainedPayloadByteLimit
    }

    public func snapshot(target: CheckpointWorktreeTarget, includingPaths: Set<String> = [],
                  ignoringRestoreOperation: UUID? = nil, onlyIncludedPaths: Bool = false,
                  retainingPayloads: Bool = true, gitPaths: CheckpointGitPaths? = nil,
                  verifying previous: WorktreeStateSnapshot? = nil) async throws -> WorktreeStateSnapshot {
        let startedAt = Date()
        // A pass that verifies `previous` trusts its object references, which
        // are immutable by id, and its worktree reads of files whose stat
        // identity is unchanged and settled before `previous` started.
        let reusable = previous.map { (snapshot: $0, settledBefore: $0.startedAt.addingTimeInterval(-Self.racyWindow)) }
        guard !target.path.isRemoteAlasPath else { throw CheckpointSnapshotError.remoteTarget }
        try validateLineage(target)
        let (head, branch) = try await headAndBranch(target)
        let indexPath: URL
        if let gitPaths { indexPath = gitPaths.index }
        else { indexPath = try await CheckpointGitPaths.resolve(git: git, cwd: target.path).index }
        let indexChecksum = try checksum(indexPath)
        // `-v` prefixes each staged record with a tag. Lowercase tags identify
        // assume-unchanged entries, whose disk edits can be hidden from both
        // status and diff. S marks skip-worktree. `--debug` adds the entry
        // flags, which mark intent-to-add.
        let listing = try indexListing(try await data(["ls-files", "-v", "--stage", "--debug", "-z"], target))
        let index = try entries(listing.tagged.map { $0.record }, tree: false)
        let hidden = try listing.tagged
            .filter { $0.tag == "S" || $0.tag.isLowercase }
            .map { try entryPath(of: $0.record) }
        // Git diff can refresh stat entries even with GIT_OPTIONAL_LOCKS=0.
        // Snapshot reads must preserve the exact index bytes being verified.
        // Submodules are never ignored, so every path whose HEAD entry differs
        // from its index entry is listed with that HEAD entry.
        let staged = try parseDiff(try await data(["-c", "diff.autoRefreshIndex=false", "diff", "--cached", "--raw", "--no-abbrev", "-z",
                                                   "--find-renames", "--no-ext-diff", "--ignore-submodules=none", head, "--"], target))
        // HEAD matches the index everywhere the staged diff is silent.
        var headEntries = Entries(values: index.values)
        for change in staged.changes {
            headEntries.values[change.path] = change.head
            if let destination = change.destination { headEntries.values[destination] = nil }
            if let entry = change.head, !Self.supportedModes.contains(entry.mode) { headEntries.unsupported.append(change.path) }
        }
        let unsupported = Set(hidden + listing.intentToAdd + index.unsupported + headEntries.unsupported)
        guard unsupported.isEmpty else { throw CheckpointSnapshotError.unsupportedPaths(unsupported.sorted()) }

        var candidates = staged.paths
        candidates.formUnion(includingPaths)
        let unstaged = try parseDiff(try await data(["-c", "diff.autoRefreshIndex=false", "diff", "--raw", "--no-abbrev", "-z",
                                                     "--find-renames", "--no-ext-diff", "--"], target))
        candidates.formUnion(unstaged.paths)
        let renames = staged.renames + unstaged.renames
        let caseOnlyRenamePairs: [(String, String)] = renames.compactMap { source, destination in
            guard source != destination, source.caseInsensitiveCompare(destination) == .orderedSame else { return nil }
            return (destination, source)
        }
        let caseOnlyRenameSources = Dictionary(uniqueKeysWithValues: caseOnlyRenamePairs)
        let caseOnlyRenameSourcePaths = Set(caseOnlyRenamePairs.map(\.1))
        let untracked = Set(try records(try await data(["ls-files", "--others", "--exclude-standard", "-z"], target)))
        candidates.formUnion(untracked)
        if onlyIncludedPaths { candidates.formIntersection(includingPaths) }
        let visited = candidates.sorted().filter { path in
            guard let operation = ignoringRestoreOperation else { return true }
            return !path.hasPrefix(".alas-checkpoint-restore-\(operation.uuidString.lowercased())/")
        }
        func indexEntryPath(for path: String) -> String {
            index.values[path] == nil ? (caseOnlyRenameSources[path] ?? path) : path
        }
        // HEAD before index, in path order, so a size-limit failure names the
        // same path the per-entry reads did.
        let gitEntries: [(path: String, entry: Entry)] = visited.flatMap { path -> [(path: String, entry: Entry)] in
            var entries = [headEntries.values[path].map { (path: path, entry: $0) }]
            if !caseOnlyRenameSourcePaths.contains(path) {
                let indexPath = indexEntryPath(for: path)
                entries.append(index.values[indexPath].map { (path: indexPath, entry: $0) })
            }
            return entries.compactMap { $0 }
        }
        var payloads: [String: Data] = [:]
        let blobs = try await gitBlobs(gitEntries, target, payloads: &payloads, retainingPayloads: retainingPayloads,
                                       known: retainingPayloads ? [:] : previous?.gitBlobReferences ?? [:])
        var diskIdentities: [String: CheckpointStatIdentity] = [:]
        var states: [String: CheckpointPathState] = [:]
        var exclusions: [CheckpointExclusion] = []
        for path in visited {
            if caseOnlyRenameSourcePaths.contains(path) {
                let headState = try gitState(headEntries.values[path], blobs: blobs)
                states[path] = .init(relativePath: path, head: headState, index: .absent, worktree: .absent)
                continue
            }
            let headPath = path
            let indexPath = indexEntryPath(for: path)
            let isUntracked = untracked.contains(path) && index.values[indexPath] == nil && headEntries.values[headPath] == nil
            if isUntracked, !includingPaths.contains(path), let reason = try exclusion(path, root: target.path) {
                exclusions.append(.init(relativePath: path, reason: reason))
                continue
            }
            let headState = try gitState(headEntries.values[headPath], blobs: blobs)
            let indexState = try gitState(index.values[indexPath], blobs: blobs)
            let diskState: CheckpointFileState
            do {
                _ = try fileSystem.validateRelativePath(path, under: target.path)
                diskState = try self.diskState(
                    path: path,
                    root: target.path,
                    directoryAsAbsent: headState.kind != .absent || indexState.kind != .absent || includingPaths.contains(path),
                    relativePath: path,
                    payloads: &payloads,
                    retainingPayloads: retainingPayloads,
                    identities: &diskIdentities,
                    reusable: retainingPayloads ? nil : reusable.flatMap { reusable in
                        reusable.snapshot.paths[path].map { (state: $0.worktree, identity: reusable.snapshot.diskIdentities[path],
                                                             settledBefore: reusable.settledBefore) }
                    }
                )
            } catch CheckpointFileSystemError.unsafePath where headState.kind == .absent && indexState.kind == .absent && includingPaths.contains(path) {
                diskState = .absent
            }
            states[path] = .init(relativePath: path, head: headState, index: indexState, worktree: diskState)
        }
        try validateLineage(target)
        guard try await headOID(target) == head,
              try checksum(indexPath) == indexChecksum else { throw CheckpointSnapshotError.stateChanged }
        let groups = makeGroups(paths: Set(states.keys), renames: renames)
        // JSON encodes path delimiters unambiguously, including tabs and newlines.
        let fingerprintRecord = Fingerprint(lineageID: target.lineageID, headOID: head, branch: branch,
                                            indexChecksum: indexChecksum, paths: states.values.sorted { $0.relativePath < $1.relativePath },
                                            exclusions: exclusions)
        let fingerprint = CheckpointBlobReference.make(for: try JSONEncoder.checkpoints.encode(fingerprintRecord)).sha256
        return .init(lineageID: target.lineageID, headOID: head, branch: branch, indexChecksum: indexChecksum,
                     paths: states, groups: groups, exclusions: exclusions, payloads: payloads, fingerprint: fingerprint,
                     startedAt: startedAt, diskIdentities: diskIdentities, gitBlobReferences: blobs)
    }

    private struct Fingerprint: Encodable {
        let lineageID: String
        let headOID: String
        let branch: String
        let indexChecksum: String
        let paths: [CheckpointPathState]
        let exclusions: [CheckpointExclusion]

        public init(lineageID: String, headOID: String, branch: String, indexChecksum: String, paths: [CheckpointPathState], exclusions: [CheckpointExclusion]) {
            self.lineageID = lineageID
            self.headOID = headOID
            self.branch = branch
            self.indexChecksum = indexChecksum
            self.paths = paths
            self.exclusions = exclusions
        }
    }

    private static let supportedModes: Set<String> = ["100644", "100755", "120000"]

    private struct Entry { let mode: String
    let oid: String

        public init(mode: String, oid: String) {
            self.mode = mode
            self.oid = oid
        }}
    private struct Entries { var values: [String: Entry] = [:]
    var unsupported: [String] = []

        public init(values: [String: Entry] = [:], unsupported: [String] = []) {
            self.values = values
            self.unsupported = unsupported
        }}

    private func entries(_ records: [String], tree: Bool) throws -> Entries {
        var result = Entries()
        for record in records {
            guard let tab = record.firstIndex(of: "\t") else { throw CheckpointSnapshotError.invalidGitOutput }
            let fields = record[..<tab].split(separator: " ")
            guard fields.count == 3 else { throw CheckpointSnapshotError.invalidGitOutput }
            let path = try entryPath(of: record)
            let mode = String(fields[0])
            if !Self.supportedModes.contains(mode) || (!tree && fields[2] != "0") {
                result.unsupported.append(path)
            }
            result.values[path] = Entry(mode: mode, oid: String(fields[tree ? 2 : 1]))
        }
        return result
    }

    private func entryPath(of record: String) throws -> String {
        guard let tab = record.firstIndex(of: "\t") else { throw CheckpointSnapshotError.invalidGitOutput }
        return String(record[record.index(after: tab)...])
    }

    private struct DiffChange {
        let path: String
        /// The source side; nil when the path is absent there.
        let head: Entry?
        /// A rename or copy destination.
        let destination: String?
    }

    /// Parses `diff --raw -z` output.
    private func parseDiff(_ bytes: Data) throws -> (paths: Set<String>, renames: [(String, String)], changes: [DiffChange]) {
        let parts = try records(bytes)
        var paths = Set<String>()
        var renames: [(String, String)] = []
        var changes: [DiffChange] = []
        var offset = 0
        while offset < parts.count {
            let fields = parts[offset].split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count == 5, fields[0].first == ":", offset + 1 < parts.count else { throw CheckpointSnapshotError.invalidGitOutput }
            let mode = String(fields[0].dropFirst())
            let status = fields[4]
            let first = parts[offset + 1]
            paths.insert(first)
            offset += 2
            var destination: String?
            if status.hasPrefix("R") || status.hasPrefix("C") {
                guard offset < parts.count else { throw CheckpointSnapshotError.invalidGitOutput }
                destination = parts[offset]
                paths.insert(parts[offset])
                if status.hasPrefix("R") { renames.append((first, parts[offset])) }
                offset += 1
            }
            changes.append(.init(path: first, head: mode == "000000" ? nil : Entry(mode: mode, oid: String(fields[2])),
                                 destination: destination))
        }
        return (paths, renames, changes)
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

    /// Reads every distinct object once, through one batch process per pass.
    /// Objects are immutable by OID, so reading them ahead of the disk reads
    /// observes the same content; the HEAD and index re-read at the end of the
    /// snapshot still guards the whole capture.
    private func gitBlobs(_ entries: [(path: String, entry: Entry)], _ target: CheckpointWorktreeTarget,
                          payloads: inout [String: Data], retainingPayloads: Bool,
                          known: [String: CheckpointBlobReference]) async throws -> [String: CheckpointBlobReference] {
        var seen = Set<String>()
        let oids = entries.map(\.entry.oid).filter { seen.insert($0).inserted }
        guard !oids.isEmpty else { return [:] }
        guard retainingPayloads else {
            let missing = oids.filter { known[$0] == nil }
            let read = missing.isEmpty ? [:] : try await git.blobReferences(oids: missing, cwd: target.path)
            return Dictionary(uniqueKeysWithValues: oids.compactMap { oid in (known[oid] ?? read[oid]).map { (oid, $0) } })
        }
        let sizes = try await git.blobSizes(oids: oids, cwd: target.path)
        for (path, entry) in entries {
            guard let byteCount = sizes[entry.oid] else { throw CheckpointSnapshotError.invalidGitOutput }
            guard byteCount <= retainedPayloadByteLimit else {
                throw CheckpointSnapshotError.payloadTooLarge(path: path, byteCount: byteCount, limit: retainedPayloadByteLimit)
            }
        }
        return try await git.blobContents(oids: oids, cwd: target.path).mapValues { add($0, to: &payloads) }
    }

    private func gitState(_ entry: Entry?, blobs: [String: CheckpointBlobReference]) throws -> CheckpointFileState {
        guard let entry else { return .absent }
        guard let blob = blobs[entry.oid] else { throw CheckpointSnapshotError.invalidGitOutput }
        return entry.mode == "120000" ? .symlink(blob: blob) : .regular(blob: blob, executable: entry.mode == "100755")
    }

    private func diskState(path: String, root: URL, directoryAsAbsent: Bool, relativePath: String, payloads: inout [String: Data],
                           retainingPayloads: Bool, identities: inout [String: CheckpointStatIdentity],
                           reusable: (state: CheckpointFileState, identity: CheckpointStatIdentity?, settledBefore: Date)?) throws -> CheckpointFileState {
        do {
            guard let metadata = try fileSystem.metadata(root: root, relativePath: path) else { return .absent }
            if metadata.kind == .regular, let identity = metadata.identity {
                identities[path] = identity
                if let reusable, reusable.identity == identity, identity.changedBefore(reusable.settledBefore),
                   reusable.state.kind == .regular, let blob = reusable.state.blob {
                    return .regular(blob: blob, executable: metadata.executable)
                }
            }
            if !retainingPayloads, metadata.kind == .regular {
                return .regular(blob: try fileSystem.regularFileReference(root: root, relativePath: path), executable: metadata.executable)
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

    private func add(_ data: Data, to payloads: inout [String: Data], retainingPayload: Bool = true) -> CheckpointBlobReference {
        let reference = CheckpointBlobReference.make(for: data)
        if retainingPayload { payloads[reference.sha256] = data }
        return reference
    }

    private func checksum(_ url: URL) throws -> String {
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

    /// HEAD's object and branch from one `rev-parse`. `--abbrev-ref=loose`
    /// shortens exactly as `symbolic-ref --short` does; a detached HEAD
    /// prints `HEAD`. An unborn branch fails, and falls back to the separate
    /// reads.
    private func headAndBranch(_ target: CheckpointWorktreeTarget) async throws -> (head: String, branch: String) {
        let result = try await git.runData(["rev-parse", "HEAD", "--abbrev-ref=loose", "HEAD"], cwd: target.path, environment: [:])
        if result.exitCode == 0 {
            let lines = try line(result.stdout).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard lines.count == 2, !lines[0].isEmpty, !lines[1].isEmpty else { throw CheckpointSnapshotError.invalidGitOutput }
            return (lines[0], lines[1] == "HEAD" ? "(detached)" : lines[1])
        }
        let head = try await headOID(target)
        let branchResult = try await git.runData(["symbolic-ref", "--short", "-q", "HEAD"], cwd: target.path, environment: [:])
        guard branchResult.exitCode == 0 || branchResult.exitCode == 1 else {
            throw ProcessError.nonZeroExit(branchResult.exitCode, branchResult.stderr)
        }
        return (head, branchResult.exitCode == 1 ? "(detached)" : try line(branchResult.stdout))
    }

    /// Parses `ls-files -v --stage --debug -z`: each record ends in NUL and is
    /// followed by indented, newline-terminated debug lines, the last holding
    /// the entry flags. Intent-to-add entries carry flag 0x20000000.
    private func indexListing(_ bytes: Data) throws -> (tagged: [(tag: Character, record: String)], intentToAdd: [String]) {
        var tagged: [(tag: Character, record: String)] = []
        var intentToAdd: [String] = []
        let chunks = bytes.split(separator: 0, omittingEmptySubsequences: false)
        for (number, chunk) in chunks.enumerated() {
            var rest = chunk[...]
            if number > 0 {
                var sawDebug = false
                while rest.first == UInt8(ascii: " ") {
                    guard let newline = rest.firstIndex(of: UInt8(ascii: "\n")) else { throw CheckpointSnapshotError.invalidGitOutput }
                    if String(decoding: rest[..<newline], as: UTF8.self).contains("flags: 2000"), let previous = tagged.last {
                        intentToAdd.append(try entryPath(of: previous.record))
                    }
                    rest = rest[rest.index(after: newline)...]
                    sawDebug = true
                }
                guard sawDebug else { throw CheckpointSnapshotError.invalidGitOutput }
            }
            if number == chunks.count - 1 {
                guard rest.isEmpty else { throw CheckpointSnapshotError.invalidGitOutput }
                break
            }
            guard let record = String(data: Data(rest), encoding: .utf8), let tag = record.first,
                  record.dropFirst().first == " " else { throw CheckpointSnapshotError.invalidGitOutput }
            tagged.append((tag, String(record.dropFirst(2))))
        }
        return (tagged, intentToAdd)
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

    private func data(_ args: [String], _ target: CheckpointWorktreeTarget) async throws -> Data {
        let result = try await git.runData(args, cwd: target.path, environment: [:])
        guard result.exitCode == 0 else { throw ProcessError.nonZeroExit(result.exitCode, result.stderr) }
        return result.stdout
    }
}
