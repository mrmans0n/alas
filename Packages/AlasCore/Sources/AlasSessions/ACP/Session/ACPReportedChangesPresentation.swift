import Foundation
import AlasACP
import AlasModel
import AlasPlatform

/// What a user row shows for its turn's adapter-reported changes. A report is a
/// hint, never a verdict, so nothing here reads as "no changes" or "clean".
public struct ACPReportedChangesPresentation: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case reported(count: Int), reportedEmpty, unavailable(reasonText: String), missing
    }

    public let state: State
    public let title: String
    /// Nil only when `declaredComplete` is literally true.
    public let caveat: String?
    public let truncationNotice: String?
    /// Unique and sorted.
    public let paths: [String]

    private static let adapterListCaveat =
        "This is the adapter's list. Shell commands, generators and background work may have changed other files."
    private static let notCleanCaveat = "This does not mean no files changed. Check Git for the workspace's current state."

    /// Nil when no control shows: no reference, or a report still awaited during an active turn.
    public static func make(attachments: [ACPMessage.Attachment], isTurnActive: Bool) -> Self? {
        guard let reference = attachments.first(where: { $0.fileChangeReportRequestId != nil }) else { return nil }
        guard let report = reference.fileChangeReport else {
            guard !isTurnActive else { return nil }
            return Self(state: .missing, title: "No report received", caveat: notCleanCaveat, truncationNotice: nil, paths: [])
        }
        // An adapter's blank text says nothing, so it cannot replace a caveat.
        let uncertainty = report.uncertainty.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let truncationNotice = report.truncated ? "The adapter left out some paths." : nil
        switch report.status {
        case .unavailable:
            return Self(
                state: .unavailable(reasonText: reasonText(report.reason)), title: "Reported changes unavailable",
                caveat: uncertainty ?? notCleanCaveat, truncationNotice: truncationNotice, paths: [])
        case .reported:
            let paths = Set(report.paths).sorted()
            return Self(
                state: paths.isEmpty ? .reportedEmpty : .reported(count: paths.count),
                title: paths.isEmpty ? "No file changes reported" : "Reported changes · \(paths.count)",
                caveat: uncertainty ?? (report.declaredComplete ? nil : adapterListCaveat),
                truncationNotice: truncationNotice, paths: paths)
        }
    }

    private static func reasonText(_ reason: String?) -> String {
        switch reason {
        case "cancelled": "The turn was cancelled before a report was made."
        case "timeout": "The adapter timed out preparing the report."
        case "invalidOutput": "The adapter could not read this turn's changes."
        case "notReported": "The adapter does not report changes for this kind of turn."
        case "providerError": "The provider failed before a report was made."
        default: "The adapter gave no report for this turn."
        }
    }
}

/// The roots a reported path may resolve against, as this session sees them.
public struct ACPReportedPathRoots: Equatable, Sendable {
    /// Virtual for a remote worktree; the checkout root in a checkout.
    public let root: String
    /// Local `realpath`; nil for remote.
    public let physicalRoot: String?
    /// Non-nil in a workspace checkout.
    public let memberRoots: [String]?

    public init(root: String, physicalRoot: String?, memberRoots: [String]? = nil) {
        self.root = root
        self.physicalRoot = physicalRoot
        self.memberRoots = memberRoots
    }

    /// `realpath(3)`, never `URL.resolvingSymlinksInPath()`, which maps
    /// `/private/tmp` back to `/tmp`. Nil for a remote path or a failed resolve.
    public static func physicalRoot(of root: String) -> String? {
        guard !RemotePath.isReserved(root), let resolved = realpath(root, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

public struct ACPReportedPathRow: Equatable, Sendable, Identifiable {
    public enum Target: Equatable, Sendable {
        case file(relativePath: String), outside
    }

    /// The raw path.
    public let id: String
    /// The relative path, or the raw path with control characters replaced by U+FFFD.
    public let display: String
    public let target: Target
}

public enum ACPReportedPathResolver {
    /// One row per unique path. Lexical only: nothing here touches a file system,
    /// and a foreign path must never be probed on this machine.
    ///
    /// A remote `physicalRoot` is nil by design: the app's remote worktree paths
    /// come from Git's physical paths, so the virtual root already is the physical
    /// one. A remote root that is somehow a symlink reads as foreign, the safe way.
    public static func rows(for paths: [String], roots: ACPReportedPathRoots) -> [ACPReportedPathRow] {
        var seen: Set<String> = []
        return paths.compactMap { path in
            guard seen.insert(path).inserted else { return nil }
            guard let relative = relativePath(of: path, roots: roots) else {
                return ACPReportedPathRow(id: path, display: sanitizedForDisplay(path), target: .outside)
            }
            return ACPReportedPathRow(id: path, display: relative, target: .file(relativePath: relative))
        }
    }

    private static func relativePath(of path: String, roots: ACPReportedPathRoots) -> String? {
        // Correct adapters drop these; this is untrusted input.
        guard !path.unicodeScalars.contains(where: isControl) else { return nil }
        // The contract says absolute, and joining a relative path to the root
        // would trust it. A virtual remote path starts with `/` too.
        guard path.hasPrefix("/") else { return nil }
        guard let relative = relative(path, inside: roots.root)
            ?? roots.physicalRoot.flatMap({ relative(path, inside: $0) })
        else { return nil }
        if let members = roots.memberRoots {
            let absolute = roots.root + "/" + relative
            guard members.contains(where: { absolute.hasPrefix($0 + "/") }) else { return nil }
        }
        return relative
    }

    /// The path below `root`; nil outside it and for the root itself.
    private static func relative(_ path: String, inside root: String) -> String? {
        guard let resolved = try? RemotePathContainment.lexicallyResolveInsideWorktree(path: path, worktreeRoot: root),
              resolved != root
        else { return nil }
        return String(resolved.dropFirst(root.count + 1))
    }

    private static func sanitizedForDisplay(_ path: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in path.unicodeScalars {
            scalars.append(isControl(scalar) ? "\u{FFFD}" : scalar)
        }
        return String(scalars)
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value <= 0x1F || (0x7F...0x9F).contains(scalar.value)
    }
}
