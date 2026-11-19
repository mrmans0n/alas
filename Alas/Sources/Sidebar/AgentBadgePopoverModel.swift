import AlasACP
import Foundation

/// What the hover popover on a sidebar agent badge shows, decided apart from
/// the view so the copy and the per-status body can be tested.
struct AgentBadgePopoverModel: Equatable {
    enum Status: Equatable { case running, awaitingInput, permission, limited, failed, idle }

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

    var footerText: String {
        var parts = [agentName]
        if let model, !model.isEmpty { parts.append(model) }
        if let contextPercent { parts.append("\(contextPercent)% context") }
        return parts.joined(separator: " · ")
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
        switch status {
        case .permission:
            let title = permissionTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? .none : .request(title)
        case .running:
            guard let plan, plan.total > 0 else { return .none }
            return .plan(completed: plan.completed, total: plan.total, step: plan.currentStep)
        case .awaitingInput, .idle, .failed, .limited:
            return reply.map { .excerpt($0) } ?? .none
        }
    }

    static func contextPercent(_ usage: ACPUsageInfo?) -> Int? {
        guard let usage, usage.size > 0 else { return nil }
        return Int((contextRatio(used: usage.used, size: usage.size) * 100).rounded())
    }
}
