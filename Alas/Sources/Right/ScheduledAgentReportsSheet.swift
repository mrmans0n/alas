import SwiftUI

struct ScheduledAgentReportPageRefresh {
    let reports: [ScheduledAgentReport]
    let pageOffset: Int
    let hasMore: Bool

    /// Whether the loaded window no longer matches the store. Compares the
    /// loaded rows positionally against a refreshed read of the same
    /// window plus one probe row: the first page alone cannot prove the
    /// tail is intact (a deletion below it shifts every later row up), and
    /// the probe row decides `hasMore` without a second request. The probe
    /// row is excluded from both the comparison and the replacement — it
    /// exists solely to compute `hasMore`. The refreshed payload is applied
    /// to every loaded row, not just the first page, so pending rows below
    /// the first page settle visibly.
    static func loadedWindowRefresh(
        firstPage: [ScheduledAgentReport],
        from reports: [ScheduledAgentReport],
        pageSize: Int,
        prefix: [ScheduledAgentReport],
        requestedLimit: Int
    ) -> Self {
        let windowCount = requestedLimit - 1
        let window = prefix.prefix(windowCount)
        // Nothing was loaded yet (first read failed or the project had no
        // reports): seed the list from the refreshed first page instead of
        // discarding it, otherwise reports that appeared would never be
        // shown and the empty state would persist. The first-page rows are
        // data, not probes; its page-size boundary determines `hasMore`.
        if windowCount == 0 {
            let seededPage = Array(firstPage.prefix(pageSize))
            return Self(
                reports: seededPage,
                pageOffset: seededPage.count,
                hasMore: firstPage.count > pageSize
            )
        }
        let prefixMatches = window.map(\.id) == reports.map(\.id)
        if prefixMatches {
            var refreshedReports = reports
            for report in window {
                guard let index = refreshedReports.firstIndex(where: { $0.id == report.id }) else { continue }
                refreshedReports[index] = report
            }
            return Self(
                reports: refreshedReports,
                pageOffset: windowCount,
                // A probe row came back: at least one more report exists
                // beyond the loaded window.
                hasMore: prefix.count == requestedLimit
            )
        }
        return Self(
            reports: Array(window),
            pageOffset: window.count,
            hasMore: prefix.count == requestedLimit
        )
    }
}

struct ScheduledAgentReportsSheet: View {
    @Bindable var state: AppState
    let projectID: String
    let initialReportID: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var reports: [ScheduledAgentReport] = []
    @State private var selectedReportID: String?
    @State private var selectedReport: ScheduledAgentReport?
    @State private var pageOffset = 0
    @State private var hasMore = true
    @State private var isLoadingPage = false
    @State private var loadedPageProjectID: String?
    @State private var isLoadingReport = false
    @State private var isDeletingReport = false
    @State private var isConfirmingDelete = false
    @State private var pageError: String?
    @State private var detailError: String?
    @State private var canOpenSession = false

    private let pageSize = 40

    private var selectedReportNeedsRefresh: Bool {
        guard let selectedReportID,
              let selectedReport,
              selectedReport.id == selectedReportID
        else {
            return false
        }
        return selectedReport.hasPendingWork
    }

    /// A failed `loadSelectedReport`/`refreshSelectedReport` read is not
    /// proof the report is gone (e.g. the shared SQLite store stayed busy
    /// past its timeout), so the polling loop must keep running until a
    /// settled or confirmed-missing result arrives.
    @State private var selectedReportReadFailed = false

    init(state: AppState, projectID: String, initialReportID: String? = nil) {
        _state = Bindable(wrappedValue: state)
        self.projectID = projectID
        self.initialReportID = initialReportID
        _selectedReportID = State(initialValue: initialReportID)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(theme.color("line-soft"))
                .frame(height: 0.5)
                .accessibilityHidden(true)
            if let selectedReportID {
                reportDetail(for: selectedReportID)
            } else {
                reportList
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .task(id: "\(projectID)|\(selectedReportID ?? "")") {
            if loadedPageProjectID != projectID {
                await loadFirstPage()
            }
            await loadSelectedReport()
            while !Task.isCancelled {
                // A failed read is not proof the report is settled or gone:
                // keep polling so a transient store error (e.g. the SQLite
                // write lock held by another process) retries instead of
                // leaving the detail in a permanent error state.
                let keepPolling = selectedReportID != nil
                    && (selectedReportNeedsRefresh || selectedReportReadFailed)
                if selectedReportID != nil, !keepPolling { break }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                if selectedReportID == nil {
                    await refreshReportList()
                } else {
                    await refreshSelectedReport()
                }
            }
        }
        .confirmationDialog(
            "Delete this scheduled report?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Report", role: .destructive) {
                Task { await deleteSelectedReport() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the saved report. It does not change the schedule, worktree, or session.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("SCHEDULED REPORTS")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.5)
                .foregroundColor(theme.color("fg-muted"))
            Text("\(reports.count)\(hasMore ? "+" : "")")
                .font(.system(size: 9.5, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(theme.color("seg-pill-bg"))
                .clipShape(Capsule())
                .foregroundColor(theme.color("fg-muted"))
            Spacer(minLength: 8)
            if selectedReportID != nil {
                Button("All reports") {
                    selectedReportID = nil
                    selectedReport = nil
                    detailError = nil
                }
                .buttonStyle(.plain)
            }
            Button("Done", action: dismiss.callAsFunction)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var reportList: some View {
        if reports.isEmpty && isLoadingPage {
            ProgressView("Loading scheduled reports…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if reports.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 24))
                    .foregroundColor(theme.color("fg-faint"))
                Text(pageError == nil ? "No scheduled reports" : "Reports could not be loaded")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.color("fg-muted"))
                if let pageError {
                    Text(pageError)
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("warn"))
                        .textSelection(.enabled)
                } else {
                    Text("Reports remain here after their schedule or worktree is removed.")
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("fg-faint"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("scheduled-reports-empty")
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(reports) { report in
                        reportRow(report)
                    }
                    if let pageError {
                        Text(pageError)
                            .font(.system(size: 11))
                            .foregroundColor(theme.color("warn"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .textSelection(.enabled)
                    }
                    if hasMore || isLoadingPage {
                        Button {
                            Task { await loadMore() }
                        } label: {
                            if isLoadingPage {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("Load more")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                        .disabled(isLoadingPage)
                        .accessibilityIdentifier("scheduled-reports-load-more")
                    }
                }
                .padding(10)
            }
        }
    }

    private func reportRow(_ report: ScheduledAgentReport) -> some View {
        Button {
            selectedReportID = report.id
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Circle()
                    .fill(theme.color(taskColor(report.taskState)))
                    .frame(width: 7, height: 7)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(RunSchedulePresentation.scheduledAgentReportHistoryLabel(report))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(theme.color("fg"))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 5) {
                        Text(report.projectName)
                        if let branch = report.branch {
                            Text("·")
                            Text(branch)
                                .font(.system(size: 9.5, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundColor(theme.color("fg-faint"))
                    Text(report.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 9.5))
                        .foregroundColor(theme.color("fg-faint"))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.color("fg-faint"))
                    .padding(.top, 2)
                    .accessibilityHidden(true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selectedReportID == report.id ? theme.color("seg-pill-bg") : .clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(RunSchedulePresentation.scheduledAgentReportHistoryLabel(report))
        .accessibilityIdentifier("scheduled-report-row-\(report.id)")
    }

    @ViewBuilder
    private func reportDetail(for id: String) -> some View {
        if isLoadingReport {
            ProgressView("Loading report…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let report = selectedReport, report.id == id {
            detail(report)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 22))
                    .foregroundColor(theme.color("fg-faint"))
                Text(detailError == nil ? "Report unavailable" : "Report could not be loaded")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.color("fg-muted"))
                Text(detailError ?? "This report was deleted or is no longer available in this project.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-faint"))
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("scheduled-report-unavailable")
        }
    }

    private func detail(_ report: ScheduledAgentReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(report.scheduleName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(theme.color("fg"))
                            .textSelection(.enabled)
                        Text([report.projectName, report.branch].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 10.5))
                            .foregroundColor(theme.color("fg-faint"))
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    Button("Delete Report", role: .destructive) {
                        isConfirmingDelete = true
                    }
                    .controlSize(.small)
                    .disabled(report.taskState == .running || report.cleanupState == .pending || isDeletingReport)
                    .accessibilityIdentifier("scheduled-report-delete")
                }

                statusSection(report)
                section("Request") {
                    selectableText(report.request)
                }
                section("Agent") {
                    Text(report.agentID + (report.modelID.map { " · \($0)" } ?? ""))
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("fg-muted"))
                        .textSelection(.enabled)
                }
                section("Timing") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Started · \(report.startedAt.formatted(date: .abbreviated, time: .shortened))")
                        if let finishedAt = report.finishedAt {
                            Text("Finished · \(finishedAt.formatted(date: .abbreviated, time: .shortened))")
                        }
                        if let elapsed = report.duration,
                           let duration = RunSchedulePresentation.durationLabel(elapsed) {
                            Text("Duration · \(duration)")
                        }
                    }
                    .font(.system(size: 10.5))
                    .foregroundColor(theme.color("fg-muted"))
                }
                if let completion = report.completion {
                    section("Agent report") {
                        ACPMarkdownText(raw: completion.summary, showsCodeBlockCopyButton: false)
                            .font(.system(size: 11))
                            .textSelection(.enabled)
                        if !completion.checks.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Checks reported")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(theme.color("fg-muted"))
                                ForEach(Array(completion.checks.enumerated()), id: \.offset) { _, check in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(check.name)
                                            .font(.system(size: 10.5, weight: .medium))
                                            .foregroundColor(theme.color("fg"))
                                        Text(check.result)
                                            .font(.system(size: 10))
                                            .foregroundColor(theme.color("fg-muted"))
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                        if !completion.links.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Output links")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(theme.color("fg-muted"))
                                ForEach(Array(completion.links.enumerated()), id: \.offset) { _, link in
                                    if let url = webURL(link.url) {
                                        Link(destination: url) {
                                            Label(link.label, systemImage: "arrow.up.right")
                                                .font(.system(size: 10.5))
                                        }
                                    } else {
                                        Text("\(link.label) · \(link.url)")
                                            .font(.system(size: 10.5))
                                            .foregroundColor(theme.color("fg-faint"))
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    section("Agent report") {
                        Text("No completion report was recorded.")
                            .font(.system(size: 10.5))
                            .foregroundColor(theme.color("fg-faint"))
                    }
                }
                if let reason = report.cleanupReason {
                    section("Cleanup details") {
                        selectableText(reason)
                    }
                }
                if let scriptRun = report.scriptRun {
                    section("Script run") {
                        HStack {
                            Text(RunSchedulePresentation.firingRunLabel(scriptRun))
                                .font(.system(size: 10.5))
                                .foregroundColor(theme.color("fg-muted"))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            if state.canOpenScheduleFiringRun(scriptRun) {
                                Button("Open run report") {
                                    state.openScheduleFiringRun(scriptRun)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
                resourceActions(report)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: "\(report.id)|\(report.sessionID ?? "")|\(report.worktreeID ?? "")") {
            canOpenSession = false
            let isAvailable = await state.scheduledAgentReportSessionIsAvailable(report)
            guard !Task.isCancelled else { return }
            canOpenSession = isAvailable
        }
        .accessibilityIdentifier("scheduled-report-detail-\(report.id)")
    }

    private func statusSection(_ report: ScheduledAgentReport) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            statusRow("Task", value: RunSchedulePresentation.scheduledAgentTaskLabel(report.taskState), color: taskColor(report.taskState))
            if let cleanup = RunSchedulePresentation.scheduledAgentCleanupLabel(report) {
                let color: String = switch report.cleanupState {
                case .notRequested: "fg-faint"
                case .pending: "accent"
                case .removed: "add"
                case .retained: "warn"
                case .failed: "del"
                }
                statusRow("Cleanup", value: cleanup, color: color)
            }
        }
        .padding(10)
        .background(theme.color("field-bg"), in: RoundedRectangle(cornerRadius: 8))
    }

    private func statusRow(_ title: String, value: String, color: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundColor(theme.color("fg-muted"))
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(theme.color(color))
        }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.4)
                .foregroundColor(theme.color("fg-faint"))
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func selectableText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundColor(theme.color("fg-muted"))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    @ViewBuilder
    private func resourceActions(_ report: ScheduledAgentReport) -> some View {
        let worktree = state.worktreeForScheduledAgentReport(report)
        if worktree != nil || canOpenSession {
            HStack(spacing: 8) {
                if worktree != nil {
                    Button("Open Worktree") {
                        state.openScheduledAgentReportWorktree(report)
                    }
                    .controlSize(.small)
                }
                if canOpenSession {
                    Button("Open Session") {
                        Task { await state.openScheduledAgentReportSession(report) }
                    }
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func loadFirstPage() async {
        isLoadingPage = true
        pageError = nil
        defer {
            if !Task.isCancelled {
                isLoadingPage = false
                loadedPageProjectID = projectID
            }
        }
        do {
            let firstPage = try await state.scheduledAgentReportPage(
                projectID: projectID,
                offset: 0,
                limit: pageSize + 1
            )
            guard !Task.isCancelled else { return }
            reports = Array(firstPage.prefix(pageSize))
            pageOffset = reports.count
            hasMore = firstPage.count > pageSize
        } catch {
            guard !Task.isCancelled else { return }
            pageError = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard hasMore, !isLoadingPage else { return }
        isLoadingPage = true
        pageError = nil
        defer { if !Task.isCancelled { isLoadingPage = false } }
        do {
            let page = try await state.scheduledAgentReportPage(
                projectID: projectID,
                offset: pageOffset,
                limit: pageSize + 1
            )
            guard !Task.isCancelled else { return }
            let loadedPage = page.prefix(pageSize)
            let seen = Set(reports.map(\.id))
            reports.append(contentsOf: loadedPage.filter { !seen.contains($0.id) })
            pageOffset += loadedPage.count
            hasMore = page.count > pageSize
        } catch {
            guard !Task.isCancelled else { return }
            pageError = error.localizedDescription
        }
    }

    private func refreshReportList() async {
        guard !isLoadingPage, selectedReportID == nil else { return }
        do {
            let firstPage = try await state.scheduledAgentReportPage(
                projectID: projectID,
                offset: 0,
                limit: pageSize + 1
            )
            guard !Task.isCancelled, selectedReportID == nil else { return }

            // Read the whole loaded window plus one row: the extra row
            // decides `hasMore` without a second request, and a positional
            // comparison against the loaded rows catches deletions below
            // the first page that a first-page-only check would miss.
            let requestedLimit = pageOffset + 1
            let refreshedPrefix = try await state.scheduledAgentReportPrefix(
                projectID: projectID,
                limit: requestedLimit
            )
            guard !Task.isCancelled, selectedReportID == nil else { return }

            let refreshedPage = ScheduledAgentReportPageRefresh.loadedWindowRefresh(
                firstPage: firstPage,
                from: reports,
                pageSize: pageSize,
                prefix: refreshedPrefix,
                requestedLimit: requestedLimit
            )
            reports = refreshedPage.reports
            pageOffset = refreshedPage.pageOffset
            hasMore = refreshedPage.hasMore
            pageError = nil
            // Every refreshed prefix row's payload is already up to date
            // here (both branches apply it), so only rows that were NOT
            // re-fetched — those past the window, e.g. the probe's tail —
            // still need their pending state polled.
            let refreshedIDs = Set(refreshedPrefix.map(\.id))
            await refreshPendingReports(excluding: refreshedIDs)
        } catch {
            guard !Task.isCancelled, selectedReportID == nil else { return }
            pageError = error.localizedDescription
        }
    }

    private func refreshPendingReports(excluding excludedIDs: Set<String>) async {
        let pendingReportIDs = reports
            .filter { $0.hasPendingWork && !excludedIDs.contains($0.id) }
            .map(\.id)
        for reportID in pendingReportIDs {
            guard !Task.isCancelled, selectedReportID == nil else { return }
            do {
                let report = try await state.scheduledAgentReport(id: reportID, projectID: projectID)
                guard !Task.isCancelled, selectedReportID == nil else { return }
                if let report {
                    updateReportInList(report)
                } else {
                    reports.removeAll { $0.id == reportID }
                    pageOffset = reports.count
                }
            } catch {
                guard !Task.isCancelled, selectedReportID == nil else { return }
                pageError = error.localizedDescription
                return
            }
        }
    }

    private func loadSelectedReport() async {
        guard let selectedReportID else {
            selectedReport = nil
            selectedReportReadFailed = false
            detailError = nil
            return
        }
        isLoadingReport = true
        selectedReport = nil
        selectedReportReadFailed = false
        detailError = nil
        defer { if !Task.isCancelled { isLoadingReport = false } }
        do {
            let report = try await state.scheduledAgentReport(id: selectedReportID, projectID: projectID)
            guard !Task.isCancelled else { return }
            if let report {
                updateReportInList(report)
            }
            selectedReport = report
            if report == nil {
                detailError = "This report was deleted or is no longer available in this project."
            }
        } catch {
            guard !Task.isCancelled else { return }
            selectedReportReadFailed = true
            detailError = error.localizedDescription
        }
    }

    private func refreshSelectedReport() async {
        guard let selectedReportID else { return }
        do {
            let report = try await state.scheduledAgentReport(id: selectedReportID, projectID: projectID)
            guard !Task.isCancelled else { return }
            if let report {
                updateReportInList(report)
            }
            selectedReport = report
            selectedReportReadFailed = false
            detailError = report == nil
                ? "This report was deleted or is no longer available in this project."
                : nil
        } catch {
            guard !Task.isCancelled, selectedReport == nil else { return }
            selectedReportReadFailed = true
            detailError = error.localizedDescription
        }
    }

    private func updateReportInList(_ report: ScheduledAgentReport) {
        guard let index = reports.firstIndex(where: { $0.id == report.id }),
              reports[index] != report
        else { return }
        reports[index] = report
    }

    private func deleteSelectedReport() async {
        guard let selectedReport, selectedReport.taskState != .running, selectedReport.cleanupState != .pending else {
            return
        }
        isDeletingReport = true
        defer { isDeletingReport = false }
        do {
            guard try await state.deleteScheduledAgentReport(id: selectedReport.id, projectID: projectID) else {
                detailError = "This report is no longer available."
                self.selectedReport = nil
                return
            }
            reports.removeAll { $0.id == selectedReport.id }
            pageOffset = reports.count
            self.selectedReport = nil
            selectedReportID = nil
            detailError = nil
        } catch ScheduledAgentReportStoreError.reportNotSettled(_) {
            detailError = "This report is still active and cannot be deleted."
        } catch {
            detailError = error.localizedDescription
        }
    }

    private func taskColor(_ state: ScheduledAgentTaskState) -> String {
        switch state {
        case .running: "accent"
        case .succeeded: "add"
        case .failed: "del"
        case .needsAttention, .interrupted: "warn"
        }
    }

    private func webURL(_ rawValue: String) -> URL? {
        guard let url = URL(string: rawValue),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            return nil
        }
        return url
    }
}
