import AppKit
import SwiftUI

enum ReviewEvidenceFilesContentState: Equatable {
    case loading
    case error(String)
    case diffSurface
    case empty
}

enum ReviewEvidenceContentRoute: Equatable {
    case files(ReviewEvidenceFilesContentState)
    case evidenceBrowser
}

struct ReviewEvidenceTabView: View {
    let worktreePath: URL
    let tabState: ReviewEvidenceTabState
    @Bindable var appState: AppState

    @State private var model: ReviewEvidenceModel?
    @State private var selectedSection: ReviewEvidenceSection
    @State private var loadNonce = 0
    @State private var isRerunningFailedChecks = false
    @State private var loadGeneration = 0
    @State private var selectedFileID: DiffReviewFileID?
    @State private var railCollapsed = false

    @Environment(\.theme) private var theme

    init(worktreePath: URL, tabState: ReviewEvidenceTabState, appState: AppState) {
        self.worktreePath = worktreePath
        self.tabState = tabState
        self.appState = appState
        _selectedSection = State(initialValue: tabState.selectedSection)
    }

    private var activeSnapshot: ReviewLoopSnapshot? {
        appState.rightPaneStore.activeState(worktreeId: tabState.worktreeId)?.reviewLoop.snapshot
    }

    private var snapshot: ReviewLoopSnapshot? {
        guard let activeSnapshot, tabState.matches(activeSnapshot) else { return nil }
        return activeSnapshot
    }

    private var canSendToAgent: Bool {
        let agentID = appState.config.changes.aiToolId
        return agentID != "none" && appState.agent(id: agentID) != nil
    }

    private var diffPreferences: DiffPreferenceBindings {
        DiffPreferenceBindings(appState: appState)
    }

    private var loadKey: String {
        let head = snapshot?.local.headSHA ?? "no-head"
        let providerState = "\(snapshot?.providerAvailable == true):\(snapshot?.providerAuthenticated == true)"
        let request = snapshot?.reviewRequest.map(reviewEvidenceRevisionKey) ?? "no-request"
        return "\(tabState.id):\(head):\(providerState):\(request):\(loadNonce)"
    }

    private func reviewEvidenceRevisionKey(for request: ReviewRequest) -> String {
        let checks = request.checks
            .sorted { $0.id < $1.id }
            .map { check in
                let completedAt = check.completedAt.map { String($0.timeIntervalSince1970) } ?? "nil"
                return [
                    check.id,
                    check.name,
                    check.workflow ?? "nil",
                    check.bucket.rawValue,
                    check.detailURL?.absoluteString ?? "nil",
                    completedAt
                ].joined(separator: ",")
            }
            .joined(separator: ";")
        let threads = request.threads
            .sorted { $0.id < $1.id }
            .map { thread in
                [
                    thread.id,
                    thread.author ?? "nil",
                    thread.body,
                    thread.url?.absoluteString ?? "nil",
                    String(thread.isResolved),
                    String(thread.isActionable)
                ].joined(separator: ",")
            }
            .joined(separator: ";")
        return [
            request.id,
            request.state.rawValue,
            String(request.isDraft),
            request.reviewDecision.rawValue,
            request.mergeState.rawValue,
            checks,
            threads
        ].joined(separator: "|")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(theme.color("bg-0"))
        .task(id: loadKey) {
            await loadEvidence()
        }
        .onChange(of: tabState.selectedSection) { _, section in
            applySelectedSection(section, loadDetail: true)
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            Icon(name: "doc.text.magnifyingglass", size: 14, color: theme.color("accent"))
            VStack(alignment: .leading, spacing: 3) {
                Text(identityTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(requestTitle)
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("fg-dim"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if let snapshot {
                        statusChips(snapshot)
                    }
                }
            }
            Spacer()
            if model?.isLoadingList == true {
                Spinner(lineWidth: 1.5, duration: 0.7)
                    .frame(width: 14, height: 14)
            }
            AlasButton(title: "Refresh", icon: "arrow.clockwise") {
                refreshEvidence()
            }
            if let url = reviewRequestURL {
                AlasButton(title: snapshotProvider.openReviewRequestTitle, icon: "arrow.up.right.square") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.color("bg-1"))
    }

    @ViewBuilder
    private var content: some View {
        if let unavailableMessage {
            unavailableState(message: unavailableMessage)
        } else if let model {
            if let message = model.errorMessage, Self.shouldShowModelUnavailable(model, selectedSection: selectedSection) {
                unavailableState(message: message)
            } else {
                evidenceBrowser(model: model)
            }
        } else {
            Spinner()
                .frame(width: 20, height: 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    static func shouldShowModelUnavailable(_ model: ReviewEvidenceModel) -> Bool {
        shouldShowModelUnavailable(model, selectedSection: model.selectedSection)
    }

    static func shouldShowModelUnavailable(_ model: ReviewEvidenceModel, selectedSection: ReviewEvidenceSection) -> Bool {
        shouldShowModelUnavailable(
            selectedSection: selectedSection,
            isLoadingFiles: model.isLoadingFiles,
            fileErrorMessage: model.fileErrorMessage,
            fileSession: model.fileSession,
            ciItemsAreEmpty: model.ciItems.isEmpty,
            feedbackItemsAreEmpty: model.feedbackItems.isEmpty,
            modelErrorMessage: model.errorMessage
        )
    }

    static func shouldShowModelUnavailable(
        selectedSection: ReviewEvidenceSection,
        isLoadingFiles: Bool,
        fileErrorMessage: String?,
        fileSession: DiffReviewLoadedSession?,
        ciItemsAreEmpty: Bool,
        feedbackItemsAreEmpty: Bool,
        modelErrorMessage: String?
    ) -> Bool {
        let hasOnlyModelError = modelErrorMessage != nil
            && ciItemsAreEmpty
            && feedbackItemsAreEmpty
        guard hasOnlyModelError else { return false }

        return !isLoadingFiles
            && fileErrorMessage == nil
            && fileSession == nil
    }

    static func contentRoute(
        selectedSection: ReviewEvidenceSection,
        isLoadingFiles: Bool,
        fileErrorMessage: String?,
        fileSession: DiffReviewLoadedSession?,
        modelErrorMessage: String?
    ) -> ReviewEvidenceContentRoute {
        guard selectedSection == .files else { return .evidenceBrowser }

        return .files(filesContentState(
            isLoadingFiles: isLoadingFiles,
            fileErrorMessage: fileErrorMessage,
            fileSession: fileSession
        ))
    }

    static func filesContentState(
        isLoadingFiles: Bool,
        fileErrorMessage: String?,
        fileSession: DiffReviewLoadedSession?
    ) -> ReviewEvidenceFilesContentState {
        if isLoadingFiles {
            return .loading
        }
        if let fileErrorMessage, fileSession == nil {
            return .error(fileErrorMessage)
        }
        if let fileSession, !fileSession.files.isEmpty {
            return .diffSurface
        }
        return .empty
    }

    private func evidenceBrowser(model: ReviewEvidenceModel) -> some View {
        VStack(spacing: 0) {
            Picker("Evidence section", selection: sectionSelectionBinding(model: model)) {
                ForEach(ReviewEvidenceSection.allCases, id: \.self) { section in
                    Text(section.displayName).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .padding(.vertical, 10)

            Divider()

            switch Self.contentRoute(
                selectedSection: selectedSection,
                isLoadingFiles: model.isLoadingFiles,
                fileErrorMessage: model.fileErrorMessage,
                fileSession: model.fileSession,
                modelErrorMessage: model.errorMessage
            ) {
            case .files(let state):
                filesPane(state: state, session: model.fileSession)
            case .evidenceBrowser:
                HStack(spacing: 0) {
                    evidenceList(model: model)
                        .frame(minWidth: 220, idealWidth: 300, maxWidth: 360, maxHeight: .infinity)
                        .background(theme.color("bg-1"))
                    Divider()
                    detailPane(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(theme.color("bg-0"))
                }
            }
        }
    }

    @ViewBuilder
    private func filesPane(state: ReviewEvidenceFilesContentState, session: DiffReviewLoadedSession?) -> some View {
        switch state {
        case .loading:
            VStack(spacing: 10) {
                Spinner()
                    .frame(width: 20, height: 20)
                Text("Loading files")
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg-dim"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.color("bg-1"))
        case .error(let message):
            unavailableState(message: message)
                .background(theme.color("bg-1"))
        case .diffSurface:
            if let session {
                DiffReviewSurface(
                    session: session,
                    selectedFileID: $selectedFileID,
                    railCollapsed: $railCollapsed,
                    layoutMode: diffPreferences.layoutMode,
                    wrapLines: diffPreferences.wrapLines,
                    showWhitespace: diffPreferences.showWhitespace,
                    codeFontFamily: appState.config.code.fontFamily,
                    codeFontSize: CGFloat(appState.config.code.fontSize),
                    showsSourceBadges: true,
                    showsRailDisplayControls: true
                )
            } else {
                filesEmptyState
            }
        case .empty:
            filesEmptyState
        }
    }

    private var filesEmptyState: some View {
        Text("No changed files")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(theme.color("fg-dim"))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.color("bg-1"))
    }

    private func evidenceList(model: ReviewEvidenceModel) -> some View {
        let items = model.items(for: selectedSection)

        return Group {
            if model.isLoadingList {
                Spinner()
                    .frame(width: 18, height: 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                Text(emptyText(for: selectedSection))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.color("fg-dim"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            evidenceRow(item: item, isSelected: isSelected(item, in: model))
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func evidenceRow(item: ReviewEvidenceItem, isSelected: Bool) -> some View {
        Button {
            if let model {
                selectItem(item, in: model, loadDetail: true)
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                statusDot(for: item.status)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.color("fg"))
                        .lineLimit(2)
                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(theme.color("fg-dim"))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(isSelected ? theme.color("accent").opacity(0.18) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func detailPane(model: ReviewEvidenceModel) -> some View {
        if model.isLoadingDetail {
            VStack(spacing: 10) {
                Spinner()
                    .frame(width: 20, height: 20)
                Text("Loading evidence detail")
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg-dim"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let detail = visibleDetail(in: model) {
            VStack(spacing: 0) {
                detailHeader(detail, snapshot: model.snapshot)
                Divider()
                ScrollView([.horizontal, .vertical]) {
                    Text(detail.body)
                        .font(CenterTypography.codeFont(
                            family: appState.config.code.fontFamily,
                            size: CGFloat(appState.config.code.fontSize)
                        ))
                        .foregroundColor(theme.color("fg"))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
            }
        } else {
            Text("Select an evidence item")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.color("fg-dim"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailHeader(_ detail: ReviewEvidenceDetail, snapshot: ReviewLoopSnapshot) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(detail.item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                if let location = detailLocation(detail) {
                    Text(location)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.color("fg-dim"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if let url = detail.item.providerURL {
                AlasButton(title: "Open in Browser", icon: "arrow.up.right.square") {
                    NSWorkspace.shared.open(url)
                }
            }
            if canRerunFailedChecks(for: detail, snapshot: snapshot) {
                AlasButton(title: isRerunningFailedChecks ? "Rerunning" : "Rerun Failed", icon: "arrow.clockwise") {
                    rerunFailedChecks(snapshot: snapshot)
                }
                .disabled(isRerunningFailedChecks)
            }
            AlasButton(title: "Copy Context", icon: "doc.on.doc") {
                copyContext(detail)
            }
            AlasButton(title: "Send to Agent", icon: "sparkle", style: .primary) {
                appState.openReviewEvidenceHandoff(snapshot: snapshot, detail: detail)
            }
            .disabled(!canSendToAgent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.color("bg-1"))
    }

    private var unavailableMessage: String? {
        guard let activeSnapshot else {
            return "Review evidence is unavailable because review state is not loaded."
        }
        guard tabState.matches(activeSnapshot) else {
            return staleReviewRequestMessage(activeSnapshot)
        }
        let snapshot = activeSnapshot
        guard snapshot.remote != nil else {
            return "Review evidence is unavailable because the code host remote was not found."
        }
        guard snapshot.providerAvailable else {
            return "Provider CLI unavailable."
        }
        guard snapshot.providerAuthenticated else {
            return "Provider authentication required."
        }
        guard CodeHostProviderRegistry.live().provider(for: snapshot.remote?.kind ?? tabState.provider) != nil else {
            return "Review evidence is unavailable because \(snapshotProvider.displayName) is not supported."
        }
        return nil
    }

    private func staleReviewRequestMessage(_ snapshot: ReviewLoopSnapshot) -> String {
        let expected = "\(tabState.provider.displayName) \(tabState.provider.reviewRequestNumberPrefix)\(tabState.number)"
        guard let request = snapshot.reviewRequest else {
            return "Review evidence is for \(expected), but no active review request was found."
        }
        return "Review evidence is for \(expected), but the active review request is \(request.displayIdentity)."
    }

    private var snapshotProvider: CodeHostKind {
        snapshot?.reviewRequest?.provider ?? snapshot?.remote?.kind ?? tabState.provider
    }

    private var identityTitle: String {
        let provider = snapshotProvider
        let slug = snapshot?.remote?.repositorySlug ?? tabState.repositorySlug
        let number = snapshot?.reviewRequest?.number ?? tabState.number
        let requestNumber = number > 0 ? "\(provider.reviewRequestNumberPrefix)\(number)" : ""
        return [provider.displayName, provider.reviewRequestLabel, requestNumber, slug]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private var requestTitle: String {
        let title = snapshot?.reviewRequest?.title ?? tabState.title
        return title.isEmpty ? "Review evidence" : title
    }

    private var reviewRequestURL: URL? {
        let url = snapshot?.reviewRequest?.url ?? tabState.url
        return url.isFileURL ? nil : url
    }

    private func loadEvidence() async {
        guard let snapshot, let remote = snapshot.remote else {
            model = nil
            return
        }
        guard snapshot.providerAvailable, snapshot.providerAuthenticated else {
            model = nil
            return
        }
        guard let provider = CodeHostProviderRegistry.live().provider(for: remote.kind) else {
            model = nil
            return
        }

        loadGeneration += 1
        let generation = loadGeneration
        let initialSection = selectedSection
        let loaded = ReviewEvidenceModel(
            snapshot: snapshot,
            provider: provider,
            cwd: worktreePath,
            initialSection: initialSection,
            initialItemID: tabState.selectedItemID
        )
        model = loaded
        await loaded.load()
        guard generation == loadGeneration else { return }
        if loaded.items(for: selectedSection).isEmpty,
           selectedSection == initialSection,
           !loaded.items(for: loaded.selectedSection).isEmpty {
            selectedSection = loaded.selectedSection
        }
        let selectedItemID: String?
        if selectedSection != loaded.selectedSection {
            if let item = loaded.items(for: selectedSection).first {
                loaded.select(itemID: item.id, section: selectedSection)
                selectedItemID = loaded.selectedItemID
            } else {
                selectedItemID = nil
            }
        } else {
            selectedItemID = loaded.selectedItemID
        }
        persistSelection(section: selectedSection, itemID: selectedItemID)
        guard selectedItemID != nil else { return }
        await loaded.loadSelectedDetail()
    }

    private func isSelected(_ item: ReviewEvidenceItem, in model: ReviewEvidenceModel) -> Bool {
        model.selectedSection == selectedSection && model.selectedItemID == item.id
    }

    private func sectionSelectionBinding(model: ReviewEvidenceModel) -> Binding<ReviewEvidenceSection> {
        Binding(
            get: { selectedSection },
            set: { section in
                applySelectedSection(section, loadDetail: true)
            }
        )
    }

    private func visibleDetail(in model: ReviewEvidenceModel) -> ReviewEvidenceDetail? {
        guard model.selectedSection == selectedSection else { return nil }
        return model.selectedDetail
    }

    @ViewBuilder
    private func statusChips(_ snapshot: ReviewLoopSnapshot) -> some View {
        HStack(spacing: 4) {
            evidenceChip(title: "Checks \(checksText(snapshot.reviewRequest?.worstCheckBucket))", tone: checksTone(snapshot.reviewRequest?.worstCheckBucket))
            if let request = snapshot.reviewRequest {
                evidenceChip(title: "Review \(reviewText(request.reviewDecision))", tone: reviewTone(request.reviewDecision))
                evidenceChip(title: "Merge \(mergeText(request.mergeState))", tone: mergeTone(request.mergeState))
            }
        }
    }

    private func evidenceChip(title: String, tone: ReviewReadinessModel.Chip.Tone) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(chipForeground(tone))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(chipBackground(tone))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func checksText(_ bucket: ReviewCheckBucket?) -> String {
        guard let bucket else { return "none" }
        switch bucket {
        case .pass: return "passing"
        case .fail: return "failed"
        case .pending: return "running"
        case .skipping: return "skipped"
        case .cancel: return "cancelled"
        case .unknown: return "unknown"
        }
    }

    private func reviewText(_ decision: ReviewDecision) -> String {
        switch decision {
        case .approved: return "approved"
        case .changesRequested: return "changes requested"
        case .reviewRequired: return "required"
        case .unknown: return "unknown"
        }
    }

    private func mergeText(_ state: ReviewMergeState) -> String {
        switch state {
        case .clean: return "clean"
        case .blocked: return "blocked"
        case .dirty: return "dirty"
        case .unstable: return "unstable"
        case .unknown: return "unknown"
        }
    }

    private func checksTone(_ bucket: ReviewCheckBucket?) -> ReviewReadinessModel.Chip.Tone {
        switch bucket {
        case .pass: .success
        case .fail: .danger
        case .pending: .accent
        case .cancel, .unknown: .warning
        case .skipping, nil: .muted
        }
    }

    private func reviewTone(_ decision: ReviewDecision) -> ReviewReadinessModel.Chip.Tone {
        switch decision {
        case .approved: .success
        case .changesRequested: .warning
        case .reviewRequired, .unknown: .muted
        }
    }

    private func mergeTone(_ state: ReviewMergeState) -> ReviewReadinessModel.Chip.Tone {
        switch state {
        case .clean: .success
        case .blocked, .dirty, .unstable: .warning
        case .unknown: .muted
        }
    }

    private func chipForeground(_ tone: ReviewReadinessModel.Chip.Tone) -> Color {
        switch tone {
        case .accent: theme.color("accent")
        case .success: theme.color("add")
        case .warning: theme.color("warn")
        case .danger: theme.color("del")
        case .muted: theme.color("fg-dim")
        }
    }

    private func chipBackground(_ tone: ReviewReadinessModel.Chip.Tone) -> Color {
        chipForeground(tone).opacity(0.14)
    }

    private func canRerunFailedChecks(for detail: ReviewEvidenceDetail, snapshot: ReviewLoopSnapshot) -> Bool {
        guard detail.item.section == .ci,
              detail.item.status == .failed,
              snapshot.providerCapabilities.canRerunFailedChecks,
              let request = snapshot.reviewRequest
        else { return false }
        return request.checks.contains {
            $0.id == detail.item.id && $0.bucket == .fail && $0.workflow != nil
        }
    }

    private func rerunFailedChecks(snapshot: ReviewLoopSnapshot) {
        guard let rightPaneState = appState.rightPaneStore.activeState(worktreeId: tabState.worktreeId) else { return }
        isRerunningFailedChecks = true
        Task { @MainActor in
            if await rightPaneState.reviewLoop.rerunFailedChecks(snapshot: snapshot) {
                await rightPaneState.refresh()
                loadNonce += 1
            } else {
                let message = rightPaneState.reviewLoop.lastError ?? "Rerun failed."
                model?.showSelectedDetailError(message)
            }
            isRerunningFailedChecks = false
        }
    }

    private func applySelectedSection(_ section: ReviewEvidenceSection, loadDetail: Bool) {
        selectedSection = section
        if section == .files {
            model?.select(section: section)
            persistSelection(section: section, itemID: nil)
            return
        }
        guard let model, let item = model.items(for: section).first else {
            persistSelection(section: section, itemID: nil)
            return
        }
        selectItem(item, in: model, loadDetail: loadDetail)
    }

    private func selectItem(_ item: ReviewEvidenceItem, in model: ReviewEvidenceModel, loadDetail: Bool) {
        selectedSection = item.section
        model.select(itemID: item.id, section: item.section)
        persistSelection(section: item.section, itemID: item.id)
        guard loadDetail else { return }
        Task { await model.loadSelectedDetail() }
    }

    private func persistSelection(section: ReviewEvidenceSection, itemID: String?) {
        appState.tabs.updateReviewEvidenceSelection(
            worktreeId: tabState.worktreeId,
            tabId: tabState.id,
            selectedSection: section,
            selectedItemID: itemID
        )
    }

    private func emptyText(for section: ReviewEvidenceSection) -> String {
        switch section {
        case .files: "No changed files"
        case .ci: "No failed checks"
        case .feedback: "No actionable feedback"
        }
    }

    private func detailLocation(_ detail: ReviewEvidenceDetail) -> String? {
        guard let filePath = detail.filePath else { return detail.item.subtitle }
        if let line = detail.line {
            return "\(filePath):\(line)"
        }
        return filePath
    }

    private func copyContext(_ detail: ReviewEvidenceDetail) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(ReviewEvidenceContextFormatter.format(detail), forType: .string)
    }

    private func statusDot(for status: ReviewEvidenceStatus) -> some View {
        Circle()
            .fill(statusColor(status))
            .frame(width: 7, height: 7)
    }

    private func statusColor(_ status: ReviewEvidenceStatus) -> Color {
        switch status {
        case .failed, .actionable:
            theme.color("del")
        case .pending:
            theme.color("warn")
        case .passed, .resolved:
            theme.color("add")
        case .cancelled, .unknown:
            theme.color("fg-faint")
        }
    }

    private func unavailableState(message: String) -> some View {
        VStack(spacing: 8) {
            Icon(name: "alert", size: 18, color: theme.color("fg-dim"))
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.color("fg-dim"))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            AlasButton(title: "Refresh", icon: "arrow.clockwise") {
                refreshEvidence()
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func refreshEvidence() {
        Task { @MainActor in
            if let rightPaneState = appState.rightPaneStore.activeState(worktreeId: tabState.worktreeId) {
                await rightPaneState.refresh()
            }
            loadNonce += 1
        }
    }
}
