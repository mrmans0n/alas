import SwiftUI

/// Everything `ACPPermissionCard` renders, folded out of the transport that
/// carried the request: the local `_meta`-bearing ACP params or the flattened
/// payload a peer forwards.
struct ACPPermissionCardContent: Equatable {
    struct Option: Equatable, Identifiable {
        let optionId: String
        let name: String
        let kind: String        // "allow_once" | "allow_always" | "reject_once" | "reject_always"
        let description: String?
        var id: String { optionId }
    }

    /// `_meta.permission.title`; nil falls back to the generic "Allow this?".
    let heading: String?
    let kind: String?
    let mcpServerName: String?
    /// The command or tool title, always shown in monospace.
    let title: String
    /// Optional preview block (stdin, script body). Dropped when it would
    /// only repeat `title`.
    let summary: String?
    /// `_meta.permission.description`, the reason line under the summary.
    let reason: String?
    let defaultToNo: Bool
    let options: [Option]
    /// The proposed change, shown for review only: it never decides the
    /// options or the default answer.
    let diffSections: [ACPToolCallDiffSection]

    /// `existingToolCall` is the transcript row with the request's
    /// `toolCallId`; its diffs preview a request that carries none (Codex).
    init(
        params: ACPPermissionRequestParams,
        existingToolCall: ACPMessage.ToolCall? = nil,
        worktreeRoot: String? = nil
    ) {
        let presentation = ACPPermissionPresentation(metadata: params.metadata)
        var summary: String?
        for block in params.toolCall.content ?? [] {
            if case .content(.text(let text)) = block {
                summary = text
                break
            }
        }
        self.init(
            heading: presentation?.title,
            kind: params.toolCall.kind,
            mcpServerName: params.toolCall.mcpServerName,
            title: params.toolCall.title ?? params.toolCall.toolCallId,
            summary: summary,
            reason: presentation?.description,
            defaultToNo: presentation?.defaultToNo ?? false,
            options: Self.options(of: params),
            diffSections: ACPToolCallPresentation.diffSections(
                ACPToolCallDiff.permissionPreview(request: params.toolCall, existingRow: existingToolCall),
                status: "pending",
                worktreeRoot: worktreeRoot
            )
        )
    }

    init(payload: RemotePermissionPayload) {
        self.init(
            heading: payload.title,
            kind: nil,
            mcpServerName: payload.mcpServerName,
            title: payload.toolName,
            summary: payload.commandSummary,
            reason: payload.reason,
            defaultToNo: payload.defaultToNo,
            options: payload.options.map {
                Option(optionId: $0.optionId, name: $0.name, kind: $0.kind, description: $0.description)
            }
        )
    }

    init(heading: String, title: String, reason: String, options: [Option]) {
        self.init(
            heading: heading, kind: nil, mcpServerName: nil, title: title,
            summary: nil, reason: reason, defaultToNo: false, options: options
        )
    }

    private init(
        heading: String?, kind: String?, mcpServerName: String?, title: String,
        summary: String?, reason: String?, defaultToNo: Bool, options: [Option],
        diffSections: [ACPToolCallDiffSection] = []
    ) {
        self.heading = Self.nonEmpty(heading)
        self.kind = Self.nonEmpty(kind)
        self.mcpServerName = Self.nonEmpty(mcpServerName)
        self.title = title
        self.summary = Self.nonEmpty(summary).flatMap { $0 == title ? nil : $0 }
        self.reason = Self.nonEmpty(reason)
        self.defaultToNo = defaultToNo
        self.options = options.map {
            Option(optionId: $0.optionId, name: $0.name, kind: $0.kind, description: Self.nonEmpty($0.description))
        }
        self.diffSections = diffSections
    }

    /// The request's options, as offered.
    static func options(of params: ACPPermissionRequestParams) -> [Option] {
        params.options.map {
            Option(optionId: $0.optionId, name: $0.name, kind: $0.kind, description: nonEmpty($0.presentationDescription))
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

/// Inline permission prompt for a local session. Resolves the pending
/// request through the runner's policy; the visuals live in
/// `ACPPermissionCard` so a mirrored peer session can show the same card.
struct ACPPermissionPrompt: View {
    @ObservedObject var session: ACPSession
    let policy: ACPPermissionPolicy
    let scopeKey: String
    var worktreeRoot: String? = nil
    /// Opens the plan review's file by its path on the session's host. Nil
    /// hides the action.
    var onOpenPlanFile: ((String) -> Void)? = nil
    @State private var contentCache = ACPPermissionCardContentCache()

    var body: some View {
        if let pending = session.transcript.pendingPermission {
            // The parked params and the policy's binding belong together:
            // the policy binds the request it parks as `pendingPermission`.
            if let review = ACPPlanReviewPresentation.make(
                params: pending.params, planFileNegotiated: session.planFile != nil,
                fileRead: session.planReviewFiles[pending.params.toolCall.toolCallId],
                binding: policy.planReviewBinding, planRevisions: session.planRevisions,
                contextResetCount: session.contextResetCount,
                foregroundTurnActive: session.foregroundTurnActive()) {
                ACPPlanReviewCard(
                    review: review,
                    options: ACPPermissionCardContent.options(of: pending.params),
                    defaultToNo: ACPPermissionPresentation(metadata: pending.params.metadata)?.defaultToNo ?? false,
                    onOpenFile: onOpenPlanFile
                ) { option in
                    choose(option: option, planDigest: review.digest)
                }
            } else {
                let existing = session.toolCall(
                    id: pending.params.toolCall.toolCallId, sessionId: pending.params.sessionId)
                ACPPermissionCard(
                    content: contentCache.content(
                        params: pending.params, existingToolCall: existing, worktreeRoot: worktreeRoot)
                ) { option in
                    handle(option: option, scopeKey: scopeKey)
                }
            }
        }
    }

    /// A plan review is never remembered, and its approval names the plan
    /// text the card showed.
    private func choose(option: ACPPermissionCardContent.Option, planDigest: String?) {
        let decision: ACPPermissionDecision = option.kind.hasPrefix("allow") ? .allow : .deny
        Task {
            await policy.userDecided(
                scopeKey: scopeKey, optionId: option.optionId, decision: decision,
                persistScope: nil, planDigest: planDigest)
        }
    }

    private func handle(option: ACPPermissionCardContent.Option, scopeKey: String) {
        let decision: ACPPermissionDecision = option.kind.hasPrefix("allow") ? .allow : .deny
        let persistScope: ACPPermissionScopeKind?
        switch option.kind {
        case "allow_once", "reject_once":     persistScope = nil
        case "allow_always", "reject_always": persistScope = .project
        default:                              persistScope = .session
        }
        Task {
            await policy.userDecided(
                scopeKey: scopeKey,
                optionId: option.optionId,
                decision: decision,
                persistScope: persistScope
            )
        }
    }
}

/// Keeps the last card content so a session update that leaves the request,
/// the row's diffs and the root alone does not re-parse the previewed patches.
private final class ACPPermissionCardContentCache {
    private struct Key: Equatable {
        let params: ACPPermissionRequestParams
        let rowDiffs: [ACPToolCallDiff]?
        let worktreeRoot: String?
    }

    private var key: Key?
    private var cached: ACPPermissionCardContent?

    func content(
        params: ACPPermissionRequestParams, existingToolCall: ACPMessage.ToolCall?, worktreeRoot: String?
    ) -> ACPPermissionCardContent {
        let key = Key(params: params, rowDiffs: existingToolCall?.diffs, worktreeRoot: worktreeRoot)
        if self.key == key, let cached { return cached }
        let content = ACPPermissionCardContent(
            params: params, existingToolCall: existingToolCall, worktreeRoot: worktreeRoot)
        self.key = key
        cached = content
        return content
    }
}

/// Inline permission card. Visual mirrors the design's pending edit card —
/// teal glow border, "Awaiting approval" pulse, body summary, sticky
/// Accept/Reject action row.
struct ACPPermissionCard: View {
    let content: ACPPermissionCardContent
    let onChoose: (ACPPermissionCardContent.Option) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            commandBody
            actionRow
        }
        .background(
            LinearGradient(
                colors: [theme.color("bg-2").opacity(0.6), theme.color("bg-1").opacity(0.6)],
                startPoint: .top, endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(theme.color("accent").opacity(0.55), lineWidth: 1)
        )
        .shadow(color: theme.color("accent").opacity(0.10), radius: 16, y: 4)
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
    }

    /// Header is a short status row only. The long command / details live
    /// in `commandBody` so they don't fight the title for space.
    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(theme.color("accent").opacity(0.18))
                Image(systemName: "hand.raised")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.color("accent"))
            }
            .frame(width: 18, height: 18)

            Text("Permission")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(theme.color("accent"))

            if let kind = content.kind {
                Text("· \(kind)")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color("fg-faint"))
            }

            if let server = content.mcpServerName {
                Text("· via \(server)")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color("fg-faint"))
            }

            Spacer(minLength: 6)

            PendingPulse()
                .frame(width: 6, height: 6)
            Text("Awaiting approval")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(theme.color("accent"))
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(theme.color("accent").opacity(0.08))
    }

    /// The actual `Allow … ?` body. Title (e.g. the command) sits on its
    /// own line; if the agent included a separate content block (e.g. a
    /// preview of stdin), that follows below in monospace. When the
    /// adapter attached `_meta.permission`, its `title` replaces the
    /// generic "Allow this?" heading and its `description` renders as a
    /// reason line under the command summary.
    private var commandBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(content.heading ?? "Allow this?")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(theme.color("fg-faint"))
            Text(content.title)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(theme.color("fg"))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(content.diffSections) { section in
                ACPToolCallDiffSectionView(section: section, collapsedMaxLines: 15)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(theme.color("line"), lineWidth: 0.5))
            }
            if let summary = content.summary {
                Text(summary)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(theme.color("fg-muted"))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(theme.color("bg-0").opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(theme.color("line"), lineWidth: 0.5))
            }
            if let reason = content.reason {
                Text(reason)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.color("fg-muted"))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 12)
    }

    /// Compact horizontal button row when no option carries a
    /// `_meta.permission.description` — pixel-identical to the pre-#1365
    /// layout. Collapses to a vertical, per-option list with secondary
    /// description text the moment any option has one.
    private var actionRow: some View {
        let hasDescriptions = content.options.contains { $0.description != nil }
        return Group {
            if hasDescriptions {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(content.options) { option in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Spacer()
                                optionButton(option)
                            }
                            if let description = option.description {
                                Text(description)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(theme.color("fg-faint"))
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Spacer()
                    ForEach(content.options) { option in
                        optionButton(option)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(theme.color("bg-1").opacity(0.55))
        .overlay(alignment: .top) {
            Rectangle().fill(theme.color("line-soft")).frame(height: 0.5)
        }
    }

    private func optionButton(_ option: ACPPermissionCardContent.Option) -> some View {
        ACPPermissionOptionButton(option: option, defaultToNo: content.defaultToNo) { onChoose(option) }
    }
}

/// One permission option as a button, styled by its kind.
struct ACPPermissionOptionButton: View {
    let option: ACPPermissionCardContent.Option
    let defaultToNo: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: glyph)
                    .font(.system(size: 10))
                Text(option.name)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(isDefaultStyled ? theme.color("accent") : theme.color("bg-3"))
            .foregroundStyle(isDefaultStyled ? theme.color("bg-0") : theme.color("fg"))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isDefaultStyled ? theme.color("accent") : theme.color("line"), lineWidth: 0.5)
            )
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(isDefaultAction ? .defaultAction : nil)
    }

    private var glyph: String {
        if option.kind == "reject_once" || option.kind == "reject_always" { return "xmark" }
        if option.kind == "allow_once" || option.kind == "allow_always" { return "checkmark" }
        return "circle"
    }

    /// The option that should carry default-button styling and the return
    /// key. Normally the once-only allow option; when the adapter set
    /// `_meta.permission.defaultToNo`, the once-only reject option takes
    /// its place instead.
    private var isDefaultStyled: Bool {
        defaultToNo ? option.kind == "reject_once" : option.kind == "allow_once"
    }

    /// Only bind the return key when the adapter explicitly asked for
    /// `defaultToNo` — untagged adapters keep the earlier behavior (no
    /// keyboard shortcut at all) per the #1365 acceptance criteria.
    private var isDefaultAction: Bool {
        defaultToNo && isDefaultStyled
    }
}

/// A plan review: the plan under review, its file's state, and the
/// request's options. Laid out like `ACPPlanApprovalPrompt`. Every label and
/// enablement comes from `ACPPlanReviewPresentation`; the options are the
/// request's own.
struct ACPPlanReviewCard: View {
    let review: ACPPlanReviewPresentation
    let options: [ACPPermissionCardContent.Option]
    let defaultToNo: Bool
    let onOpenFile: ((String) -> Void)?
    let onChoose: (ACPPermissionCardContent.Option) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 12) {
                planBody
                if let label = review.fileLabel {
                    ACPPlanFileLine(label: label, path: nil, onOpen: openAction)
                }
            }
            .padding(12)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 10) {
                    Spacer()
                    ForEach(options) { option in
                        ACPPermissionOptionButton(option: option, defaultToNo: defaultToNo) { onChoose(option) }
                            .disabled(review.disablesOption(kind: option.kind))
                    }
                }
                if review.isStale {
                    Text(ACPPlanReviewPresentation.staleNotice)
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.color("fg-faint"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(12)
            .background(theme.color("bg-0").opacity(0.45))
        }
        .background(theme.color("bg-1").opacity(0.96))
        .clipShape(.rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(theme.color("accent").opacity(0.55), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.color("accent"))
                .frame(width: 18, height: 18)
            Text("Plan review")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.color("accent"))
            if review.isOutOfTurn {
                Text("· Not in a turn")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color("fg-faint"))
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(theme.color("accent").opacity(0.08))
    }

    @ViewBuilder
    private var planBody: some View {
        if review.hasPlanText, let text = review.planText {
            // Plain while it fits, so a short plan stays compact; a
            // ScrollView would take the whole cap.
            ViewThatFits(in: .vertical) {
                ACPMarkdownText(raw: text, typography: .default)
                ScrollView { ACPMarkdownText(raw: text, typography: .default) }
            }
            .frame(maxHeight: 360)
        } else {
            Text(ACPPlanReviewPresentation.noPlanTextNotice)
                .font(.system(size: 12))
                .foregroundStyle(theme.color("fg-muted"))
        }
    }

    private var openAction: (() -> Void)? {
        guard let onOpenFile, let path = review.openableFilePath else { return nil }
        return { onOpenFile(path) }
    }
}

private struct PendingPulse: View {
    @State private var pulse = false
    @Environment(\.theme) private var theme
    var body: some View {
        Circle()
            .fill(theme.color("accent"))
            .overlay(
                Circle()
                    .strokeBorder(theme.color("accent").opacity(0.5), lineWidth: 2)
                    .scaleEffect(pulse ? 2.2 : 1)
                    .opacity(pulse ? 0 : 0.6)
                    .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: pulse)
            )
            .onAppear { pulse = true }
    }
}
