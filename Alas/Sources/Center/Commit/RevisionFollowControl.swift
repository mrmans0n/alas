import SwiftUI

struct RevisionFollowControl: View {
    let presentation: RevisionFollowPresentation
    let worktreeID: String
    let tabID: TabID
    let accessibilityPrefix: String
    let appState: AppState?
    var isRefreshing = false
    var onAcceptPendingCheckout: (() -> Void)?
    var onRetry: (() -> Void)?

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            tether

            if isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityIdentifier("\(accessibilityPrefix)-updating")
            }

            switch presentation {
            case .paused(_, _, _, let message):
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("warn"))
                    .lineLimit(1)
                    .accessibilityIdentifier("\(accessibilityPrefix)-pending-checkout")
                if let onAcceptPendingCheckout {
                    Button("Update", action: onAcceptPendingCheckout)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .accessibilityIdentifier("\(accessibilityPrefix)-accept-checkout")
                }
            case .stalled(_, _, let message):
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("warn"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("\(accessibilityPrefix)-unresolved")
                if let onRetry {
                    Button("Retry", action: onRetry)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .accessibilityIdentifier("\(accessibilityPrefix)-unresolved-retry")
                }
            case .failed(_, _, let message):
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("del"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("\(accessibilityPrefix)-error")
                if let onRetry {
                    Button("Retry", action: onRetry)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .accessibilityIdentifier("\(accessibilityPrefix)-error-retry")
                }
            default:
                EmptyView()
            }

            Spacer(minLength: 8)
            action
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(LinearGradient(
                    colors: [railColor.opacity(0.25), railColor, railColor.opacity(0.25)],
                    startPoint: .leading,
                    endPoint: .trailing
                ))
                .frame(height: pulse ? 2 : 1)
                .shadow(color: pulse ? railColor.opacity(0.8) : .clear, radius: 4)
                .offset(y: -9)
        }
        .onChange(of: presentation.resolvedSHA) { oldSHA, newSHA in
            guard let newSHA else { return }
            guard RevisionFollowPresentation.shouldPulse(
                previousSHA: oldSHA,
                resolvedSHA: newSHA,
                reduceMotion: reduceMotion
            ) else { return }
            pulse = true
            withAnimation(.easeOut(duration: 0.7)) { pulse = false }
        }
    }

    @ViewBuilder
    private var tether: some View {
        switch presentation {
        case .fixed(let sha):
            RevisionTetherView(expression: nil, resolvedSHA: sha)
        case .following(let expression, let resolvedSHA),
             .failed(let expression, let resolvedSHA, _),
             .stalled(let expression, let resolvedSHA, _):
            RevisionTetherView(expression: expression, resolvedSHA: resolvedSHA)
                .accessibilityIdentifier("\(accessibilityPrefix)-following-label")
        case .paused(let expression, let resolvedSHA, let candidateSHA, _):
            RevisionTetherView(expression: expression, resolvedSHA: resolvedSHA, candidateSHA: candidateSHA)
                .accessibilityIdentifier("\(accessibilityPrefix)-following-label")
        }
    }

    @ViewBuilder
    private var action: some View {
        switch presentation {
        case .fixed:
            Button {
                appState?.promptFollowRevision(worktreeID: worktreeID, tabID: tabID)
            } label: {
                Label("Follow a revision", systemImage: "link.badge.plus")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(appState == nil)
            .accessibilityIdentifier("\(accessibilityPrefix)-follow")
            .popover(isPresented: editorPresented, arrowEdge: .bottom) {
                editor
            }
        default:
            Menu("Following") {
                Button("Edit revision…") {
                    appState?.promptFollowRevision(
                        worktreeID: worktreeID,
                        tabID: tabID,
                        prefill: presentation.expression.map { .expression($0) }
                    )
                }
                .accessibilityIdentifier("\(accessibilityPrefix)-edit")
                Button("Stop following", role: .destructive) {
                    appState?.stopFollowingRevision(worktreeID: worktreeID, tabID: tabID)
                }
                .accessibilityIdentifier("\(accessibilityPrefix)-stop")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(appState == nil)
            .popover(isPresented: editorPresented, arrowEdge: .bottom) {
                editor
            }
        }
    }

    private var editorPresented: Binding<Bool> {
        Binding(
            get: { editorRequest != nil },
            set: { if !$0 { appState?.dismissFollowRevisionEditor() } }
        )
    }

    private var editorRequest: FollowRevisionEditorRequest? {
        guard let request = appState?.followRevisionEditorRequest,
              request.matches(worktreeID: worktreeID, tabID: tabID)
        else { return nil }
        return request
    }

    private var expression: Binding<String> {
        Binding(
            get: { editorRequest?.expression ?? "" },
            set: { value in
                guard var request = editorRequest else { return }
                request.expression = value
                request.errorMessage = nil
                appState?.followRevisionEditorRequest = request
            }
        )
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(editorRequest?.isEditing == true ? "Edit followed revision" : "Follow a revision")
                .font(.system(size: 13, weight: .semibold))
            Text("Enter a Git revision, such as HEAD~3.")
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-muted"))
            AlasField(
                text: expression,
                placeholder: "HEAD~3",
                monospaced: true,
                focusOnAppear: true,
                onSubmit: { appState?.submitFollowRevisionEditor() },
                isEnabled: editorRequest?.isSubmitting != true
            )
            if let error = editorRequest?.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("del"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { appState?.dismissFollowRevisionEditor() }
                    .keyboardShortcut(.cancelAction)
                Button("Follow") { appState?.submitFollowRevisionEditor() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(editorRequest?.submissionExpression == nil || editorRequest?.isSubmitting == true)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private var railColor: Color {
        switch presentation {
        case .failed: theme.color("del")
        case .paused, .stalled: theme.color("warn")
        case .following: theme.color("accent")
        case .fixed: theme.color("line")
        }
    }
}

struct RevisionTetherView: View {
    let expression: String?
    let resolvedSHA: String
    var candidateSHA: String?

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            chip(expression ?? resolvedSHA, color: expression == nil ? theme.color("fg-muted") : theme.color("accent"))
            if expression == nil {
                Text("┄")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.color("line"))
            } else {
                Rectangle()
                    .fill(theme.color("accent").opacity(0.55))
                    .frame(width: 18, height: 1)
                chip(resolvedSHA, color: theme.color("add"))
            }
            if let candidateSHA {
                Image(systemName: "link.slash")
                    .font(.system(size: 9))
                    .foregroundColor(theme.color("warn"))
                chip(candidateSHA, color: theme.color("warn"))
            }
        }
        .lineLimit(1)
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

private extension RevisionFollowPresentation {
    var expression: String? {
        switch self {
        case .following(let expression, _),
             .paused(let expression, _, _, _),
             .stalled(let expression, _, _),
             .failed(let expression, _, _): expression
        case .fixed: nil
        }
    }

    var resolvedSHA: String? {
        switch self {
        case .fixed(let sha): sha
        case .following(_, let sha),
             .paused(_, let sha, _, _),
             .stalled(_, let sha, _),
             .failed(_, let sha, _): sha
        }
    }
}
