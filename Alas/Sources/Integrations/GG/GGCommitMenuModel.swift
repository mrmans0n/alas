import Foundation

enum GGCommitAction: Hashable, Sendable {
    case reviewProviderRequest(number: Int, url: URL)
    case openProviderRequest(number: Int)
    case checkout
    case splitCommit
    case dropCommit
    case unstackHere
    case landThrough
}

struct GGCommitMenuContext: Equatable {
    let entry: GGStackEntry
    let stack: GGStack
    let provider: CodeHostKind?
    let capabilities: GGCapabilities
    let inFlightAction: GGStackActionKind?
    let pausedOperation: GGPausedOperation?
    let hasBlockingGitOperation: Bool
    let selectionIsStale: Bool
    var canOpenSplitCommit: Bool = false
    var providerReviewURL: URL?
}

struct GGCommitMenuItem: Identifiable, Equatable {
    enum ID: Hashable {
        case reviewProviderRequest
        case openProviderRequest
        case remoteSeparator
        case checkout
        case splitCommit
        case lifecycleSeparator
        case dropCommit
        case unstackHere
        case landThrough
    }

    let id: ID
    let title: String?
    let systemImage: String?
    let action: GGCommitAction?
    let isVisible: Bool
    let isEnabled: Bool
    let disabledReason: String?

    var isSeparator: Bool { action == nil }
}

struct GGCommitMenuModel: Equatable {
    let items: [GGCommitMenuItem]

    var visibleItems: [GGCommitMenuItem] {
        items.filter(\.isVisible)
    }

    func item(for action: GGCommitAction) -> GGCommitMenuItem? {
        items.first { $0.action == action }
    }

    static func make(context: GGCommitMenuContext) -> GGCommitMenuModel {
        let reviewNumber = context.entry.prNumber
        let reviewLabel = context.provider?.reviewRequestLabel ?? "PR"
        let reviewURL = context.providerReviewURL
        let hasProviderReview = context.provider != nil && reviewNumber != nil && reviewURL != nil
        let mutationReason = mutationDisabledReason(context: context)
        let immutableReason = context.entry.prState == .merged
            ? "Merged commits cannot be rewritten."
            : nil

        func actionItem(
            id: GGCommitMenuItem.ID,
            title: String,
            systemImage: String,
            action: GGCommitAction?,
            isVisible: Bool = true,
            disabledReason: String? = nil
        ) -> GGCommitMenuItem {
            GGCommitMenuItem(
                id: id,
                title: title,
                systemImage: systemImage,
                action: action,
                isVisible: isVisible,
                isEnabled: disabledReason == nil,
                disabledReason: disabledReason
            )
        }

        func separator(_ id: GGCommitMenuItem.ID, isVisible: Bool = true) -> GGCommitMenuItem {
            GGCommitMenuItem(
                id: id,
                title: nil,
                systemImage: nil,
                action: nil,
                isVisible: isVisible,
                isEnabled: false,
                disabledReason: nil
            )
        }

        let reviewAction = reviewNumber.flatMap { number in
            reviewURL.map { GGCommitAction.reviewProviderRequest(number: number, url: $0) }
        }
        let openAction = GGCommitAction.openProviderRequest(number: reviewNumber ?? 0)
        let splitReason = mutationReason
            ?? (context.capabilities.structuredSplit ? nil : "Update GG to use native Split Commit")
            ?? (context.canOpenSplitCommit ? nil : "Native Split Commit is unavailable.")
            ?? immutableReason
        let rewriteReason = mutationReason ?? immutableReason
        let unstackReason = rewriteReason ?? (
            context.entry.position == context.stack.entries.map(\.position).min()
                ? "Select a commit above the bottom of the stack."
                : nil
        )
        let landReason = mutationReason ?? landDisabledReason(context: context)

        return GGCommitMenuModel(items: [
            actionItem(
                id: .reviewProviderRequest,
                title: "Review \(reviewLabel) in Alas...",
                systemImage: "text.bubble",
                action: reviewAction,
                isVisible: hasProviderReview
            ),
            actionItem(
                id: .openProviderRequest,
                title: "Open \(reviewLabel) in Browser",
                systemImage: "safari",
                action: openAction,
                isVisible: hasProviderReview
            ),
            separator(.remoteSeparator, isVisible: hasProviderReview),
            actionItem(
                id: .checkout,
                title: "Checkout Commit",
                systemImage: "arrow.triangle.branch",
                action: .checkout,
                isVisible: !context.entry.isCurrent,
                disabledReason: mutationReason
            ),
            actionItem(
                id: .splitCommit,
                title: "Split Commit...",
                systemImage: "square.split.2x1",
                action: .splitCommit,
                disabledReason: splitReason
            ),
            separator(.lifecycleSeparator),
            actionItem(
                id: .dropCommit,
                title: "Drop Commit...",
                systemImage: "trash",
                action: .dropCommit,
                disabledReason: rewriteReason
            ),
            actionItem(
                id: .unstackHere,
                title: "Split Stack Here...",
                systemImage: "arrow.trianglehead.branch",
                action: .unstackHere,
                disabledReason: unstackReason
            ),
            actionItem(
                id: .landThrough,
                title: "Land Through Here...",
                systemImage: "arrow.down.to.line",
                action: .landThrough,
                disabledReason: landReason
            ),
        ])
    }

    private static func mutationDisabledReason(context: GGCommitMenuContext) -> String? {
        if context.selectionIsStale {
            return "The stack changed. Refresh and try again."
        }
        if context.pausedOperation != nil {
            return "Continue or abort the paused GG operation first."
        }
        if context.inFlightAction != nil {
            return "Another GG operation is running."
        }
        if context.hasBlockingGitOperation {
            return "Finish the current Git operation first."
        }
        return nil
    }

    private static func landDisabledReason(context: GGCommitMenuContext) -> String? {
        guard context.entry.prState == .open,
              context.entry.approved,
              context.entry.ciStatus == nil || context.entry.ciStatus == .success
        else { return "This commit is not ready to land." }

        let lowerEntriesAreReady = context.stack.entries
            .filter { $0.position < context.entry.position }
            .allSatisfy { entry in
                entry.prState == .merged
                    || (entry.prState == .open
                        && entry.approved
                        && (entry.ciStatus == nil || entry.ciStatus == .success))
            }
        return lowerEntriesAreReady ? nil : "A lower commit is not ready to land."
    }
}
