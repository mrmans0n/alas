import Foundation

public enum GGCommitAction: Hashable, Sendable {
    case reviewProviderRequest(number: Int, url: URL)
    case openProviderRequest(number: Int)
    case checkout
    case splitCommit
    case dropCommit
    case unstackHere
    case landThrough
}

public struct GGCommitMenuContext: Equatable, Sendable {
    public let entry: GGStackEntry
    public let stack: GGStack
    public let provider: CodeHostKind?
    public let capabilities: GGCapabilities
    public let inFlightAction: GGStackActionKind?
    public let pausedOperation: GGPausedOperation?
    public let hasBlockingGitOperation: Bool
    public let selectionIsStale: Bool
    public var canOpenSplitCommit: Bool = false
    public var providerReviewURL: URL?

    public init(entry: GGStackEntry, stack: GGStack, provider: CodeHostKind?, capabilities: GGCapabilities, inFlightAction: GGStackActionKind?, pausedOperation: GGPausedOperation?, hasBlockingGitOperation: Bool, selectionIsStale: Bool, canOpenSplitCommit: Bool = false, providerReviewURL: URL? = nil) {
        self.entry = entry
        self.stack = stack
        self.provider = provider
        self.capabilities = capabilities
        self.inFlightAction = inFlightAction
        self.pausedOperation = pausedOperation
        self.hasBlockingGitOperation = hasBlockingGitOperation
        self.selectionIsStale = selectionIsStale
        self.canOpenSplitCommit = canOpenSplitCommit
        self.providerReviewURL = providerReviewURL
    }
}

public struct GGCommitMenuItem: Identifiable, Equatable, Sendable {
    public enum ID: Hashable, Sendable {
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

    public let id: ID
    public let title: String?
    public let systemImage: String?
    public let action: GGCommitAction?
    public let isVisible: Bool
    public let isEnabled: Bool
    public let disabledReason: String?

    public var isSeparator: Bool { action == nil }

    public init(id: ID, title: String?, systemImage: String?, action: GGCommitAction?, isVisible: Bool, isEnabled: Bool, disabledReason: String?) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.action = action
        self.isVisible = isVisible
        self.isEnabled = isEnabled
        self.disabledReason = disabledReason
    }
}

public struct GGCommitMenuModel: Equatable, Sendable {
    public let items: [GGCommitMenuItem]

    public var visibleItems: [GGCommitMenuItem] {
        items.filter(\.isVisible)
    }

    public func item(for action: GGCommitAction) -> GGCommitMenuItem? {
        items.first { $0.action == action }
    }

    public static func make(context: GGCommitMenuContext) -> GGCommitMenuModel {
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
        GGLandReadiness.blocker(
            target: context.entry,
            in: context.stack,
            canWaitForReadiness: context.capabilities.landJSONL
        )?.message(reviewLabel: context.provider?.reviewRequestLabel ?? "PR")
    }

    public init(items: [GGCommitMenuItem]) {
        self.items = items
    }
}
