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
    /// Which ask each loading entry waits on, so an earlier ask's deadline
    /// never expires a later one.
    @ObservationIgnored private var pending: [CodeHostReference: Int] = [:]
    @ObservationIgnored private var asks = 0

    /// What an unanswered lookup shows. The host leaves out a lookup it
    /// didn't finish in time, so this marks it to be asked again.
    static let noAnswer = CodeHostReferenceFailure.other("The host did not answer.")
    /// Past the host's own 10 s lookup deadline, with room for the trip.
    private static let answerDeadline = Duration.seconds(15)

    /// Asks `send` for the references not asked for yet, or not answered;
    /// with no lookup support they are marked unsupported instead.
    func ensure(_ references: [CodeHostReference], supported: Bool, send: ([String]) -> Void) {
        let wanted = references.filter { Self.needsAsking(entries[$0], supported: supported) }
        guard !wanted.isEmpty else { return }
        guard supported else {
            for reference in wanted { entries[reference] = .unsupported }
            return
        }
        asks += 1
        let ask = asks
        for reference in wanted {
            entries[reference] = .loading
            pending[reference] = ask
        }
        for batch in stride(from: 0, to: wanted.count, by: RemoteChipLimits.maxReferences) {
            send(wanted[batch ..< min(batch + RemoteChipLimits.maxReferences, wanted.count)].map(\.spelling))
        }
        Task { [weak self] in
            try? await Task.sleep(for: Self.answerDeadline)
            self?.expire(wanted, ask: ask)
        }
    }

    private static func needsAsking(_ entry: Entry?, supported: Bool) -> Bool {
        switch entry {
        case nil: true
        case .unsupported: supported
        case .failed(let failure): failure == noAnswer
        case .loading, .loaded: false
        }
    }

    private func expire(_ references: [CodeHostReference], ask: Int) {
        for reference in references where pending[reference] == ask {
            pending[reference] = nil
            if entries[reference] == .loading { entries[reference] = .failed(Self.noAnswer) }
        }
    }

    func apply(_ answers: [RemoteReferenceEntry]) {
        for answer in answers {
            guard let reference = CodeHostReference(spelling: answer.spelling) else { continue }
            if let summary = answer.summary {
                entries[reference] = .loaded(summary)
                pending[reference] = nil
            } else if let failure = answer.failure {
                entries[reference] = .failed(failure)
                pending[reference] = nil
            }
        }
    }

    /// A reply never came (a reconnect dropped it): ask again next time.
    func forgetPending() {
        entries = entries.filter { $0.value != .loading }
        pending = [:]
    }

    /// The loaded kind, or on GitLab the kind the sigil implies; nil draws gray.
    func kind(of reference: CodeHostReference, host: CodeHostKind?) -> CodeHostReferenceSummary.Kind? {
        if case .loaded(let summary)? = entries[reference] { return summary.kind }
        guard host == .gitlab else { return nil }
        return reference.sigil == .bang ? .reviewRequest : .issue
    }
}
