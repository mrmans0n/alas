import Foundation

struct CommitMessageSuggester {
    let router: LocalTextAppleFirstRouter
    let timeout: Duration

    init(
        engine: any LocalTextGenerating,
        isAppleIntelligenceAvailable: @escaping @MainActor @Sendable () -> Bool = { false },
        generateWithAppleIntelligence: @escaping LocalTextAppleFirstRouter.AppleGenerator = { _ in nil },
        isMLXAvailable: @escaping @MainActor @Sendable () -> Bool,
        timeout: Duration = CommitMessageSuggestionPolicy.timeout
    ) {
        router = LocalTextAppleFirstRouter(
            engine: engine,
            isAppleIntelligenceAvailable: isAppleIntelligenceAvailable,
            generateWithAppleIntelligence: generateWithAppleIntelligence,
            isMLXAvailable: isMLXAvailable
        )
        self.timeout = timeout
    }

    /// Background priority: any user-initiated or automatic local text job
    /// preempts a pending commit suggestion.
    @MainActor
    func suggest(for input: CommitMessageSuggestionInput) async -> CommitMessageSuggestion? {
        let conventional = CommitMessageSuggestionPolicy.usesConventionalCommits(input.recentSubjects)
        let request = LocalTextGenerationRequest(
            messageCandidates: CommitMessageSuggestionPolicy.messageCandidates(for: input),
            inputTokenLimit: CommitMessageSuggestionPolicy.inputTokenLimit,
            maxTokens: CommitMessageSuggestionPolicy.maxTokens,
            temperature: 0,
            prefillStepSize: 512,
            timeout: timeout
        )
        return await router.generate(request, caller: .commitMessage, priority: .background) {
            CommitMessageSuggestionPolicy.parse($0, conventionalCommits: conventional)
        }
    }
}

/// Decides when a suggestion may seed the commit message fields. Alas only
/// fills blank fields or fields still holding its own untouched suggestion;
/// anything the user (or another writer) put there wins.
struct CommitMessageSuggestionState {
    enum Update: Equatable {
        /// Seed the fields with this suggestion.
        case fill(CommitMessageSuggestion)
        /// The fields hold an untouched draft for an older staged index.
        case clear
    }

    private struct Pending {
        let id: UInt64
        let indexKey: String
    }

    private var generation: UInt64 = 0
    private var pending: Pending?
    /// The untouched suggestion in the fields, if any.
    private(set) var applied: CommitMessageSuggestionRecord?

    init(restoring applied: CommitMessageSuggestionRecord? = nil) {
        self.applied = applied
    }

    var isSuggesting: Bool { pending != nil }

    /// True while the fields show an untouched suggestion.
    func isShowingSuggestion(subject: String, body: String) -> Bool {
        applied.map { $0.subject == subject && ($0.body ?? "") == body } ?? false
    }

    /// Starts a request for the staged index identified by `indexKey`, or
    /// returns nil when the fields are not Alas's to fill.
    mutating func begin(indexKey: String, subject: String, body: String) -> UInt64? {
        guard canFill(subject: subject, body: body) else {
            pending = nil
            return nil
        }
        generation &+= 1
        pending = Pending(id: generation, indexKey: indexKey)
        return generation
    }

    /// Call on every change to either field. Echoes of an applied suggestion
    /// are ignored; text anyone else wrote drops the pending request.
    mutating func recordEdit(subject: String, body: String) {
        if isShowingSuggestion(subject: subject, body: body) { return }
        applied = nil
        if !Self.isBlank(subject: subject, body: body) { pending = nil }
    }

    mutating func cancel() {
        pending = nil
    }

    /// True (and forgets the draft) when the fields still show an untouched
    /// suggestion computed for a staged index other than `indexKey`. Such a
    /// draft describes changes that are no longer what would be committed.
    mutating func withdrawStale(indexKey: String, subject: String, body: String) -> Bool {
        guard let applied, applied.indexKey != indexKey,
              isShowingSuggestion(subject: subject, body: body) else { return false }
        self.applied = nil
        return true
    }

    /// Fills the fields with a suggestion for the current index; otherwise
    /// withdraws an untouched draft left over from an older index. Nil leaves
    /// the fields alone: the request was superseded, or the user owns them.
    mutating func complete(
        _ id: UInt64,
        suggestion: CommitMessageSuggestion?,
        indexKey: String,
        subject: String,
        body: String
    ) -> Update? {
        guard let request = pending, request.id == id else { return nil }
        pending = nil
        if let suggestion, request.indexKey == indexKey, canFill(subject: subject, body: body) {
            applied = .init(subject: suggestion.subject, body: suggestion.body, indexKey: indexKey)
            return .fill(suggestion)
        }
        return withdrawStale(indexKey: indexKey, subject: subject, body: body) ? .clear : nil
    }

    /// True when the fields are blank or hold Alas's own untouched draft.
    func canFill(subject: String, body: String) -> Bool {
        Self.isBlank(subject: subject, body: body) || isShowingSuggestion(subject: subject, body: body)
    }

    private static func isBlank(subject: String, body: String) -> Bool {
        subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
