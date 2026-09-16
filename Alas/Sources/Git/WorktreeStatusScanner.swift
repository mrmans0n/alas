import Foundation

/// Computes `WorktreeDirtyState` by running `git status` across worktrees.
///
/// An actor so the in-flight coalescing flags are protected without a lock.
/// The parsing half is a pure static function so the porcelain format — which
/// is where the bugs live — is testable without git, a filesystem, or a
/// subprocess.
actor WorktreeStatusScanner {
    static let shared = WorktreeStatusScanner()

    /// Cap on concurrent git subprocesses. `git status` stats the working
    /// tree, so an unbounded fan-out would spawn one process per worktree —
    /// around 34 for a typical setup — on every app activation.
    static let maxConcurrentScans = 4

    /// Per-worktree ceiling. A pathological repo should not stall the pass.
    static let perScanTimeout: TimeInterval = 10

    private var isScanning = false
    private var rescanRequested = false
    private var pendingPaths: [URL]?
    private let statusesProvider: @Sendable ([URL]) async -> [String: WorktreeDirtyState]

    init(
        statusesProvider: @escaping @Sendable ([URL]) async -> [String: WorktreeDirtyState] = WorktreeStatusScanner.statuses(for:)
    ) {
        self.statusesProvider = statusesProvider
    }

    /// Scans `paths` and publishes the results.
    ///
    /// Coalesces overlapping triggers: a request arriving mid-scan sets a flag
    /// and returns rather than starting a second concurrent pass, then the
    /// running pass repeats once when it finishes.
    func scan(paths: [URL]) async {
        guard !isScanning else {
            pendingPaths = mergedPaths(pendingPaths, with: paths)
            rescanRequested = true
            return
        }
        isScanning = true
        defer { isScanning = false }

        var currentPaths = paths
        repeat {
            rescanRequested = false
            let results = await statusesProvider(currentPaths)
            await MainActor.run { WorktreeStatusStore.shared.apply(results) }
            if rescanRequested, let pendingPaths {
                currentPaths = pendingPaths
                self.pendingPaths = nil
            }
        } while rescanRequested
    }

    private func mergedPaths(_ current: [URL]?, with incoming: [URL]) -> [URL] {
        guard var merged = current else { return incoming }
        var seen = Set(merged.map(\.path))
        for path in incoming where seen.insert(path.path).inserted {
            merged.append(path)
        }
        return merged
    }

    /// Runs at most `maxConcurrentScans` git processes at a time.
    ///
    /// Worktrees whose scan fails are omitted from the result rather than
    /// reported as `.unknown`, so the store keeps its previous value and a row
    /// showing dirt does not blank on a transient git error.
    nonisolated static func statuses(for paths: [URL]) async -> [String: WorktreeDirtyState] {
        var results: [String: WorktreeDirtyState] = [:]
        await withTaskGroup(of: (String, WorktreeDirtyState?).self) { group in
            var iterator = paths.makeIterator()

            func addNext() {
                guard let path = iterator.next() else { return }
                group.addTask { (path.path, await status(at: path)) }
            }

            for _ in 0..<maxConcurrentScans { addNext() }
            while let (path, status) = await group.next() {
                if let status { results[path] = status }
                addNext()
            }
        }
        return results
    }

    /// Returns nil when the worktree is gone or git fails, so the caller can
    /// leave the previous value alone.
    nonisolated static func status(at path: URL) async -> WorktreeDirtyState? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        // usesRemoteHostRegistry: false keeps this scanner strictly local —
        // remote worktrees are fed from the remote summary pipeline instead.
        guard let result = try? await Process.git(
            ["status", "--porcelain=v1", "-z", "--untracked-files=normal"],
            cwd: path,
            usesRemoteHostRegistry: false,
            timeout: perScanTimeout
        ), result.exitCode == 0 else { return nil }
        return parse(porcelainZ: result.stdout)
    }

    /// Parses `git status --porcelain=v1 -z` output.
    ///
    /// Each record is `XY <path>` terminated by NUL. Rename and copy records
    /// carry the original path in a following NUL-terminated field, which is
    /// consumed without being counted as another changed file.
    nonisolated static func parse(porcelainZ output: String) -> WorktreeDirtyState {
        var fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        // git terminates the final record too, leaving a trailing empty field.
        if fields.last?.isEmpty == true { fields.removeLast() }

        var fileCount = 0
        var conflictCount = 0
        var index = 0

        while index < fields.count {
            let record = fields[index]
            index += 1
            // "XY " plus at least one path character.
            guard record.count >= 3 else { continue }

            let code = String(record.prefix(2))
            fileCount += 1
            if isUnmerged(code) { conflictCount += 1 }

            // Renames and copies spend a second field on their source path.
            // Checked on either column deliberately: a record with `R` or `C`
            // in the index or the work-tree position carries the extra path
            // field, not just when it leads.
            if code.contains("R") || code.contains("C") { index += 1 }
        }

        guard fileCount > 0 else { return .clean }
        return .dirty(fileCount: fileCount, conflictCount: conflictCount)
    }

    /// Unmerged (conflicted) porcelain codes: any code containing `U`, plus
    /// `AA` (both added) and `DD` (both deleted), which contain none.
    nonisolated static func isUnmerged(_ code: String) -> Bool {
        code.contains("U") || code == "AA" || code == "DD"
    }
}
