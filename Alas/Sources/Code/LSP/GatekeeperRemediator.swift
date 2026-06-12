import Foundation

/// Orchestrates inline Gatekeeper remediation for a blocked LSP binary.
///
/// `GatekeeperAssessor` only flags binaries that carry the
/// `com.apple.quarantine` xattr (the narrow signal Tahoe's GUI-spawn
/// Gatekeeper actually acts on), so remediation is just removing that
/// attribute and re-checking. No admin prompt, no `spctl --add` — those
/// don't fix the actual block on Tahoe (and `spctl --add` is deprecated
/// in modern macOS anyway).
@MainActor
final class GatekeeperRemediator {
    enum Outcome: Equatable {
        case allowed
        case stillBlocked
        case failed(String)
    }

    typealias QuarantineRemover = (_ path: String) async -> Bool
    typealias Reassess = (_ realPath: String) -> GatekeeperAssessor.Result
    typealias InvalidateCache = (_ realPath: String) -> Void

    private let removeQuarantine: QuarantineRemover
    private let reassess: Reassess
    private let invalidate: InvalidateCache

    init(
        removeQuarantine: @escaping QuarantineRemover = GatekeeperRemediator.defaultRemoveQuarantine,
        reassess: @escaping Reassess = { GatekeeperAssessor.shared.assess(realPath: $0) },
        invalidate: @escaping InvalidateCache = { GatekeeperAssessor.shared.invalidate(realPath: $0) }
    ) {
        self.removeQuarantine = removeQuarantine
        self.reassess = reassess
        self.invalidate = invalidate
    }

    func remediate(realPath: String, remediationTarget: String? = nil) async -> Outcome {
        let target = remediationTarget ?? realPath
        let removed = await removeQuarantine(target)
        invalidate(realPath)
        switch reassess(realPath) {
        case .allowed:
            return .allowed
        case .rejected, .unknown:
            return removed
                ? .stillBlocked
                : .failed("Could not remove the quarantine attribute from \(realPath).")
        }
    }

    nonisolated static func defaultRemoveQuarantine(realPath: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: removeQuarantineRecursively(at: realPath))
            }
        }
    }

    nonisolated private static func removeQuarantineRecursively(at path: String) -> Bool {
        var ok = removeQuarantineAttribute(at: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(atPath: path) else {
            return ok
        }

        for case let relativePath as String in enumerator {
            let childPath = URL(fileURLWithPath: path).appendingPathComponent(relativePath).path
            ok = removeQuarantineAttribute(at: childPath) && ok
        }
        return ok
    }

    nonisolated private static func removeQuarantineAttribute(at path: String) -> Bool {
        let result = path.withCString { cpath in
            removexattr(cpath, "com.apple.quarantine", 0)
        }
        // 0 → removed. -1 with ENOATTR → wasn't there; treat as
        // success since the post-state matches the goal.
        return result == 0 || (result == -1 && errno == ENOATTR)
    }
}
