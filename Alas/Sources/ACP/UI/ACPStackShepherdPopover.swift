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
    /// Ship stack's line: ships through this position; `.max` ships it all.
    @State private var shipThrough = Int.max
    @State private var opensDrafts = false
    /// Ship more's line over the held-back entries.
    @State private var moreShipThrough = Int.max
    @State private var moreOpensDrafts = false
    @State private var isShippingMore = false

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
        shipMoreSection(record: record)
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

    /// The entries the shepherded stack holds back, with the same line as
    /// Ship stack. Ship more syncs them straight away: they are committed
    /// already, so no agent turn is needed.
    @ViewBuilder
    private func shipMoreSection(record: StackShepherdRecord) -> some View {
        if Self.canChooseEntries, let stack, stack.name == record.id.stackName,
           case let heldBack = (record.shipPlan ?? .wholeStack).heldBackEntries(of: stack), !heldBack.isEmpty {
            let through = StackShipPlan.snap(moreShipThrough, to: StackShipPlan.linePositions(in: heldBack))
            let shipped = heldBack.filter { $0.position <= through }.count
            Divider().background(theme.color("line"))
            VStack(alignment: .leading, spacing: 8) {
                Text("Held back · \(heldBack.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.color("fg-dim"))
                    .textCase(.uppercase)
                StackShipLinePicker(entries: heldBack, kind: record.remote.kind, shipThrough: $moreShipThrough, opensDrafts: moreOpensDrafts)
                draftsSwitch(isOn: $moreOpensDrafts)
                AlasButton(
                    title: isShippingMore ? "Shipping…" : "Ship \(shipped) more",
                    icon: ACPShepherdButton.stackShipSymbol,
                    fillsWidth: true
                ) {
                    shipMore(stack: stack, through: through)
                }
                .disabled(isBusy || isShippingMore)
                .opacity(isBusy || isShippingMore ? 0.45 : 1)
                .help(isBusy
                    ? "Wait for this session's turn to end: the agent may still be changing the stack"
                    : "Publish these entries with gg sync now and shepherd them with the rest")
                .accessibilityLabel("Ship \(shipped) more entries")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    /// `through` is the line's position among the held-back rows, which is
    /// also where it can stop in the whole stack.
    private func shipMore(stack: GGStack, through: Int) {
        let plan = StackShipPlan(shipThroughPosition: through, of: stack, opensDrafts: moreOpensDrafts)
        isShippingMore = true
        Task {
            await state.shipMoreStack(sessionID: session.id, worktree: worktree, plan: plan)
            self.stack = try? await state.stackShepherd.effects?.loadStack(worktree.path)
            moreShipThrough = .max
            isShippingMore = false
        }
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

    /// The installed gg can publish part of a stack and open drafts.
    private static var canChooseEntries: Bool { GGAvailability.shared.capabilities.syncUntilDraft }

    @ViewBuilder
    private func unboundContent(context: StackShepherdSessionContext) -> some View {
        let name = context.otherRecord?.id.stackName ?? stack?.name ?? state.shepherdStackName(for: worktree) ?? worktree.branch
        let entries = stack?.entries ?? []
        let published = entries.filter { $0.prNumber != nil }.count
        // The other session's record knows the host; else the Changes pane's
        // commit remote, which its stack chips use too.
        let kind = context.otherRecord?.remote.kind
            ?? state.rightPaneStore.activeState(worktreeId: worktree.id)?.commitRemote?.kind
        let action = StackShipAction.resolve(
            record: nil, otherRecord: context.otherRecord, stack: stack, isBusy: isBusy, isLoading: isLoading
        )
        let offersShip: Bool = switch action {
        case .create, .unavailable: true
        case .adopt, .shepherding: false
        }
        let picksEntries = offersShip && Self.canChooseEntries && !entries.isEmpty
        ShipPopoverHeader(
            symbol: ACPShepherdButton.stackShipSymbol,
            title: "Ship stack \(name)",
            detail: stack.map { "\($0.base) · \(entries.count) entr\(entries.count == 1 ? "y" : "ies"), \(published) published" }
                ?? (isLoading ? "Reading the stack…" : "gg lists no stack here")
        )
        if !entries.isEmpty {
            Divider().background(theme.color("line"))
            Group {
                if picksEntries {
                    StackShipLinePicker(entries: entries, kind: kind, shipThrough: $shipThrough, opensDrafts: opensDrafts)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(entries.sorted { $0.position > $1.position }.prefix(Self.maxListedEntries)) { unboundEntryRow($0, kind: kind) }
                        if entries.count > Self.maxListedEntries {
                            Text("\(entries.count - Self.maxListedEntries) more")
                                .font(.system(size: 10.5))
                                .foregroundStyle(theme.color("fg-dim"))
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        Divider().background(theme.color("line"))
        switch action {
        case .adopt where context.otherRecord != nil:
            adoptRow(text: "The gg stack \(name) is shepherded by another session.", buttonTitle: "Move to this session")
        case .adopt:
            adoptRow(text: "Every entry has an open request.", buttonTitle: "Shepherd stack from this session")
        case .create:
            createContent(reason: nil, picksEntries: picksEntries)
        case .unavailable(let reason):
            createContent(reason: reason, picksEntries: picksEntries)
        case .shepherding:
            EmptyView()
        }
    }

    private func unboundEntryRow(_ entry: GGStackEntry, kind: CodeHostKind?) -> some View {
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
                Text(verbatim: "\((kind ?? .github).reviewRequestNumberPrefix)\(number)")
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
    private func createContent(reason: String?, picksEntries: Bool) -> some View {
        let entries = stack?.entries ?? []
        let top = entries.map(\.position).max() ?? 0
        let through = StackShipPlan.snap(shipThrough, to: StackShipPlan.linePositions(in: entries))
        let shipped = entries.filter { $0.position <= through }.count
        let shipsAll = !picksEntries || through >= top
        let plan = picksEntries
            ? stack.map { StackShipPlan(shipThroughPosition: shipThrough, of: $0, opensDrafts: opensDrafts) } ?? .wholeStack
            : .wholeStack
        VStack(alignment: .leading, spacing: 10) {
            ShipPopoverStep(symbol: "sparkles") {
                Text(shipsAll
                    ? "The agent folds its work into the stack and publishes every entry with gg sync; Alas shepherds them all."
                    : "The agent folds its work into the stack and publishes the entries below the line with gg sync; Alas shepherds them. Entries above it, and commits the agent adds on top, stay local.")
            }
            if picksEntries {
                draftsSwitch(isOn: $opensDrafts)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        Divider().background(theme.color("line"))
        ShipPopoverFooter(
            title: shipsAll ? "Ship stack with agent" : "Ship \(shipped) of \(entries.count) entries with agent",
            symbol: ACPShepherdButton.stackShipSymbol,
            reason: reason,
            isWaiting: isBusy || isLoading,
            help: shipsAll
                ? "Ask this session to publish every entry of the stack and shepherd them"
                : "Ask this session to publish the entries below the line and shepherd them"
        ) {
            onClose()
            state.requestShipStack(sessionID: session.id, worktree: worktree, plan: plan)
        }
    }

    private func draftsSwitch(isOn: Binding<Bool>) -> some View {
        ShepherdSwitchRow(
            title: "Open new requests as drafts",
            detail: "Entries that already have a request keep it as it is",
            isOn: isOn.wrappedValue,
            isDisabled: false
        ) { isOn.wrappedValue = $0 }
    }
}

/// The Ship stack entry list with one line: entries below it ship, entries
/// above it stay local. Drag the line or click a row to ship through it; the
/// focused line also moves with the arrow keys, and VoiceOver adjusts it.
struct StackShipLinePicker: View {
    /// Contiguous positions, in any order; listed top of the stack first.
    let entries: [GGStackEntry]
    /// Prefixes request numbers; nil reads as GitHub's `#`.
    let kind: CodeHostKind?
    /// Ships through this position; at or above the top row ships every row.
    @Binding var shipThrough: Int
    let opensDrafts: Bool
    @Environment(\.theme) private var theme
    @State private var dragOrigin: Int?
    @State private var hovered: Int?

    /// A row's height plus the spacing: how far the line moves per entry.
    private static let rowPitch: CGFloat = 25
    private static let maxVisibleRows = 8
    private static let lineID = "ship-line"
    private static let space = "ship-line-picker"

    private enum Item: Identifiable {
        case entry(GGStackEntry)
        case line

        var id: String {
            switch self {
            case .entry(let entry): entry.id
            case .line: StackShipLinePicker.lineID
            }
        }
    }

    private var top: Int { entries.map(\.position).max() ?? 0 }
    /// Where the line can stop: never below an entry that already has a
    /// request, and only above entries with a GG-ID (`StackShipPlan.linePositions`).
    private var stops: [Int] { StackShipPlan.linePositions(in: entries) }
    private var through: Int { StackShipPlan.snap(shipThrough, to: stops) }

    /// Rows top-first with the line above the first row that ships. The line
    /// keeps one identity wherever it sits, so a drag survives it moving.
    private var items: [Item] {
        var items: [Item] = []
        for entry in entries.sorted(by: { $0.position > $1.position }) {
            if entry.position == through { items.append(.line) }
            items.append(.entry(entry))
        }
        return items
    }

    var body: some View {
        let list = VStack(alignment: .leading, spacing: 5) {
            ForEach(items) { item in
                switch item {
                case .entry(let entry): row(entry)
                case .line: line
                }
            }
        }
        .coordinateSpace(.named(Self.space))
        if entries.count > Self.maxVisibleRows {
            ScrollView { list }
                .frame(height: CGFloat(Self.maxVisibleRows) * Self.rowPitch)
        } else {
            list
        }
    }

    private func row(_ entry: GGStackEntry) -> some View {
        let ships = entry.position <= through
        let state = Self.stateLabel(entry, prefix: (kind ?? .github).reviewRequestNumberPrefix, ships: ships, opensDrafts: opensDrafts)
        return Button {
            shipThrough = entry.position
        } label: {
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
                if entry.prNumber != nil {
                    Text(verbatim: state)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.color("add"))
                } else {
                    ShipPopoverChip(text: state, tone: ships ? (opensDrafts ? "warn" : "accent") : nil)
                }
            }
            .opacity(ships ? 1 : 0.5)
            .frame(height: 20)
            .padding(.horizontal, 4)
            .background(
                hovered == entry.position ? theme.color("bg-3") : .clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
            .padding(.horizontal, -4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = entry.position } else if hovered == entry.position { hovered = nil }
        }
        .help("Ship through entry \(entry.position)")
        .accessibilityLabel("Entry \(entry.position), \(entry.title), \(state)")
        .accessibilityHint("Ships this entry and every entry below it")
    }

    private var line: some View {
        HStack(spacing: 6) {
            Rectangle().frame(height: 1.5)
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.and.down")
                    .font(.system(size: 8, weight: .semibold))
                Text("ship below")
                    .font(.system(size: 9.5, weight: .medium))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(theme.color("accent"), lineWidth: 1))
            Rectangle().frame(height: 1.5)
        }
        .foregroundStyle(theme.color("accent"))
        .frame(height: 14)
        .contentShape(Rectangle())
        .pointerStyle(.rowResize)
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
                .onChanged { value in
                    let origin = dragOrigin ?? through
                    dragOrigin = origin
                    let rows = Int((-value.translation.height / Self.rowPitch).rounded())
                    shipThrough = min(max(origin + rows, stops.first ?? 0), top)
                }
                .onEnded { _ in dragOrigin = nil }
        )
        .focusable()
        .onKeyPress(.upArrow) { move(1) }
        .onKeyPress(.downArrow) { move(-1) }
        .help("Drag to choose what ships: entries below the line ship, entries above it stay local")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ship line")
        .accessibilityValue(Self.lineValue(through: through, bottom: entries.map(\.position).min() ?? 0, top: top))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: _ = move(1)
            case .decrement: _ = move(-1)
            @unknown default: break
            }
        }
    }

    /// Moves the line `stops` stops up (positive) or down.
    private func move(_ stops: Int) -> KeyPress.Result {
        let all = self.stops
        let index = all.firstIndex(of: through) ?? all.count - 1
        shipThrough = all[min(max(index + stops, 0), all.count - 1)]
        return .handled
    }

    private static func stateLabel(_ entry: GGStackEntry, prefix: String, ships: Bool, opensDrafts: Bool) -> String {
        if let number = entry.prNumber { return "\(prefix)\(number)" }
        if !ships { return "held back" }
        return opensDrafts ? "draft" : "new"
    }

    private static func lineValue(through: Int, bottom: Int, top: Int) -> String {
        through >= top ? "Ships every entry" : "Ships entries \(bottom) to \(through), holds back \(through + 1) to \(top)"
    }
}
