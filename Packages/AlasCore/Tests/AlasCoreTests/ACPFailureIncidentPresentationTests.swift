import Foundation
import Testing
import AlasCore

struct ACPFailureIncidentPresentationTests {
    private static let permissive = ACPFailureActionContext(
        isRetryTarget: true, agentReady: true, promptActive: false, holdsWriteLease: true,
        isMirror: false, hasUncertainDelivery: false, isPeer: false)

    private static func incident(
        category: String = "service", severity: String = "error", details: String? = nil, kind: String? = nil,
        actions: [String] = []
    ) throws -> ACPFailureIncident {
        var record: [String: Any] = [
            "version": 1, "id": "t:error", "revision": 1, "category": category, "severity": severity,
            "title": "Model overloaded", "actions": actions,
        ]
        record["details"] = details
        record["kind"] = kind
        let data = try JSONSerialization.data(withJSONObject: record)
        return ACPFailureIncident(record: try JSONDecoder().decode(ACPSessionFailureRecord.self, from: data))
    }

    @Test func visibleActionsFiltersRawValues() {
        let actions = ACPFailureActionPolicy.visibleActions(
            rawActions: ["new_session", "future", "retry", "retry", "login"], context: Self.permissive)
        #expect(actions == [.newSession, .retry, .login])
    }

    enum RetryCondition: CaseIterable {
        case isRetryTarget, agentReady, promptActive, holdsWriteLease, isMirror, hasUncertainDelivery, isPeer
    }

    @Test(arguments: RetryCondition.allCases)
    func retryRequiresEveryCondition(_ flipped: RetryCondition) {
        var context = Self.permissive
        switch flipped {
        case .isRetryTarget: context.isRetryTarget = false
        case .agentReady: context.agentReady = false
        case .promptActive: context.promptActive = true
        case .holdsWriteLease: context.holdsWriteLease = false
        case .isMirror: context.isMirror = true
        case .hasUncertainDelivery: context.hasUncertainDelivery = true
        case .isPeer: context.isPeer = true
        }
        #expect(!ACPFailureActionPolicy.visibleActions(rawActions: ["retry"], context: context).contains(.retry))
    }

    /// Signing in stands the runner down, which would end the work still running.
    @Test(arguments: [false, true])
    func signInHiddenWhileWorkRuns(background: Bool) {
        var context = Self.permissive
        if background { context.hasBackgroundWork = true } else { context.promptActive = true }
        let actions = ACPFailureActionPolicy.visibleActions(rawActions: ["login", "new_session"], context: context)
        #expect(actions == [.newSession])
    }

    @Test func actionsNeverInferredFromCategory() throws {
        for incident in [try Self.incident(category: "service"), try Self.incident(kind: "rate_limited")] {
            let presentation = ACPFailureIncidentPresentation.make(incident, context: Self.permissive, isActiveRetry: false)
            #expect(presentation.actions.isEmpty)
        }
    }

    @Test(arguments: [true, false])
    func readOnlySurfacesShowNoActions(mirror: Bool) {
        var context = Self.permissive
        if mirror { context.isMirror = true } else { context.isPeer = true }
        let actions = ACPFailureActionPolicy.visibleActions(rawActions: ["retry", "login", "new_session"], context: context)
        #expect(actions.isEmpty)
    }

    @Test(arguments: [
        ("connection", "Connection"), ("access", "Access"), ("limit", "Limit"), ("request", "Request"),
        ("service", "Service"), ("unknown", "Other"), ("future", "Other"),
    ])
    func categoryLabels(raw: String, label: String) throws {
        let presentation = ACPFailureIncidentPresentation.make(
            try Self.incident(category: raw), context: Self.permissive, isActiveRetry: false)
        #expect(presentation.categoryLabel == label)
    }

    @Test(arguments: [
        ("error", false, ACPFailureIncidentPresentation.Tone.error, "Error"),
        ("error", true, .error, "Error"),
        ("warning", true, .warningActive, "Warning"),
        ("warning", false, .muted, "Warning"),
    ])
    func presentationTone(
        severity: String, isActiveRetry: Bool, tone: ACPFailureIncidentPresentation.Tone, label: String
    ) throws {
        let presentation = ACPFailureIncidentPresentation.make(
            try Self.incident(severity: severity), context: Self.permissive, isActiveRetry: isActiveRetry)
        #expect(presentation.tone == tone)
        #expect(presentation.severityLabel == label)
    }

    @Test(arguments: [("Try again", "Try again"), (" \n ", nil)] as [(String, String?)])
    func presentationDetails(raw: String, details: String?) throws {
        let presentation = ACPFailureIncidentPresentation.make(
            try Self.incident(details: raw), context: Self.permissive, isActiveRetry: false)
        #expect(presentation.title == "Model overloaded")
        #expect(presentation.details == details)
    }
}
