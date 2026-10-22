import AlasCore
import SwiftUI

/// The approval card for one pending (session, app). Reuses the permission
/// card's look by mapping the four choices onto its option kinds.
struct ComputerUseApprovalCard: View {
    let agentName: String
    let app: ComputerUseAppIdentity
    let onAnswer: (ComputerUseApprovalChoice) -> Void

    static func options(for app: ComputerUseAppIdentity) -> [(option: ACPPermissionCardContent.Option, choice: ComputerUseApprovalChoice)] {
        func entry(_ id: String, _ name: String, _ kind: String, _ choice: ComputerUseApprovalChoice)
            -> (option: ACPPermissionCardContent.Option, choice: ComputerUseApprovalChoice) {
            (.init(optionId: id, name: name, kind: kind, description: nil), choice)
        }
        var result = [
            entry("turn", "Allow for this turn", "allow_once", .allowForTurn),
            entry("session", "Allow for this session", "allow_session", .allowForSession),
        ]
        if let bundleID = app.bundleID, !bundleID.isEmpty {
            result.append(entry("always", "Always allow", "allow_always", .alwaysAllow))
        }
        result.append(entry("deny", "Deny", "reject_once", .deny))
        return result
    }

    var body: some View {
        let options = Self.options(for: app)
        ACPPermissionCard(
            content: ACPPermissionCardContent(
                heading: "Computer use",
                title: "Allow \(agentName) to use \(app.name)?",
                reason: "It can see \(app.name)'s windows and read its controls.",
                options: options.map(\.option)
            )
        ) { chosen in
            if let match = options.first(where: { $0.option.optionId == chosen.optionId }) {
                onAnswer(match.choice)
            }
        }
    }
}
