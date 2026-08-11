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

struct NewWorktreeIssueState: Equatable {
    private(set) var draft: AttachedIssueDraft?
    private var capturedLaunchPreference: NewWorktreeLaunchPreference?

    mutating func attach(
        _ draft: AttachedIssueDraft,
        currentLaunch: NewWorktreeLaunchPreference
    ) -> NewWorktreeIssueAttachEffects {
        if self.draft == nil {
            capturedLaunchPreference = currentLaunch
        }
        self.draft = draft
        return NewWorktreeIssueAttachEffects(
            preferredProjectID: draft.projectID,
            branchSeed: draft.branchSeed,
            shouldSelectChat: true
        )
    }

    mutating func remove() -> NewWorktreeLaunchPreference? {
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
