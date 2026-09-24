import SwiftUI

enum RunTabLoadingPresentation {
    static func showsPlaceholder(scannedWorktreeID: String?, worktreeID: String) -> Bool {
        scannedWorktreeID != worktreeID
    }

    static func scanMarkerAfterStartingRefresh(scannedWorktreeID: String?, refreshingWorktreeID: String) -> String? {
        scannedWorktreeID == refreshingWorktreeID ? nil : scannedWorktreeID
    }

    static func acceptsRefreshCompletion(
        startedWorktreeID: String,
        activeWorktreeID: String?,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && activeWorktreeID == startedWorktreeID
    }

    static func acceptsHistoryLoadCompletion(
        requestedWorktreeID: String,
        requestedPageIndex: Int,
        requestedRevision: Int,
        activeWorktreeID: String?,
        currentPageIndex: Int,
        currentRevision: Int,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled
            && activeWorktreeID == requestedWorktreeID
            && currentPageIndex == requestedPageIndex
            && currentRevision == requestedRevision
    }
}

/// Commands, their observed state, and their endpoints for one worktree.
///
/// Scripts are rescanned on appear (the palette does the same — the directory
/// holds a handful of small files), while run state comes from
/// `AppState.runRecords`, which outlives this view. Hiding or switching the
/// panel therefore never touches a running command.
struct RunTabView: View {
    @Bindable var state: AppState
    let worktree: Worktree

    @Environment(\.theme) private var theme
    @State private var scripts: [RunScript] = []
    @State private var scriptCatalogError: String?
    @State private var activeWorktreeID: String?
    @State private var activeHistoryOwner: RunHistoryOwner?
    /// Keeps the "no scripts yet" copy from flashing before the first scan.
    @State private var scannedWorktreeID: String?
    /// Drives the relative timestamps ("3m ago") without re-scanning anything.
    @State private var now = Date()
    /// Held in `@State` so `onReceive` keeps one stable subscription instead
    /// of restarting the interval on every body pass.
    @State private var ticker = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    @State private var historyPage = RunHistoryPage(entries: [], totalCount: 0)
    @State private var historyPageIndex = 0
    @State private var observedRunHistoryRevision = 0
    @State private var historyError: String?
    @State private var isClearingHistory = false
    var body: some View {
        Group {
            let displayedScripts = activeOrAllScripts
            if RunTabLoadingPresentation.showsPlaceholder(
                scannedWorktreeID: scannedWorktreeID,
                worktreeID: worktree.id
            ) {
RightPaneLoadingSkeletonView(activeTab: .run)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let scriptCatalogError {
                            catalogErrorBanner(scriptCatalogError)
                        }
                        ForEach(RunScriptScope.allCases, id: \.self) { scope in
                            let scoped = displayedScripts.filter { $0.scope == scope }
                            if !scoped.isEmpty {
                                RunScopeHeader(title: scope.sectionTitle, count: scoped.count)
                                ForEach(scoped) { script in
                                    RunRowView(
                                        presentation: presentation(for: script),
                                        onAction: { perform($0, script: script) }
                                    )
                                }
                            }
                        }
                        historySection
                    }
                    .padding(.top, PaneBandLayout.outerVertical)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: "\(worktree.id):\(worktree.projectId)") {
            let startedWorktreeID = worktree.id
            let historyOwner = RunHistoryOwner(worktreeID: worktree.id, projectId: worktree.projectId)
            activeWorktreeID = startedWorktreeID
            activeHistoryOwner = historyOwner
            historyPageIndex = 0
            historyPage = .init(entries: [], totalCount: 0)
            historyError = nil
            observedRunHistoryRevision = state.runHistoryRevision(worktreeID: startedWorktreeID, projectId: worktree.projectId)
            scripts = []
            scriptCatalogError = nil
            scannedWorktreeID = RunTabLoadingPresentation.scanMarkerAfterStartingRefresh(
                scannedWorktreeID: scannedWorktreeID,
                refreshingWorktreeID: startedWorktreeID
            )
            await refreshScripts(startedWorktreeID: startedWorktreeID)
            guard RunTabLoadingPresentation.acceptsRefreshCompletion(
                startedWorktreeID: startedWorktreeID,
                activeWorktreeID: activeWorktreeID,
                isCancelled: Task.isCancelled
            ) else { return }
            scannedWorktreeID = startedWorktreeID
            await loadHistory()
            // Reconnecting to a worktree is the moment to settle runs whose
            // terminal disappeared while nothing was watching them.
            state.reconcileRunRecords(worktree: worktree)
            now = Date()
        }
        .onReceive(ticker) { now = $0 }
        .onChange(of: state.runScriptCatalogGeneration) {
            refreshScriptsFromControl()
        }
        .onChange(of: state.runHistoryRevision) {
            let revision = state.runHistoryRevision(worktreeID: worktree.id, projectId: worktree.projectId)
            guard revision != observedRunHistoryRevision else { return }
            observedRunHistoryRevision = revision
            historyPageIndex = 0
            Task { await loadHistory() }
        }
        .confirmationDialog(
            "Clear run history?",
            isPresented: $isClearingHistory,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                state.clearRunHistory(worktreeID: worktree.id, projectId: worktree.projectId)
            }
        } message: {
            Text("This clears completed runs for this worktree across all branches. Active runs keep running.")
        }
    }

    private var activeOrAllScripts: [RunScript] {
        let scriptsByKey = Dictionary(uniqueKeysWithValues: scripts.map { ($0.key, $0) })
        let activeScripts = state.runRecords.records(worktreeID: worktree.id, projectId: worktree.projectId)
            .filter(\.status.isActive)
            .compactMap { record in
                scriptsByKey[record.scriptKey] ?? script(from: record)
            }
            .sorted {
                if $0.scope != $1.scope { return $0.scope.rawValue < $1.scope.rawValue }
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        guard scriptCatalogError == nil else { return activeScripts }
        let catalogKeys = Set(scripts.map(\.key))
        return scripts + activeScripts.filter { !catalogKeys.contains($0.key) }
    }

    private func script(from record: RunRecord) -> RunScript? {
        let parts = record.scriptKey.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let scope = RunScriptScope(rawValue: String(parts[0]))
        else { return nil }
        let fileName = String(parts[1])
        let fileURL = switch scope {
        case .repo:
            RunScriptStore.repoScriptsDir(worktreeRoot: worktree.path).appendingPathComponent(fileName)
        case .global:
            Paths.runScriptsGlobalDir.appendingPathComponent(fileName)
        }
        return RunScript(
            scope: scope,
            fileName: fileName,
            fileURL: fileURL,
            displayName: record.scriptName,
            onExit: .keep,
            cwd: nil,
            isExecutable: false,
            endpoint: record.endpoint
        )
    }

    private func presentation(for script: RunScript) -> RunRowPresentation {
        let record = state.runRecords.record(worktreeID: worktree.id, projectId: worktree.projectId, scriptKey: script.key)
        return RunTabPresentation.row(
            RunRowInput(
                script: script,
                record: record,
                hasTerminal: state.runningScriptTab(for: script, in: worktree) != nil,
                hasReport: record.map { state.hasRunReport(worktreeID: worktree.id, projectId: worktree.projectId, runID: $0.id) } ?? false,
                target: record?.target ?? state.runExecutionTarget(for: script, in: worktree)
            ),
            now: now
        )
    }

    private func perform(_ action: RunRowAction, script: RunScript) {
        Task {
            await perform(action, matching: script)
        }
    }

    private func perform(_ action: RunRowAction, matching staleScript: RunScript) async {
        switch action {
        case .start:
            let preRefreshRunID = state.runRecords.record(worktreeID: worktree.id, projectId: worktree.projectId, scriptKey: staleScript.key)?.id
            guard let script = await freshScript(matching: staleScript) else { return }
            guard state.runRecords.record(worktreeID: worktree.id, projectId: worktree.projectId, scriptKey: staleScript.key)?.id == preRefreshRunID else {
                return
            }
            if case .finished? = state.runRecords.record(worktreeID: worktree.id, projectId: worktree.projectId, scriptKey: script.key)?.status {
                state.restartScript(script, in: worktree)
            } else if state.scriptTab(for: script, in: worktree) != nil {
                state.restartScript(script, in: worktree)
            } else {
                state.runOrFocusScript(script, in: worktree)
            }
        case .stop:
            state.stopScript(staleScript, in: worktree)
        case .restart:
            let stoppedRunID = state.runRecords.record(worktreeID: worktree.id, projectId: worktree.projectId, scriptKey: staleScript.key)?.id
            state.stopScript(staleScript, in: worktree)
            guard let script = await freshScript(matching: staleScript) else { return }
            if let stoppedRunID,
               state.runRecords.record(worktreeID: worktree.id, projectId: worktree.projectId, scriptKey: staleScript.key)?.id != stoppedRunID {
                return
            }
            state.restartScript(script, in: worktree)
        case .openTerminal:
            state.focusScriptTerminal(staleScript, in: worktree)
        case .openEndpoint:
            guard let script = await freshScript(matching: staleScript) else { return }
            state.openRunEndpoint(script, in: worktree)
        case .showReport(let runID):
            state.openRunReport(worktreeID: worktree.id, projectId: worktree.projectId, runID: runID)
        case .edit:
            state.editScript(staleScript, in: worktree)
        }
    }

    @discardableResult
    private func refreshScripts(startedWorktreeID: String? = nil) async -> [RunScript]? {
        let refreshWorktreeID = startedWorktreeID ?? worktree.id
        let worktreePath = worktree.path
        let host = RemoteHostRegistry.shared.host(forPath: worktreePath.path)
        let result = await RunScriptStore.discoverScripts(worktreeRoot: worktreePath, remoteHost: host)
        guard RunTabLoadingPresentation.acceptsRefreshCompletion(
            startedWorktreeID: refreshWorktreeID,
            activeWorktreeID: activeWorktreeID,
            isCancelled: Task.isCancelled
        ) else { return nil }
        switch result {
        case .scripts(let fresh):
            scriptCatalogError = nil
            scripts = fresh
            return fresh
        case .failed(let message):
            scriptCatalogError = message
            return nil
        }
    }

    private func refreshScriptsFromControl() {
        let startedWorktreeID = worktree.id
        Task {
            await refreshScripts(startedWorktreeID: startedWorktreeID)
            guard RunTabLoadingPresentation.acceptsRefreshCompletion(
                startedWorktreeID: startedWorktreeID,
                activeWorktreeID: activeWorktreeID,
                isCancelled: Task.isCancelled
            ) else { return }
            scannedWorktreeID = startedWorktreeID
        }
    }

    private func freshScript(matching script: RunScript) async -> RunScript? {
        guard let fresh = await refreshScripts() else { return nil }
        return fresh.first { $0.key == script.key }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Icon(name: "play", size: 22, color: theme.color("fg-faint"))
            Text("No run scripts yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.color("fg-muted"))
            Text("Add a script to \(RunScriptStore.repoScriptsRelativeDir) to build, test, or serve this worktree.")
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-faint"))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
        .accessibilityIdentifier("run-tab-empty-state")
    }

    private func catalogErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Icon(name: "exclamationmark.triangle", size: 13, color: theme.color("warn"))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("Couldn’t refresh run scripts")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.color("fg-muted"))
                Text(message)
                    .font(.system(size: 10))
                    .foregroundColor(theme.color("fg-faint"))
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Retry") { refreshScriptsFromControl() }
            .controlSize(.small)
        }
        .padding(10)
        .background(theme.color("warn").opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.color("warn").opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Icon(name: "exclamationmark.triangle", size: 22, color: theme.color("warn"))
            Text("Couldn’t Load Run Scripts")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.color("fg-muted"))
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-faint"))
                .multilineTextAlignment(.center)
            Button("Retry") { refreshScriptsFromControl() }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
        .accessibilityIdentifier("run-tab-error-state")
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("HISTORY")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.5)
                    .foregroundColor(theme.color("fg-muted"))
                Spacer()
                if historyPage.totalCount > 0 {
                    Button("Clear") { isClearingHistory = true }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)

            if let historyError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(historyError)
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("warn"))
                    Button("Retry") { Task { await loadHistory() } }
                        .controlSize(.small)
                }
                .padding(.horizontal, 12)
            } else if historyPage.entries.isEmpty {
                Text("No completed runs yet")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-faint"))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ForEach(historyPage.entries) { entry in
                    Button {
                        state.openRunReport(worktreeID: worktree.id, projectId: worktree.projectId, runID: entry.id)
                    } label: {
                        HStack(spacing: 8) {
                            RunStatusDot(tone: historyTone(entry.outcome), isActive: false)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.scriptName)
                                    .font(.system(size: 12, weight: .medium))
                                Text(RunTabPresentation.historyDetail(entry, now: now))
                                    .font(.system(size: 10))
                                    .foregroundColor(theme.color("fg-faint"))
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open report for \(entry.scriptName): \(RunTabPresentation.historyDetail(entry, now: now))")
                }
                HStack {
                    Button("Previous") {
                        historyPageIndex -= 1
                        Task { await loadHistory() }
                    }
                    .disabled(historyPageIndex == 0)
                    Spacer()
                    Text(historyRange)
                        .font(.system(size: 10))
                        .foregroundColor(theme.color("fg-faint"))
                    Spacer()
                    Button("Next") {
                        historyPageIndex += 1
                        Task { await loadHistory() }
                    }
                    .disabled((historyPageIndex + 1) * 20 >= historyPage.totalCount)
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.top, 12)
    }

    private var historyRange: String {
        guard historyPage.totalCount > 0 else { return "0 of 0" }
        let first = historyPageIndex * 20 + 1
        let last = min(first + historyPage.entries.count - 1, historyPage.totalCount)
        return "\(first)–\(last) of \(historyPage.totalCount)"
    }

    private func historyTone(_ outcome: RunOutcome) -> RunStatusTone {
        switch outcome {
        case .succeeded: .success
        case .failed: .failure
        case .stopped, .unknown: .warning
        }
    }

    private func loadHistory() async {
        let requestedWorktreeID = worktree.id
        let requestedOwner = RunHistoryOwner(worktreeID: worktree.id, projectId: worktree.projectId)
        let requestedPageIndex = historyPageIndex
        let requestedRevision = state.runHistoryRevision(worktreeID: requestedWorktreeID, projectId: worktree.projectId)
        guard let history = state.runHistoryStore else {
            historyError = "Run history storage is unavailable."
            historyPage = .init(entries: [], totalCount: 0)
            return
        }
        do {
            let page = try await history.page(
                worktreeID: requestedWorktreeID,
                projectID: requestedOwner.projectId,
                offset: requestedPageIndex * 20,
                limit: 20
            )
            await state.reloadDurableRunReportIDs(worktreeID: requestedWorktreeID, projectId: requestedOwner.projectId)
            guard activeHistoryOwner == requestedOwner,
                  RunTabLoadingPresentation.acceptsHistoryLoadCompletion(
                requestedWorktreeID: requestedWorktreeID,
                requestedPageIndex: requestedPageIndex,
                requestedRevision: requestedRevision,
                activeWorktreeID: activeWorktreeID,
                currentPageIndex: historyPageIndex,
                currentRevision: state.runHistoryRevision(worktreeID: requestedWorktreeID, projectId: requestedOwner.projectId),
                isCancelled: Task.isCancelled
            ) else { return }
            historyError = nil
            historyPage = page
        } catch {
            guard activeHistoryOwner == requestedOwner,
                  RunTabLoadingPresentation.acceptsHistoryLoadCompletion(
                requestedWorktreeID: requestedWorktreeID,
                requestedPageIndex: requestedPageIndex,
                requestedRevision: requestedRevision,
                activeWorktreeID: activeWorktreeID,
                currentPageIndex: historyPageIndex,
                currentRevision: state.runHistoryRevision(worktreeID: requestedWorktreeID, projectId: requestedOwner.projectId),
                isCancelled: Task.isCancelled
            ) else { return }
            historyError = error.localizedDescription
        }
    }
}

private struct RunScopeHeader: View {
    let title: String
    let count: Int
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.5)
                .foregroundColor(theme.color("fg-muted"))
            Text("\(count)")
                .font(.system(size: 9.5, weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(theme.color("seg-pill-bg"))
                .clipShape(Capsule())
                .foregroundColor(theme.color("fg-muted"))
            Spacer(minLength: 8)
        }
        .paneBand(fill: theme.color("section-head-bg"))
    }
}

private struct RunRowView: View {
    let presentation: RunRowPresentation
    let onAction: (RunRowAction) -> Void

    @Environment(\.theme) private var theme
    @State private var hovering = false
    @State private var menuHovered = false

    var body: some View {
        let status = Text(presentation.statusLabel).foregroundColor(toneColor)
        let detail = Text(presentation.detail.map { " · \($0)" } ?? "")
            .foregroundColor(theme.color("fg-faint"))
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                RunStatusDot(tone: presentation.tone, isActive: presentation.isActive)
                Text(presentation.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let action = primaryAction {
                    actionButton(action, prominent: true)
                        .fixedSize()
                }
                actionMenu
            }

            Text("\(status)\(detail)")
                .font(.system(size: 10.5))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 13)

            if let location = presentation.locationLabel {
                HStack(spacing: 4) {
                    Icon(name: "terminal", size: 9, color: theme.color("fg-faint"))
                    Text(location)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.color("fg-faint"))
                        .lineLimit(1)
                }
                .padding(.leading, 13)
            }

            if let conflict = presentation.conflictLabel {
                HStack(spacing: 4) {
                    Icon(name: "exclamationmark.triangle", size: 9, color: theme.color("warn"))
                    Text(conflict)
                        .font(.system(size: 10))
                        .foregroundColor(theme.color("warn"))
                        .lineLimit(2)
                }
                .padding(.leading, 13)
            }

            if hasSecondaryActions {
                HStack(spacing: 6) {
                    ForEach(presentation.actions, id: \.self) { action in
                        switch action {
                        case .openTerminal, .showReport:
                            actionButton(action)
                        default:
                            EmptyView()
                        }
                    }
                    Spacer(minLength: 0)
                    ForEach(presentation.actions, id: \.self) { action in
                        if case .openEndpoint = action {
                            actionButton(action)
                        }
                    }
                }
                .padding(.leading, 7)
                .padding(.top, 2)
            }
        }
        .padding(10)
        .rightPaneCardChrome(accent: toneColor, isHovering: hovering)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .onHover { hovering = $0 }
        .help(presentation.locationDetail)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("run-row-\(presentation.id)")
    }

    private var primaryAction: RunRowAction? {
        presentation.actions.first {
            switch $0 {
            case .start, .stop: true
            default: false
            }
        }
    }

    private var hasSecondaryActions: Bool {
        presentation.actions.contains {
            switch $0 {
            case .openTerminal, .openEndpoint, .showReport: true
            default: false
            }
        }
    }

    private var actionMenu: some View {
        Menu {
            if presentation.actions.contains(.restart) {
                Button("Restart") { onAction(.restart) }
            }
            if presentation.actions.contains(.edit) {
                Button("Edit") { onAction(.edit) }
            }
        } label: {
            Icon(name: "ellipsis", size: 12, color: theme.color("fg-muted"))
                .toolbarControlSurface(isLit: menuHovered)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { menuHovered = $0 }
        .help("More actions for \(presentation.name)")
        .accessibilityLabel("More actions for \(presentation.name)")
    }

    private func actionButton(_ action: RunRowAction, prominent: Bool = false) -> some View {
        Button { onAction(action) } label: {
            HStack(spacing: 4) {
                if case .openEndpoint = action {
                    Text(label(for: action))
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Icon(name: "arrow.up.right", size: 10)
                } else {
                    Icon(
                        name: icon(for: action),
                        size: 10,
                        color: theme.color(prominent && action != .stop ? "accent" : "fg-muted")
                    )
                    Text(label(for: action))
                        .font(.system(size: 10.5, weight: prominent ? .medium : .regular))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(theme.color(prominent && action != .stop ? "accent" : "fg-muted"))
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(
                prominent ? theme.color(action == .stop ? "bg-3" : "accent-soft") : .clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.toolbarControl)
        .help(actionHelp(action))
        .accessibilityLabel("\(actionHelp(action)) for \(presentation.name)")
    }

    private func actionHelp(_ action: RunRowAction) -> String {
        if case .openEndpoint(let url) = action {
            return "Open \(url.absoluteString)"
        }
        return label(for: action)
    }

    private func icon(for action: RunRowAction) -> String {
        switch action {
        case .start: "play"
        case .stop: "stop"
        case .restart: "arrow.clockwise"
        case .openTerminal: "terminal"
        case .openEndpoint: "arrow.up.right"
        case .showReport: "doc.text"
        case .edit: "pencil"
        }
    }

    private var toneColor: Color {
        switch presentation.tone {
        case .idle:    theme.color("fg-faint")
        case .active:  theme.color("accent")
        case .success: theme.color("add")
        case .failure: theme.color("del")
        case .warning: theme.color("warn")
        }
    }

    private func label(for action: RunRowAction) -> String {
        switch action {
        case .start(let label): label
        case .stop:             "Stop"
        case .restart:          "Restart"
        case .openTerminal:     "Terminal"
        case .openEndpoint(let url):
            url.formatted(.url.scheme(.never).user(.never).password(.never).port(.always).path(.never).query(.never).fragment(.never))
        case .showReport:       "Report"
        case .edit:             "Edit"
        }
    }
}

private struct RunStatusDot: View {
    let tone: RunStatusTone
    let isActive: Bool

    @Environment(\.theme) private var theme
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(isActive && pulsing ? 0.35 : 1)
            .animation(
                isActive ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                value: pulsing
            )
            .onAppear { pulsing = isActive }
            .onChange(of: isActive) { _, active in pulsing = active }
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch tone {
        case .idle:    theme.color("fg-faint")
        case .active:  theme.color("accent")
        case .success: theme.color("add")
        case .failure: theme.color("del")
        case .warning: theme.color("warn")
        }
    }
}
