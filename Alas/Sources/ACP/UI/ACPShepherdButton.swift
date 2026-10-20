import SwiftUI

/// PR shepherd control in the ACP toolbar: a pill with a state symbol and
/// the request number (or "Ship" without one) that opens the shepherd
/// popover.
///
/// `session` is a plain reference on purpose: the pill reads only the
/// shepherd records and the cached review snapshot, so streaming updates
/// must not re-render the toolbar. The popover observes the transcript.
struct ACPShepherdButton: View {
    let session: ACPSession
    let worktree: Worktree
    let state: AppState
    @Environment(\.theme) private var theme
    @State private var open = false
    @State private var hovering = false

    /// Lit while the pointer is over the button or its popover is up, so the
    /// trigger stays visibly tied to the surface it opened.
    private var isLit: Bool { hovering || open }

    var body: some View {
        let context = ShepherdSessionContext(sessionID: session.id, worktree: worktree, state: state)
        let presentation = context.presentation
        let badge = presentation.badge
        let tooltip = presentation.tooltip
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: badge.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(badge.color(theme: theme))
                if let number = presentation.number {
                    Text(number)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                } else {
                    Text("Ship")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundStyle(theme.color(isLit ? "fg" : "fg-dim"))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(theme.color("bg-3").opacity(isLit ? 1 : 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.color("line"), lineWidth: 0.5))
            .aiBeam(isActive: badge.isActive, cornerRadius: 5)
        }
        .buttonStyle(.toolbarControl)
        .onHover { hovering = $0 }
        .help(tooltip)
        .accessibilityLabel("PR shepherd")
        .accessibilityValue(tooltip)
        .popover(isPresented: $open, arrowEdge: .top) {
            ShepherdPopover(
                session: session,
                transcript: session.transcript,
                worktree: worktree,
                state: state,
                onClose: { open = false }
            )
        }
    }
}

/// What the toolbar knows about one session's PR: the session's own record,
/// another session's live record for the same worktree, and the freshest
/// snapshot (the shepherd's, else the Changes pane's cached one, else a
/// fetch the popover made). With a bound record, only a snapshot carrying
/// that exact request counts.
@MainActor
struct ShepherdSessionContext {
    let record: ShepherdRecord?
    /// A non-terminal record owned by a different session in this worktree.
    let otherRecord: ShepherdRecord?
    let snapshot: ReviewLoopSnapshot?
    /// The shepherd's own merge gate from its latest decision on the bound
    /// record; nil without one.
    private let shepherdGatePasses: Bool?

    init(sessionID: String, worktree: Worktree, state: AppState, fetched: ReviewLoopSnapshot? = nil) {
        let shepherd = state.reviewShepherd
        let own = shepherd.record(forSession: sessionID)
        let worktreeRecord = shepherd.record(forWorktree: worktree.id)
        record = own
        if own == nil, let worktreeRecord, worktreeRecord.sessionID != sessionID, !worktreeRecord.phase.isTerminal {
            otherRecord = worktreeRecord
        } else {
            otherRecord = nil
        }
        let pane = state.rightPaneStore.activeState(worktreeId: worktree.id)?.reviewLoop.snapshot
        if let bound = own ?? otherRecord {
            // The pane may cache another PR, or none, for this worktree.
            snapshot = [shepherd.snapshots[bound.id], pane, fetched]
                .lazy
                .compactMap { $0 }
                .first { Self.carries(bound.id, $0) }
        } else {
            snapshot = pane ?? fetched
        }
        shepherdGatePasses = own.map { shepherd.gatePasses[$0.id] ?? false }
    }

    private static func carries(_ id: ShepherdRecordID, _ snapshot: ReviewLoopSnapshot) -> Bool {
        guard let request = snapshot.reviewRequest else { return false }
        return ShepherdRecordID(worktreeID: id.worktreeID, request: request) == id
    }

    /// The request this context describes; with a bound record, always that
    /// record's request.
    var request: ReviewRequest? { snapshot?.reviewRequest }

    /// A bound record uses the shepherd's full gate (head stability and
    /// required reviewers included); without one, the readiness half.
    var mergeGatePasses: Bool {
        if let shepherdGatePasses { return shepherdGatePasses }
        guard let snapshot, request != nil else { return false }
        return ReviewReadinessModel.canMergeReviewRequest(snapshot: snapshot)
    }

    var presentation: ShepherdPresentation {
        ShepherdPresentation.make(record: record, request: request, mergeGatePasses: mergeGatePasses)
    }
}

extension ShepherdBadgeState {
    /// Symbol shared by the toolbar pill and the popover's phase line.
    var symbolName: String {
        switch self {
        case .noRequest: "arrow.up.circle"
        case .unshepherded: "arrow.triangle.pull"
        case .waiting: "clock.fill"
        case .fixing: "sparkles"
        case .ready, .merging: "arrow.triangle.merge"
        case .queued: "list.bullet.rectangle"
        case .attention: "exclamationmark.triangle.fill"
        case .merged: "checkmark.circle.fill"
        case .closed: "xmark.circle"
        }
    }

    func color(theme: Theme) -> Color {
        switch self {
        case .noRequest, .unshepherded, .closed: theme.color("fg-muted")
        case .waiting: theme.color("warn")
        case .fixing: theme.color("accent")
        case .ready, .merging, .queued: theme.color("add")
        case .attention: theme.color("del")
        case .merged: Color(nsColor: .systemPurple)
        }
    }
}

extension ShepherdPhase {
    /// Escalated and paused records wait for the user to press Resume.
    var isResumable: Bool {
        switch self {
        case .escalated, .paused: true
        default: false
        }
    }
}

private struct ShepherdPopover: View {
    let session: ACPSession
    @ObservedObject var transcript: ACPTranscript
    let worktree: Worktree
    let state: AppState
    let onClose: () -> Void
    @Environment(\.theme) private var theme
    @State private var fetchedSnapshot: ReviewLoopSnapshot?
    @State private var isLoading = true
    @State private var rules: ShepherdRules = .none
    /// The rules files could not be read: the popover keeps the shepherd's
    /// own merge gate rather than judge it without them.
    @State private var rulesUnreadable = false
    @State private var reviewerResult: ReviewerResult?

    private var isBusy: Bool { transcript.streamingState != .idle }

    var body: some View {
        let context = ShepherdSessionContext(
            sessionID: session.id, worktree: worktree, state: state, fetched: fetchedSnapshot
        )
        VStack(alignment: .leading, spacing: 0) {
            if let record = context.record {
                boundContent(record: record, context: context)
            } else {
                unboundContent(context: context)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 340)
        .background(theme.color("bg-1"))
        .task(id: session.id) { await load() }
        .task(id: isLoading ? nil : reviewerKey(context)) { await loadReviewers() }
    }

    // MARK: Loading

    private func load() async {
        let settings = state.projectsManager.projects.first(where: { $0.id == worktree.projectId })?.shepherd
        let root = worktree.path
        do {
            rules = try await ShepherdRulesResolver.load(worktreePath: root, projectSettings: settings)
            rulesUnreadable = false
        } catch {
            rules = .none
            rulesUnreadable = true
        }
        let context = ShepherdSessionContext(sessionID: session.id, worktree: worktree, state: state)
        // Read-only fetches: the UI never runs the shepherd policy.
        if context.request == nil, let bound = context.record ?? context.otherRecord {
            fetchedSnapshot = await state.reviewShepherd.statusSnapshot(for: bound.id)
        } else if context.snapshot == nil {
            fetchedSnapshot = await state.reviewShepherd.fetchSnapshot(
                worktreePath: worktree.path,
                baseBranch: state.shepherdBaseBranch(for: worktree)
            )
        }
        isLoading = false
    }

    /// Required-reviewer evidence belongs to one bound request head and the
    /// time Alas first saw it. A new head, a different record or the policy
    /// recording when it first saw the head changes the key, which restarts
    /// the load and hides the old result.
    private struct ReviewerKey: Hashable {
        let id: ShepherdRecordID
        let headSHA: String?
        let headFirstSeenAt: Date?
    }

    private struct ReviewerResult {
        let key: ReviewerKey
        /// Lowercased logins, or nil when the provider couldn't tell.
        let logins: Set<String>?
    }

    private func reviewerKey(_ context: ShepherdSessionContext) -> ReviewerKey? {
        guard let record = context.record, let request = context.request else { return nil }
        return ReviewerKey(
            id: record.id,
            headSHA: request.headSHA,
            headFirstSeenAt: record.headFirstSeenAt(of: request.headSHA)
        )
    }

    /// The loaded evidence for the context's current head, or nil while it loads.
    private func reviewers(for context: ShepherdSessionContext) -> ReviewerResult? {
        guard let key = reviewerKey(context), let reviewerResult, reviewerResult.key == key else { return nil }
        return reviewerResult
    }

    private func loadReviewers() async {
        guard !isLoading, !rules.requiredReviewers.isEmpty else { return }
        let context = ShepherdSessionContext(
            sessionID: session.id, worktree: worktree, state: state, fetched: fetchedSnapshot
        )
        guard let key = reviewerKey(context), let snapshot = context.snapshot else { return }
        let logins = await state.reviewShepherd.headReviewers(
            for: snapshot,
            worktreePath: worktree.path,
            notBefore: key.headFirstSeenAt
        )
        guard !Task.isCancelled else { return }
        reviewerResult = ReviewerResult(key: key, logins: logins)
    }

    // MARK: Bound

    @ViewBuilder
    private func boundContent(record: ShepherdRecord, context: ShepherdSessionContext) -> some View {
        let request = context.request
        let presentation = exactPresentation(record: record, context: context)
        header(record: record, request: request)
        Divider().background(theme.color("line"))
        if let request {
            if request.checks.isEmpty {
                infoLine("No CI checks", systemImage: "checkmark.seal")
            } else {
                CIStatusStrip(checks: request.checks, maxVisibleRows: 8)
            }
            reviewLines(request: request, reviewers: reviewers(for: context))
        } else {
            infoLine("Waiting for the first status check.", systemImage: "hourglass")
        }
        Divider().background(theme.color("line"))
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: presentation.badge.symbolName)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(presentation.badge.color(theme: theme))
                Text(presentation.phaseLine)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(theme.color("fg"))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 4) {
                Text("Attempt \(record.fixAttempts) of \(record.fixAttemptBudget)")
                Stepper(
                    "Fix attempts",
                    value: Binding(
                        get: { record.fixAttemptBudget },
                        set: { state.reviewShepherd.setMaxFixAttempts($0, for: record.id) }
                    ),
                    in: ShepherdPolicy.fixAttemptRange
                )
                .labelsHidden()
                .controlSize(.mini)
                .disabled(record.phase.isTerminal)
                .help("Fix prompts sent before the shepherd stops and asks for you")
                Text("· Rules: \(rulesUnreadable ? "unreadable" : rules.sourceLabel ?? "none")")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(theme.color("fg-muted"))
            ShepherdSwitchRow(
                title: "Auto-fix",
                detail: "CI failures, conflicts and reviewer threads go back to this session",
                isOn: record.autoFix,
                isDisabled: record.phase.isTerminal
            ) { isOn in
                state.reviewShepherd.setAutoFix(isOn, for: record.id)
            }
            ShepherdSwitchRow(
                title: "Auto-merge",
                detail: "Squash-merge once checks, reviewers and the head are settled",
                isOn: record.autoMerge,
                isDisabled: record.phase.isTerminal
            ) { isOn in
                state.reviewShepherd.setAutoMerge(isOn, for: record.id)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        Divider().background(theme.color("line"))
        footer(record: record)
    }

    /// Once `load()` has the rules and head reviewers, use the policy's exact
    /// merge gate on this fresh data instead of the shepherd's gate from its
    /// last poll, which the toolbar badge uses. Until the reviewers for the
    /// current head arrive, `headReviewers` is nil and the gate fails closed
    /// when the rules require any.
    private func exactPresentation(record: ShepherdRecord, context: ShepherdSessionContext) -> ShepherdPresentation {
        guard !isLoading, !rulesUnreadable, let snapshot = context.snapshot, context.request != nil else {
            return context.presentation
        }
        let observation = ShepherdObservation(
            snapshot: snapshot,
            headReviewers: reviewers(for: context)?.logins,
            session: isBusy ? .busy : .idle,
            rules: rules,
            now: Date()
        )
        return ShepherdPresentation.make(
            record: record,
            request: context.request,
            mergeGatePasses: ShepherdPolicy.mergeGatePasses(record, observation)
        )
    }

    private func header(record: ShepherdRecord, request: ReviewRequest?) -> some View {
        let kind = record.id.providerKind
        let number = "\(kind.reviewRequestNumberPrefix)\(record.id.requestNumber)"
        let url = request?.url ?? record.remote.reviewRequestURL(number: record.id.requestNumber)
        let shortSHA = (request?.headSHA ?? record.lastSeenHeadSHA).map { String($0.prefix(7)) }
        let parts: [String?] = ["\(record.branch) → \(record.baseBranch)", shortSHA, kind.displayName]
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(number)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.color("accent"))
                Text(request?.title ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.color("fg"))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11))
                }
                .foregroundStyle(theme.color("fg-muted"))
                .help("Open \(kind.reviewRequestLabel) \(number) in the browser")
                .accessibilityLabel("Open \(kind.reviewRequestLabel) \(number) in the browser")
            }
            Text(parts.compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.color("fg-muted"))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func reviewLines(request: ReviewRequest, reviewers: ReviewerResult?) -> some View {
        let openThreads = request.threads.filter(\.isActionable)
        let trusted = openThreads.filter { $0.headAuthorTrust == .trusted }.count
        let threadText = openThreads.isEmpty
            ? "No open review threads"
            : "\(openThreads.count) open thread\(openThreads.count == 1 ? "" : "s"), \(trusted) from trusted reviewers"
        return VStack(alignment: .leading, spacing: 4) {
            Text(threadText)
            if let reviewersText = requiredReviewersText(reviewers) {
                Text(reviewersText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(theme.color("fg-dim"))
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func requiredReviewersText(_ reviewers: ReviewerResult?) -> String? {
        guard !rules.requiredReviewers.isEmpty else { return nil }
        guard let reviewers else { return "Checking required reviewers…" }
        guard let headReviewers = reviewers.logins else { return "Couldn't check required reviewers." }
        let missing = rules.requiredReviewers.filter { !headReviewers.contains($0.lowercased()) }
        if missing.isEmpty { return "Required reviewers have reviewed this head." }
        return "Waiting on this head: " + missing.map { "@\($0)" }.joined(separator: ", ")
    }

    private func footer(record: ShepherdRecord) -> some View {
        let label = record.id.providerKind.reviewRequestLabel
        return HStack(spacing: 8) {
            Button("Open in Changes") {
                onClose()
                Task {
                    let revealed = await state.rightPaneStore.revealAttentionTarget(
                        .reviewRequest(number: record.id.requestNumber),
                        for: worktree
                    )
                    if !revealed { state.config.rightPaneVisible = true }
                }
            }
            .help("Show this \(label) in the Changes review drawer")
            if record.phase.isResumable {
                Button("Resume") {
                    state.reviewShepherd.resume(record.id)
                }
                .help("Watch again and reset the fix attempt count")
            }
            Spacer(minLength: 0)
            Button("Stop shepherding") {
                state.reviewShepherd.stopShepherding(record.id)
            }
            .help("Stop watching. The \(label) stays open.")
        }
        .controlSize(.small)
        .font(.system(size: 11))
        .padding(12)
    }

    // MARK: Unbound

    @ViewBuilder
    private func unboundContent(context: ShepherdSessionContext) -> some View {
        let snapshot = context.snapshot
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color("fg-muted"))
                Text(worktree.branch)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let local = snapshot?.local {
                    Text("\(local.aheadCommitCount) ahead of \(local.baseBranch)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.color("fg-muted"))
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            if let other = context.otherRecord {
                adoptRow(
                    text: "\(other.id.providerKind.reviewRequestLabel) \(other.id.providerKind.reviewRequestNumberPrefix)\(other.id.requestNumber) is shepherded by another session.",
                    buttonTitle: "Move to this session",
                    request: context.request
                )
            } else if let request = context.request, request.state == .open {
                let number = "\(request.provider.reviewRequestNumberPrefix)\(request.number)"
                adoptRow(
                    text: "\(request.provider.reviewRequestLabel) \(number) is open: \(request.title)",
                    buttonTitle: "Shepherd \(number) from this session",
                    request: request
                )
            } else {
                createRow(kind: snapshot?.remote?.kind, reason: ShepherdShipAction.createUnavailableReason(
                    isBusy: isBusy, snapshot: snapshot, isLoading: isLoading
                ))
            }
        }
        .padding(12)
    }

    private func adoptRow(text: String, buttonTitle: String, request: ReviewRequest?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(theme.color("fg-dim"))
                .fixedSize(horizontal: false, vertical: true)
            AlasButton(title: buttonTitle, style: .primary) {
                guard let request else { return }
                onClose()
                Task { await state.shepherdWithSession(session.id, worktree: worktree, request: request) }
            }
            .disabled(request == nil)
            .opacity(request == nil ? 0.5 : 1)
            .help(request == nil ? "Waiting for the PR status" : "Bind this PR to this session and send it the current problems")
            .accessibilityLabel(buttonTitle)
        }
    }

    private func createRow(kind: CodeHostKind?, reason: String?) -> some View {
        let title = "Ship with agent"
        let label = kind?.reviewRequestLabel ?? "PR"
        return VStack(alignment: .leading, spacing: 6) {
            AlasButton(title: title, icon: "sparkles", style: .primary) {
                onClose()
                state.requestShepherdCreatePR(sessionID: session.id, worktree: worktree)
            }
            .disabled(reason != nil)
            .opacity(reason == nil ? 1 : 0.5)
            .help(reason ?? "Ask this session to open a \(label) and shepherd it")
            .accessibilityLabel(title)
            Text(reason ?? "The agent writes, opens and shepherds the \(label)")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.color(reason == nil ? "fg-muted" : "warn"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Pieces

    private func infoLine(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(theme.color("fg-dim"))
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}
