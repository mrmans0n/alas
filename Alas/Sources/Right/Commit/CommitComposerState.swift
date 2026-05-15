import Foundation
import Observation

@Observable
@MainActor
final class CommitComposerState {
    // Draft fields
    var subject: String = ""
    var body: String = ""

    // Composer mode
    var expanded: Bool = false
    var amend: Bool = false
    var amendWarning: Bool = false   // soft "rewrites history" notice

    // True when HEAD points to a real commit. False on an unborn branch
    // (fresh `git init` with no commits yet) — in that state amending is
    // impossible because there's nothing to amend, so the toggle should
    // be disabled. Defaults to true so we don't briefly disable the
    // control during the very first refresh.
    var canAmend: Bool = true

    // Generation
    var busy: Bool = false
    var error: String? = nil
    @ObservationIgnored
    var generation: Task<Void, Never>? = nil

    // Amend prefill bookkeeping — when we prefilled subject/body from
    // HEAD, we remember exactly what we wrote so toggling Amend off
    // can clear our prefill without clobbering user edits.
    @ObservationIgnored
    var amendPrefilled: Bool = false
    @ObservationIgnored
    private var prefilledSubject: String = ""
    @ObservationIgnored
    private var prefilledBody: String = ""

    func canCommit(stagedCount: Int) -> Bool {
        stagedCount > 0
            && !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !busy
    }

    func applyAmendPrefill(_ prior: GitService.HeadMessage) {
        let blankSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let blankBody = body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard blankSubject && blankBody else { return }
        subject = prior.subject
        body = prior.body
        prefilledSubject = prior.subject
        prefilledBody = prior.body
        amendPrefilled = true
    }

    func clearAmendPrefillIfUnchanged() {
        guard amendPrefilled else { return }
        guard subject == prefilledSubject && body == prefilledBody else { return }
        subject = ""
        body = ""
        amendPrefilled = false
        prefilledSubject = ""
        prefilledBody = ""
    }

    func resetAfterCommit() {
        subject = ""
        body = ""
        amend = false
        amendWarning = false
        amendPrefilled = false
        prefilledSubject = ""
        prefilledBody = ""
        expanded = false
        error = nil
    }
}
