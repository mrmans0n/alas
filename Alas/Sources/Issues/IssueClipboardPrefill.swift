import Foundation

enum IssueClipboardPrefill {
    private static let maximumLength = 8_192

    static func candidate(from clipboardText: String?) -> String? {
        guard let clipboardText,
              clipboardText.count <= maximumLength
        else {
            return nil
        }

        let candidate = clipboardText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              !candidate.contains(where: \.isNewline),
              case .url = try? IssueReference.parse(candidate)
        else {
            return nil
        }
        return candidate
    }
}

/// A clipboard link the New Worktree dialog offers to attach in one click.
struct IssueClipboardTicket: Equatable {
    let reference: String
    /// Set for GitHub and GitLab issue links, whose mark replaces the generic
    /// ticket glyph. Any other URL can still be attached as a manual ticket.
    let codeHost: CodeHostKind?

    init?(clipboardText: String?) {
        guard let reference = IssueClipboardPrefill.candidate(from: clipboardText) else { return nil }
        self.reference = reference
        if case .url(let kind, _, _, _) = try? CodeHostIssueInput.parse(reference) {
            codeHost = kind
        } else {
            codeHost = nil
        }
    }

    /// An `Icon` name: the provider's mark, else the SF Symbol `ticket`.
    var iconName: String {
        switch codeHost {
        case .github: "github"
        case .gitlab: "gitlab"
        case nil: "ticket"
        }
    }
}
