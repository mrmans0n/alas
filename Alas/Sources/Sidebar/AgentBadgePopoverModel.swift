import AlasACP
import Foundation

/// What the hover popover on a sidebar agent badge shows, decided apart from
/// the view so the copy and the per-status body can be tested.
struct AgentBadgePopoverModel: Equatable {
    enum Status: Equatable {
        case running, awaitingInput, permission, limited, failed, idle

        /// Running shows the plan and a permission shows the request; the
        /// rest show the start of the agent's last reply.
        var showsReply: Bool {
            switch self {
            case .running, .permission: false
            case .awaitingInput, .idle, .failed, .limited: true
            }
        }

        /// The badge tile's own hue, so the chip and the tile always agree.
        var dotColorToken: String {
            let state: HarnessService.AggregatedState? = switch self {
            case .running: .running
            case .awaitingInput, .permission: .awaiting
            case .limited: .limited
            case .failed: .failed
            case .idle: nil
            }
            return state.map { HarnessSessionBadgeSurface(state: $0).colorToken } ?? "fg-muted"
        }
    }

    enum Body: Equatable {
        case none
        case request(String)
        case plan(completed: Int, total: Int, step: String?)
        case excerpt(String)
    }

    var agentName: String
    /// nil falls back to the SF Symbol "sparkles".
    var agentLogoAsset: String?
    var title: String
    var status: Status
    var since: Date?
    var body: Body
    var model: String?
    /// 0...100.
    var contextPercent: Int?

    func chipText(now: Date) -> String {
        let age = since.map { WorktreeRowPresentation.compactAge(since: $0, now: now) }
        switch status {
        case .idle:
            guard let age else { return "Idle" }
            return age == "now" ? "Idle · finished now" : "Idle · finished \(age) ago"
        case .running: return Self.chip("Working", age)
        case .awaitingInput, .permission: return Self.chip("Waiting for you", age)
        case .limited: return Self.chip("Usage limit", age)
        case .failed: return Self.chip("Failed", age)
        }
    }

    private static func chip(_ label: String, _ age: String?) -> String {
        age.map { "\(label) · \($0)" } ?? label
    }

    /// The model and context; the agent's name only when there is no model,
    /// since the header's logo already names the agent.
    var footerText: String {
        guard let model, !model.isEmpty else { return agentName }
        guard let contextPercent else { return model }
        return "\(model) · \(contextPercent)% context"
    }

    /// The step in progress, counting from one: "Plan 3 of 5 · Run tests".
    static func planText(completed: Int, total: Int, step: String?) -> String {
        let base = "Plan \(min(completed + 1, total)) of \(total)"
        guard let step, !step.isEmpty else { return base }
        return "\(base) · \(step)"
    }

    var hintText: String {
        switch status {
        case .permission, .awaitingInput: "Click to answer"
        default: "Click to open"
        }
    }

    static func body(
        status: Status,
        permissionTitle: String?,
        plan: AgentSidebarPlanProgress?,
        reply: String?
    ) -> Body {
        if status.showsReply { return reply.map { .excerpt($0) } ?? .none }
        switch status {
        case .permission:
            let title = permissionTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? .none : .request(title)
        case .running:
            guard let plan, plan.total > 0 else { return .none }
            return .plan(completed: plan.completed, total: plan.total, step: plan.currentStep)
        case .awaitingInput, .idle, .failed, .limited:
            return .none
        }
    }

    static func contextPercent(_ usage: ACPUsageInfo?) -> Int? {
        guard let usage, usage.size > 0 else { return nil }
        return Int((contextRatio(used: usage.used, size: usage.size) * 100).rounded())
    }
}

extension AgentBadgePopoverModel {
    /// The card for a session on a peer Mac, from the summary the host sent.
    init(peer session: RemoteSessionSummary) {
        let status: Status = switch session.status {
        case "streaming": .running
        case "awaitingPermission": .permission
        case "awaitingInput": .awaitingInput
        default: .idle
        }
        let detail = session.detail
        let plan: AgentSidebarPlanProgress? = detail.flatMap { detail in
            guard let total = detail.planTotal, total > 0 else { return nil }
            return AgentSidebarPlanProgress(
                completed: detail.planCompleted ?? 0, total: total, currentStep: detail.planStep)
        }
        let agent = AgentKind(rawValue: session.agentId)
        self.init(
            agentName: agent?.displayName ?? session.agentId,
            agentLogoAsset: agent?.logoAssetName,
            title: session.title,
            status: status,
            since: session.updatedAt > 0 ? Date(timeIntervalSince1970: TimeInterval(session.updatedAt)) : nil,
            body: Self.body(
                status: status,
                permissionTitle: detail?.previewKind == .permission ? detail?.preview : nil,
                plan: plan,
                reply: detail?.previewKind == .reply ? detail?.preview : nil),
            model: detail?.model,
            contextPercent: detail?.contextPercent)
    }
}
