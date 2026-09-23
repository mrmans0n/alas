import SwiftUI

struct RepoHookApprovalSheet: View {
    let request: RepoHookApprovalRequest
    @Bindable private var queue: RepoHookApprovalQueue

    init(request: RepoHookApprovalRequest, queue: RepoHookApprovalQueue) {
        self.request = request
        _queue = Bindable(wrappedValue: queue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Repository startup hook")
                .font(.headline)
            Text("\(request.event.title) hook at \(request.event.relativePath) from \(sourceDescription).")
                .fixedSize(horizontal: false, vertical: true)
            if let hook = request.hook {
                Text("Approval applies only to these exact contents. Changed contents will require approval again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(hook.text)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .textSelection(.enabled)
            } else if let failure = request.failure {
                Text("Alas could not read this hook: \(failure.message)")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                Text("Retry the read or continue without this repository hook.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if request.context.allowsCancel {
                    Button("Cancel", role: .cancel) {
                        queue.decide(.cancel)
                    }
                }
                Spacer()
                Button(request.failure == nil ? request.context.skipTitle : "Retry") {
                    queue.decide(request.failure == nil ? .skip : .retry)
                }
                if request.hook != nil {
                    Button(approveTitle) {
                        queue.decide(.approve)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .frame(width: 620)
        .interactiveDismissDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Repository startup hook approval")
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
