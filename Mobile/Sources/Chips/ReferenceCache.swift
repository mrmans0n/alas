import AlasRemoteKit
import Observation

/// What the session's `#N`/`!N` references turned out to be, as the host
/// looked them up. Chips draw gray until their entry arrives.
@MainActor @Observable
final class ReferenceCache {
    enum Entry: Equatable {
        case loading
        case loaded(CodeHostReferenceSummary)
        case failed(CodeHostReferenceFailure)
        /// The host can't look references up: it predates them, or the worktree has no code host.
        case unsupported
    }

    private(set) var entries: [CodeHostReference: Entry] = [:]

    /// Asks `send` for the references not asked for yet; with no lookup
    /// support they are marked unsupported instead.
    func ensure(_ references: [CodeHostReference], supported: Bool, send: ([String]) -> Void) {
        let wanted = references.filter { entries[$0] == nil || entries[$0] == .unsupported && supported }
        guard !wanted.isEmpty else { return }
        for reference in wanted { entries[reference] = supported ? .loading : .unsupported }
        if supported {
            for batch in stride(from: 0, to: wanted.count, by: RemoteChipLimits.maxReferences) {
                send(wanted[batch ..< min(batch + RemoteChipLimits.maxReferences, wanted.count)].map(\.spelling))
            }
        }
    }

    func apply(_ answers: [RemoteReferenceEntry]) {
        for answer in answers {
            guard let reference = CodeHostReference(spelling: answer.spelling) else { continue }
            if let summary = answer.summary {
                entries[reference] = .loaded(summary)
            } else if let failure = answer.failure {
                entries[reference] = .failed(failure)
            }
        }
    }

    /// A reply never came (a reconnect dropped it): ask again next time.
    func forgetPending() {
        entries = entries.filter { $0.value != .loading }
    }

    /// The loaded kind, or on GitLab the kind the sigil implies; nil draws gray.
    func kind(of reference: CodeHostReference, host: CodeHostKind?) -> CodeHostReferenceSummary.Kind? {
        if case .loaded(let summary)? = entries[reference] { return summary.kind }
        guard host == .gitlab else { return nil }
        return reference.sigil == .bang ? .reviewRequest : .issue
    }
}
