import Foundation

struct NewWorktreeLaunchPreference: Equatable {
    let openAfterCreate: Bool
    let launchMode: AppConfig.LauncherMode
    let persistableLaunchMode: AppConfig.LauncherMode
    let launchAgentID: String
}

struct NewWorktreeIssueAttachEffects: Equatable {
    let preferredProjectID: String?
    let branchSeed: String
    let shouldSelectChat: Bool
}

struct NewWorktreeNameSuggestionRequest: Equatable {
    let id: UInt64
    let source: IssueSnapshot
}

struct NewWorktreeIssueState: Equatable {
    private struct PendingNameSuggestion: Equatable {
        let id: UInt64
        let seed: String
        let displayReference: String?
        var userEditedName = false
    }

    private(set) var draft: AttachedIssueDraft?
    private var capturedLaunchPreference: NewWorktreeLaunchPreference?
    private var nameSuggestionGeneration: UInt64 = 0
    private var pendingNameSuggestion: PendingNameSuggestion?

    mutating func attach(
        _ draft: AttachedIssueDraft,
        currentLaunch: NewWorktreeLaunchPreference
    ) -> NewWorktreeIssueAttachEffects {
        if self.draft == nil {
            capturedLaunchPreference = currentLaunch
        }
        self.draft = draft
        pendingNameSuggestion = nil
        return NewWorktreeIssueAttachEffects(
            preferredProjectID: draft.projectID,
            branchSeed: draft.branchSeed,
            shouldSelectChat: true
        )
    }

    /// Starts tracking a semantic-name request for the attached draft's seed.
    /// Any earlier request becomes stale.
    mutating func beginNameSuggestion() -> NewWorktreeNameSuggestionRequest? {
        guard let draft, !draft.branchSeed.isEmpty else { return nil }
        nameSuggestionGeneration &+= 1
        pendingNameSuggestion = .init(
            id: nameSuggestionGeneration,
            seed: draft.branchSeed,
            displayReference: draft.source.displayReference
        )
        return .init(id: nameSuggestionGeneration, source: draft.source)
    }

    /// Records that the user typed into the branch or stack name. Ownership
    /// covers both fields (gg's availability probe can carry one into the
    /// other) and sticks even if the text returns to the seed, so a pending
    /// suggestion never overwrites a name the user deliberately restored.
    mutating func recordUserNameEdit() {
        pendingNameSuggestion?.userEditedName = true
    }

    /// Swaps the seed's title component for `semanticName` in whichever name
    /// field still holds the seed. Returns nil (keep the fields) when the
    /// request is stale, the model produced nothing usable, or the user has
    /// edited the name since the seed was applied.
    mutating func completeNameSuggestion(
        _ id: UInt64,
        semanticName: String?,
        branch: String,
        stackName: String
    ) -> (branch: String, stackName: String)? {
        guard let pending = pendingNameSuggestion, pending.id == id else { return nil }
        pendingNameSuggestion = nil
        guard let semanticName else { return nil }
        let suggested = IssueBranchName.make(displayReference: pending.displayReference, title: semanticName)
        guard !pending.userEditedName else { return nil }
        let replacesBranch = branch == pending.seed
        let replacesStack = stackName == pending.seed
        guard !suggested.isEmpty, suggested != pending.seed, replacesBranch || replacesStack else { return nil }
        return (
            replacesBranch ? suggested : branch,
            replacesStack ? suggested : stackName
        )
    }

    mutating func remove() -> NewWorktreeLaunchPreference? {
        pendingNameSuggestion = nil
        guard draft != nil else { return nil }
        draft = nil
        let preference = capturedLaunchPreference
        capturedLaunchPreference = nil
        return preference
    }

    mutating func recordLaunchPreferenceChangeAfterAttach() {
        guard draft != nil else { return }
        capturedLaunchPreference = nil
    }
}
