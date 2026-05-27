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

    typealias QuarantineRemover = (_ realPath: String) async -> Bool
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

    func remediate(realPath: String) async -> Outcome {
        let removed = await removeQuarantine(realPath)
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
                let size = realPath.withCString { cpath in
                    removexattr(cpath, "com.apple.quarantine", 0)
                }
                // 0 → removed. -1 with ENOATTR → wasn't there; treat as
                // success since the post-state matches the goal.
                let ok = size == 0 || (size == -1 && errno == ENOATTR)
                continuation.resume(returning: ok)
            }
        }
    }
}
