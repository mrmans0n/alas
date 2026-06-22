import Foundation

struct PendingStashDrop: Equatable {
    let stash: GitStash

    static func alertTitle(for pending: PendingStashDrop) -> String {
        "Drop \(pending.stash.ref)?"
    }

    static func alertMessage(for pending: PendingStashDrop) -> String {
        "This permanently deletes \"\(pending.stash.subject)\" from the stash list. This cannot be undone."
    }
}

extension PendingStashDrop {
    static let placeholder = PendingStashDrop(
        stash: GitStash(ref: "stash@{0}", subject: "stash", relativeTime: "", sha: "")
    )
}
