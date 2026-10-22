import SwiftUI

/// What the toolbar knows about one session's gg stack: the session's own
/// stack record, another session's live one for the same worktree, and the
/// shepherd's latest reads of the entries' requests.
@MainActor
struct StackShepherdSessionContext {
    let record: StackShepherdRecord?
    /// A live record a different session owns in this worktree.
    let otherRecord: StackShepherdRecord?
    let requests: [Int: ReviewRequest]
    /// `StackShepherdPolicy`'s ready gate from the latest poll.
    let gatePasses: Bool

    init(sessionID: String, worktree: Worktree, state: AppState) {
        let shepherd = state.stackShepherd
        let currentStack = state.shepherdStackName(for: worktree)
        let own = shepherd.record(forSession: sessionID, worktreeID: worktree.id, currentStackName: currentStack)
        record = own
        // Only the stack the worktree is on can be taken over from here: the
        // button binds that stack, whatever else the worktree has records for.
        if own == nil, let currentStack,
           let other = shepherd.liveRecord(forWorktree: worktree.id, stackName: currentStack),
           other.sessionID != sessionID {
            otherRecord = other
        } else {
            otherRecord = nil
        }
        let bound = own ?? otherRecord
        requests = bound.flatMap { shepherd.requests[$0.id] } ?? [:]
        gatePasses = bound.flatMap { shepherd.gatePasses[$0.id] } ?? false
    }

    var presentation: ShepherdPresentation {
        .make(stack: record, requests: requests, gatePasses: gatePasses)
    }
}

/// The Ship popover for a gg stack worktree: every entry's request and the
/// shepherd's state once bound, else Ship stack or Shepherd stack.
struct StackShepherdPopover: View {
    let session: ACPSession
    @ObservedObject var transcript: ACPTranscript
    let worktree: Worktree
    let state: AppState
    let onClose: () -> Void
    @Environment(\.theme) private var theme
    @State private var stack: GGStack?
    @State private var isLoading = true
    @State private var rules: ShepherdRules = .none
    @State private var rulesUnreadable = false

    private var isBusy: Bool { transcript.streamingState != .idle }

    var body: some View {
        let context = StackShepherdSessionContext(sessionID: session.id, worktree: worktree, state: state)
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
    }

    /// Read-only: the UI never runs the shepherd policy.
    private func load() async {
        let settings = state.projectsManager.projects.first(where: { $0.id == worktree.projectId })?.shepherd
        do {
            rules = try await ShepherdRulesResolver.load(worktreePath: worktree.path, projectSettings: settings)
            rulesUnreadable = false
        } catch {
            rules = .none
            rulesUnreadable = true
        }
        stack = try? await state.stackShepherd.effects?.loadStack(worktree.path)
        isLoading = false
    }

    // MARK: Bound

    @ViewBuilder
    private func boundContent(record: StackShepherdRecord, context: StackShepherdSessionContext) -> some View {
        let presentation = context.presentation
        header(name: record.id.stackName, detail: "\(record.base) · \(record.remote.kind.displayName)")
        Divider().background(theme.color("line"))
        VStack(alignment: .leading, spacing: 6) {
            ForEach(record.entries.sorted { $0.position > $1.position }, id: \.requestNumber) { entry in
                entryRow(entry, record: record, context: context)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
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
                        set: { state.stackShepherd.setMaxFixAttempts($0, for: record.id) }
                    ),
                    in: ShepherdDefaults.fixAttemptRange
                )
                .labelsHidden()
                .controlSize(.mini)
                .disabled(record.isFinished)
                .help("Fix prompts each entry gets before the shepherd stops and asks for you")
                Text("· Rules: \(rulesUnreadable ? "unreadable" : rules.sourceLabel ?? "none")")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(theme.color("fg-muted"))
            ShepherdSwitchRow(
                title: "Auto-fix",
                detail: "CI failures, conflicts and reviewer threads in any entry go back to this session as one turn",
                isOn: record.autoFix,
                isDisabled: record.isFinished
            ) { isOn in
                state.stackShepherd.setAutoFix(isOn, for: record.id)
            }
            Text("The stack lands with Land in the stack drawer; the shepherd never merges it.")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.color("fg-muted"))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        Divider().background(theme.color("line"))
        footer(record: record)
    }

    private func header(name: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: GGStackIcon.systemName)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color("fg-muted"))
                Text(name)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(detail)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.color("fg-muted"))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func entryRow(_ entry: StackShepherdEntry, record: StackShepherdRecord, context: StackShepherdSessionContext) -> some View {
        let request = context.requests[entry.requestNumber]
        let kind = record.remote.kind
        let number = "\(kind.reviewRequestNumberPrefix)\(entry.requestNumber)"
        let url = request?.url ?? record.remote.reviewRequestURL(number: entry.requestNumber)
        let presentation = ShepherdPresentation.make(
            record: entry.shepherd,
            request: request,
            mergeGatePasses: context.gatePasses && !entry.shepherd.phase.isTerminal
        )
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: presentation.badge.symbolName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(presentation.badge.color(theme: theme))
            Text("\(entry.position)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.color("fg-muted"))
            Link(number, destination: url)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.color("accent"))
                .help("Open \(kind.reviewRequestLabel) \(number) in the browser")
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(presentation.phaseLine)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.color("fg-muted"))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func footer(record: StackShepherdRecord) -> some View {
        HStack(spacing: 8) {
            Button("Show stack") {
                onClose()
                state.rightPaneStore.activeState(worktreeId: worktree.id)?.activeTab = .changes
                state.config.rightPaneVisible = true
            }
            .help("Show the stack drawer in Changes")
            if record.phase.isResumable {
                Button("Resume") {
                    state.stackShepherd.resume(record.id)
                }
                .help("Watch again and reset every entry's fix attempt count")
            }
            Spacer(minLength: 0)
            Button("Stop shepherding") {
                state.stackShepherd.stopShepherding(record.id)
            }
            .help("Stop watching. The requests stay open.")
        }
        .controlSize(.small)
        .font(.system(size: 11))
        .padding(12)
    }

    // MARK: Unbound

    /// Entries listed before the rest fold into a "more" line.
    private static let maxListedEntries = 8

    @ViewBuilder
    private func unboundContent(context: StackShepherdSessionContext) -> some View {
        let name = context.otherRecord?.id.stackName ?? stack?.name ?? state.shepherdStackName(for: worktree) ?? worktree.branch
        let entries = stack?.entries ?? []
        let published = entries.filter { $0.prNumber != nil }.count
        ShipPopoverHeader(
            symbol: ACPShepherdButton.stackShipSymbol,
            title: "Ship stack \(name)",
            detail: stack.map { "\($0.base) · \(entries.count) entr\(entries.count == 1 ? "y" : "ies"), \(published) published" }
                ?? (isLoading ? "Reading the stack…" : "gg lists no stack here")
        )
        if !entries.isEmpty {
            Divider().background(theme.color("line"))
            VStack(alignment: .leading, spacing: 5) {
                ForEach(entries.prefix(Self.maxListedEntries)) { unboundEntryRow($0) }
                if entries.count > Self.maxListedEntries {
                    Text("\(entries.count - Self.maxListedEntries) more")
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.color("fg-dim"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        Divider().background(theme.color("line"))
        switch StackShipAction.resolve(
            record: nil, otherRecord: context.otherRecord, stack: stack, isBusy: isBusy, isLoading: isLoading
        ) {
        case .adopt where context.otherRecord != nil:
            adoptRow(text: "The gg stack \(name) is shepherded by another session.", buttonTitle: "Move to this session")
        case .adopt:
            adoptRow(text: "Every entry has an open request.", buttonTitle: "Shepherd stack from this session")
        case .create:
            createContent(reason: nil)
        case .unavailable(let reason):
            createContent(reason: reason)
        case .shepherding:
            EmptyView()
        }
    }

    private func unboundEntryRow(_ entry: GGStackEntry) -> some View {
        HStack(spacing: 8) {
            Text("\(entry.position)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.color("fg-faint"))
                .frame(minWidth: 10, alignment: .trailing)
            Text(entry.title)
                .font(.system(size: 11))
                .foregroundStyle(theme.color("fg"))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let number = entry.prNumber {
                Text(verbatim: "#\(number)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.color("add"))
            } else {
                ShipPopoverChip(text: "unpublished")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func adoptRow(text: String, buttonTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(theme.color("fg-muted"))
                .fixedSize(horizontal: false, vertical: true)
            AlasButton(title: buttonTitle, style: .primary, fillsWidth: true) {
                onClose()
                Task { await state.shepherdStackWithSession(session.id, worktree: worktree) }
            }
            .help("Watch every request in this stack from this session and send it the current problems")
            .accessibilityLabel(buttonTitle)
        }
        .padding(12)
    }

    @ViewBuilder
    private func createContent(reason: String?) -> some View {
        ShipPopoverStep(symbol: "sparkles") {
            Text("The agent folds its work into the stack and publishes every entry with gg sync; Alas shepherds them all.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        Divider().background(theme.color("line"))
        ShipPopoverFooter(
            title: "Ship stack with agent",
            symbol: ACPShepherdButton.stackShipSymbol,
            reason: reason,
            isWaiting: isBusy || isLoading,
            help: "Ask this session to publish every entry of the stack and shepherd them"
        ) {
            onClose()
            state.requestShipStack(sessionID: session.id, worktree: worktree)
        }
    }
}
