import SwiftUI

struct RepoHookApprovalPresentationHandler: ViewModifier {
    let approvalQueue: RepoHookApprovalQueue
    var isActive = true
    /// Whether this view participates in dialog routing while `isActive` is false.
    var registersPresenter = true
    @State private var presenterID = UUID()

    func body(content: Content) -> some View {
        @Bindable var queue = approvalQueue
        let requestBinding = presentationBinding(for: $queue.activeDialogRequest)
        content
            .onChange(of: registersPresenter, initial: true) { _, shouldRegister in
                if shouldRegister {
                    queue.registerDialogPresenter(id: presenterID)
                } else {
                    queue.unregisterDialogPresenter(id: presenterID)
                }
            }
            .onDisappear { queue.unregisterDialogPresenter(id: presenterID) }
            .sheet(item: requestBinding) { request in
                RepoHookApprovalSheet(request: request, queue: queue)
            }
    }

    func presentationBinding(
        for queueBinding: Binding<RepoHookApprovalRequest?>
    ) -> Binding<RepoHookApprovalRequest?> {
        Binding(
            get: { isActive ? queueBinding.wrappedValue : nil },
            set: { request in
                guard isActive else { return }
                queueBinding.wrappedValue = request
            }
        )
    }
}

struct RepoHookApprovalSheet: View {
    let request: RepoHookApprovalRequest
    @Bindable private var queue: RepoHookApprovalQueue

    init(request: RepoHookApprovalRequest, queue: RepoHookApprovalQueue) {
        self.request = request
        _queue = Bindable(wrappedValue: queue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.isReadOnlyReview ? "Approved repository hook" : "Repository startup hook")
                .font(.headline)
            Text("\(request.event.title) hook at \(request.event.relativePath) from \(sourceDescription).")
                .fixedSize(horizontal: false, vertical: true)
            if let hook = request.hook {
                if !request.isReadOnlyReview {
                    Text("Approval applies only to these exact contents. Changed contents will require approval again.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ScrollView(.vertical) {
                    Text(hook.text)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 280, alignment: .topLeading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            } else if let failure = request.failure {
                Text("This repository hook could not be prepared: \(failure.message)")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                Text("Retry or continue without this repository hook.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if request.isReadOnlyReview {
                    Spacer()
                    Button("Close") {
                        queue.decide(.cancel)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    if request.context.allowsCancel {
                        Button("Cancel", role: .cancel) {
                            queue.decide(.cancel)
                        }
                    }
                    Spacer()
                    Button(request.context.skipTitle) {
                        queue.decide(.skip)
                    }
                    .accessibilityIdentifier("repo-hook-approval-skip")
                    if request.failure != nil {
                        Button("Retry") {
                            queue.decide(.retry)
                        }
                        .accessibilityIdentifier("repo-hook-approval-retry")
                    }
                    if request.hook != nil {
                        Button(approveTitle) {
                            queue.decide(.approve)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 620)
        .interactiveDismissDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            request.isReadOnlyReview
                ? "Repository startup hook review"
                : "Repository startup hook approval"
        )
    }

    private var sourceDescription: String {
        switch request.source {
        case .local: "this Mac"
        case let .remote(host): host
        }
    }

    private var approveTitle: String {
        switch request.context.kind {
        case .sessionOpen: "Approve and open"
        case .worktreeCreate: "Approve and finish"
        case .workspaceMember: "Approve and finish member"
        case .projectSettings: "Approve hook"
        }
    }
}
