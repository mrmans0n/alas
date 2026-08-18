import AppKit
import SwiftUI

struct GGInboxTabState: Codable, Equatable, Identifiable {
    let id: TabID          // "gg-inbox:<projectId>"
    let projectId: String
    var title: String

    init(projectId: String, projectName: String) {
        self.id = "gg-inbox:\(projectId)"
        self.projectId = projectId
        self.title = "Inbox — \(projectName)"
    }
}

/// Best-effort stack → live-worktree mapping using gg's
/// `<username>/<stack-name>` branch convention.
enum GGInboxWorktreeResolver {
    static func worktreeId(
        stackName: String,
        username: String?,
        worktrees: [(id: String, branch: String)]
    ) -> String? {
        guard !hasAmbiguousLocalOwners(stackName: stackName, worktrees: worktrees) else { return nil }
        if let username {
            return worktrees.first(where: { $0.branch == "\(username)/\(stackName)" })?.id
        }
        return worktrees.first(where: { stackNameComponent(ofBranch: $0.branch) == stackName })?.id
    }

    /// True when more than one local worktree branch matches gg's
    /// `<username>/<stackName>` convention for this stack name — i.e. more
    /// than one person's stack shares the name. gg infers per-entry
    /// ownership from local branches (its `infer_stack_usernames` scans them
    /// for the naming convention), and its inbox JSON carries only
    /// `stack_name` with no owner, so a second matching branch means a given
    /// row can't be safely attributed to either one. This is independent of
    /// how many inbox rows reference the name — a single stack with several
    /// positions/PRs is normal and must never be treated as ambiguous.
    static func hasAmbiguousLocalOwners(
        stackName: String,
        worktrees: [(id: String, branch: String)]
    ) -> Bool {
        worktrees.filter { stackNameComponent(ofBranch: $0.branch) == stackName }.count > 1
    }

    /// Everything after the FIRST `/` in a gg-convention branch
    /// (`<username>/<stackName>`). gg stack names can themselves contain
    /// slashes (path-style names), so only the first slash separates the
    /// username — a suffix match on the whole branch string would falsely
    /// conflate an unrelated nested stack (e.g. `feature/auth`) with a
    /// top-level stack of a shorter name (`auth`). Nil for a branch with no
    /// slash at all (not gg-convention shaped).
    private static func stackNameComponent(ofBranch branch: String) -> String? {
        guard let slashIndex = branch.firstIndex(of: "/") else { return nil }
        return String(branch[branch.index(after: slashIndex)...])
    }
}

/// Project-scoped triage tab over `gg inbox`. Navigation-first: rows focus
/// the matching live worktree; landing/syncing stays in the per-worktree
/// drawer.
struct GGInboxTabView: View {
    let state: AppState
    let tabState: GGInboxTabState
    var onStartupRecoveryReady: () -> Void = {}

    @Environment(\.theme) private var theme
    @State private var ggUpgrade = GGInstallController()
    private let store = GGInboxStore.shared
    private let service = GGService()

    private var inboxState: GGInboxStore.State { store.states[tabState.projectId] ?? .init() }
    private var project: ProjectConfig? { state.projects.first { $0.id == tabState.projectId } }
    private var supportsStreamingInbox: Bool {
        GGInboxSupport.isSupported(version: GGAvailability.shared.version)
    }

    // MARK: pure helpers (tested)

    static func updatedLabel(fetchedAt: Date?, now: Date) -> String? {
        guard let fetchedAt else { return nil }
        let seconds = now.timeIntervalSince(fetchedAt)
        if seconds < 60 { return "Updated just now" }
        if seconds < 3_600 { return "Updated \(Int(seconds / 60))m ago" }
        return "Updated \(Int(seconds / 3_600))h ago"
    }

    static func refreshLabel(_ progress: GGInboxRefreshProgress?) -> String? {
        guard let progress else { return nil }
        return "Refreshing \(progress.completed)/\(progress.total)"
    }

    static func shouldShowClearInbox(
        snapshot: GGInboxSnapshot?,
        isRefreshing: Bool,
        lastError: String?
    ) -> Bool {
        guard let snapshot else { return false }
        return snapshot.totalItems == 0 && snapshot.stackErrors.isEmpty
            && !isRefreshing && lastError == nil
    }

    static func shouldRefreshAfterSupportTransition(
        wasSupported: Bool,
        isSupported: Bool,
        snapshot: GGInboxSnapshot?,
        fetchedAt: Date?,
        now: Date
    ) -> Bool {
        guard !wasSupported, isSupported else { return false }
        return snapshot == nil || GGInboxStore.isStale(fetchedAt: fetchedAt, now: now)
    }

    static func shouldShowUpgradeRequired(hasProbed: Bool, supportsStreamingInbox: Bool) -> Bool {
        hasProbed && !supportsStreamingInbox
    }

    static func shouldInstallGG(version: String?) -> Bool {
        version == nil
    }

    static func validPRURL(_ rawValue: String?) -> URL? {
        guard let rawValue, let url = URL(string: rawValue),
              url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    static func reviewRequestKind(prURL: String?) -> CodeHostKind {
        guard let url = validPRURL(prURL),
              url.pathComponents.contains("merge_requests") else { return .github }
        return .gitlab
    }

    static func ciIconName(_ status: String?) -> String? {
        switch GGCIStatus(rawValue: status ?? "") {
        case .success:            return "checkmark.circle"
        case .failed, .canceled:  return "xmark.circle"
        case .running, .pending:  return "clock"
        case .unknown, .none:     return nil
        }
    }

    static func ciIconColorToken(_ status: String?) -> String {
        switch GGCIStatus(rawValue: status ?? "") {
        case .success:            return "add"
        case .failed, .canceled:  return "del"
        case .running, .pending:  return "caution"
        case .unknown, .none:     return "fg-dim"
        }
    }

    static func commitCountLabel(_ count: Int) -> String {
        "\(count) commit\(count == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(theme.color("line"))
            content
        }
        .background(theme.color("bg-1"))
        .onAppear { refreshIfStale(onComplete: onStartupRecoveryReady) }
        .onChange(of: ggUpgrade.phase) { _, phase in
            guard phase == .succeeded, supportsStreamingInbox else { return }
            refresh()
        }
        .onChange(of: GGAvailability.shared.hasProbed) { _, hasProbed in
            guard hasProbed else { return }
            refreshIfStale(onComplete: onStartupRecoveryReady)
        }
        .onChange(of: supportsStreamingInbox) { wasSupported, isSupported in
            guard Self.shouldRefreshAfterSupportTransition(
                wasSupported: wasSupported,
                isSupported: isSupported,
                snapshot: inboxState.snapshot,
                fetchedAt: inboxState.fetchedAt,
                now: Date()
            ) else { return }
            refreshIfStale(onComplete: onStartupRecoveryReady)
        }
        .onChange(of: inboxState.isRefreshing) { wasRefreshing, isRefreshing in
            guard wasRefreshing, !isRefreshing else { return }
            onStartupRecoveryReady()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Icon(name: "branch", size: 12, color: theme.color("fg-muted"))
            Text(tabState.title).font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.color("fg"))
            if let snapshot = inboxState.snapshot {
                Text(Self.commitCountLabel(snapshot.totalItems))
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundColor(theme.color("fg-dim"))
            }
            Spacer()
            if inboxState.isRefreshing {
                Spinner(lineWidth: 1.4, duration: 0.8).frame(width: 11, height: 11)
                if let label = Self.refreshLabel(inboxState.refreshProgress) {
                    Text(label).font(.system(size: 11)).foregroundColor(theme.color("fg-faint"))
                }
            } else {
                if let label = Self.updatedLabel(fetchedAt: inboxState.fetchedAt, now: Date()) {
                    Text(label).font(.system(size: 11)).foregroundColor(theme.color("fg-faint"))
                }
                Button { refresh() } label: {
                    Icon(name: "arrow.clockwise", size: 11, color: theme.color("fg-faint"))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("Refresh inbox")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if !GGAvailability.shared.hasProbed {
            probingState
        } else if Self.shouldShowUpgradeRequired(
            hasProbed: GGAvailability.shared.hasProbed,
            supportsStreamingInbox: supportsStreamingInbox
        ) {
            upgradeRequiredState
        } else {
            if let error = inboxState.lastError {
                errorBanner(error)
            }
            if let snapshot = inboxState.snapshot {
                if Self.shouldShowClearInbox(
                    snapshot: snapshot,
                    isRefreshing: inboxState.isRefreshing,
                    lastError: inboxState.lastError
                ) {
                    emptyState
                } else {
                    bucketList(snapshot)
                }
            } else {
                Spacer()
            }
        }
    }

    private var probingState: some View {
        VStack(spacing: 8) {
            Spacer()
            Spinner(lineWidth: 1.5, duration: 0.7).frame(width: 12, height: 12)
            Text("Checking gg version…")
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-dim"))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var upgradeRequiredState: some View {
        let needsInstall = Self.shouldInstallGG(version: GGAvailability.shared.version)
        return VStack(alignment: .leading, spacing: 8) {
            Spacer()
            Text(needsInstall ? "Inbox needs gg installed." : "Inbox needs a newer gg version.")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.color("fg"))
            if let version = GGAvailability.shared.version {
                Text("gg \(version)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.color("fg-muted"))
            }
            Text(needsInstall ? "Install gg to use Inbox." : "gg Inbox requires gg 0.9.12 or newer.")
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-dim"))
            upgradeStatus
            AlasButton(title: needsInstall ? "Install gg…" : "Upgrade gg…", style: .normal) {
                if needsInstall {
                    ggUpgrade.install()
                } else {
                    ggUpgrade.upgrade()
                }
            }
                .disabled(ggUpgrade.phase == .running)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(14)
    }

    @ViewBuilder
    private var upgradeStatus: some View {
        let needsInstall = Self.shouldInstallGG(version: GGAvailability.shared.version)
        switch ggUpgrade.phase {
        case .idle, .succeeded:
            EmptyView()
        case .running:
            HStack(spacing: 6) {
                Spinner(lineWidth: 1.5, duration: 0.7).frame(width: 10, height: 10)
                Text(needsInstall ? "Installing…" : "Upgrading…")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-dim"))
            }
        case .failed(let message):
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(theme.color("warn"))
                .lineLimit(2)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("Inbox is clear.").font(.system(size: 13))
                .foregroundColor(theme.color("fg-dim"))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Text(message).font(.system(size: 11)).foregroundColor(.red)
                .lineLimit(2)
            Spacer()
            Button("Retry") { refresh() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.color("accent"))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(theme.color("bg-2"))
    }

    private func bucketList(_ snapshot: GGInboxSnapshot) -> some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(GGInboxBucket.allCases, id: \.self) { bucket in
                        let entries = bucket.entries(in: snapshot.buckets)
                        if !entries.isEmpty {
                            bucketSection(bucket, entries: entries)
                        }
                    }
                    if !snapshot.stackErrors.isEmpty {
                        stackErrorsSection(snapshot.stackErrors)
                    }
                }
                .frame(
                    maxWidth: ACPChatLayout.contentMaxWidth(forPaneWidth: proxy.size.width),
                    alignment: .leading
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private func bucketSection(_ bucket: GGInboxBucket, entries: [GGInboxEntry]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(bucket.title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold)).tracking(0.5)
                    .foregroundColor(theme.color("fg-muted"))
                Text(Self.commitCountLabel(entries.count))
                    .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                    .foregroundColor(theme.color(bucket.themeToken))
            }
            .padding(.top, 10).padding(.bottom, 4)
            ForEach(entries, id: \.sha) { entry in
                row(entry, bucket: bucket)
            }
        }
    }

    private func row(_ entry: GGInboxEntry, bucket: GGInboxBucket) -> some View {
        let targetWorktreeId = resolveWorktreeId(entry)
        let kind = Self.reviewRequestKind(prURL: entry.prUrl)
        let tint = theme.color(bucket.themeToken)
        return HStack(spacing: 10) {
            Text("\(entry.position)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.color("fg-faint"))

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    Text(entry.stackName)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(theme.color("fg-muted"))
                        .lineLimit(1)
                    if let icon = Self.ciIconName(entry.ciStatus) {
                        Icon(
                            name: icon,
                            size: 10,
                            color: theme.color(Self.ciIconColorToken(entry.ciStatus))
                        )
                    }
                }
                if let refreshError = entry.refreshError {
                    Text(refreshError)
                        .font(.system(size: 10.5))
                        .foregroundColor(theme.color("warn"))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                if let url = Self.validPRURL(entry.prUrl) {
                    Button { NSWorkspace.shared.open(url) } label: {
                        reviewReferenceLabel(entry.prNumber, kind: kind)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help(
                        Text(
                            verbatim: "Open \(kind.reviewRequestLabel) "
                                + "\(kind.reviewRequestNumberPrefix)\(entry.prNumber)"
                        )
                    )
                } else {
                    reviewReferenceLabel(entry.prNumber, kind: kind)
                }
                if let behind = entry.behindBase, behind > 0 {
                    Text("behind \(behind)")
                        .font(.system(size: 10.5))
                        .foregroundColor(theme.color("warn"))
                }
            }
            .frame(width: 64, alignment: .trailing)
            .padding(.leading, 10)
            .overlay(alignment: .leading) {
                Rectangle().fill(tint.opacity(0.28)).frame(width: 0.5)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(tint.opacity(0.28), lineWidth: 0.5)
        }
        .contentShape(Rectangle())
        .opacity(targetWorktreeId == nil ? 0.55 : 1)
        .onTapGesture {
            if let id = targetWorktreeId { state.selectWorktree(id: id) }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.return) {
            if let id = targetWorktreeId {
                state.selectWorktree(id: id)
                return .handled
            }
            return .ignored
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.stackName): \(entry.title)")
        .accessibilityHint(targetWorktreeId == nil ? "No live worktree" : "Focus worktree")
        .accessibilityAddTraits(.isButton)
    }

    private func stackErrorsSection(_ errors: [GGInboxStackError]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("STACK ERRORS")
                .font(.system(size: 10.5, weight: .semibold)).tracking(0.5)
                .foregroundColor(theme.color("warn"))
                .padding(.top, 12).padding(.bottom, 4)
            ForEach(errors, id: \.stackName) { item in
                HStack(spacing: 8) {
                    Text(item.stackName).font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.color("fg-muted"))
                    Text(item.error).font(.system(size: 11))
                        .foregroundColor(theme.color("fg-dim")).lineLimit(2)
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func reviewReferenceLabel(_ number: Int, kind: CodeHostKind) -> some View {
        Text(verbatim: "\(kind.reviewRequestNumberPrefix)\(number)")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(theme.color("accent"))
    }

    // MARK: actions

    private func resolveWorktreeId(_ entry: GGInboxEntry) -> String? {
        guard let project else { return nil }
        let worktrees = state.projectsManager.visibleWorktrees(projectId: project.id)
            .map { (id: $0.id, branch: $0.branch) }
        return GGInboxWorktreeResolver.worktreeId(
            stackName: entry.stackName,
            username: GGConfigReader.branchUsername(repoPath: project.path),
            worktrees: worktrees
        )
    }

    private func refreshIfStale(onComplete: (() -> Void)? = nil) {
        guard GGAvailability.shared.hasProbed else { return }
        guard supportsStreamingInbox else {
            onComplete?()
            return
        }
        guard inboxState.snapshot == nil
            || GGInboxStore.isStale(fetchedAt: inboxState.fetchedAt, now: Date()) else {
            onComplete?()
            return
        }
        guard !inboxState.isRefreshing else { return }
        refresh(onComplete: onComplete)
    }

    private func refresh(onComplete: (() -> Void)? = nil) {
        guard supportsStreamingInbox, let project, state.ggInboxAvailable(projectId: project.id) else {
            onComplete?()
            return
        }
        Task { @MainActor in
            if await store.refresh(projectId: project.id, repoPath: project.path, service: service) {
                onComplete?()
            }
        }
    }
}
