import AlasACP
import Foundation
import Testing
@testable import Alas

struct AgentBadgePopoverModelTests {
    typealias Model = AgentBadgePopoverModel

    private func model(
        _ status: Model.Status, since: Date? = nil, name: String = "Claude",
        modelName: String? = nil, context: Int? = nil
    ) -> Model {
        Model(agentName: name, agentLogoAsset: nil, title: "t", status: status, since: since,
              body: .none, model: modelName, contextPercent: context)
    }

    struct BodyCase: Sendable {
        let status: Model.Status
        let title: String?
        let plan: AgentSidebarPlanProgress?
        let reply: String?
        let expected: Model.Body
    }

    static let bodyCases: [BodyCase] = [
        .init(status: .permission, title: "Run rm", plan: nil, reply: nil, expected: .request("Run rm")),
        .init(status: .permission, title: "  ", plan: nil, reply: nil, expected: .none),
        .init(status: .running, title: nil, plan: .init(completed: 2, total: 5, currentStep: "Run tests"), reply: nil,
              expected: .plan(completed: 2, total: 5, step: "Run tests")),
        .init(status: .running, title: nil, plan: nil, reply: "x", expected: .none),
        .init(status: .running, title: nil, plan: .init(completed: 0, total: 0, currentStep: nil), reply: nil, expected: .none),
        .init(status: .idle, title: nil, plan: nil, reply: "Done.", expected: .excerpt("Done.")),
        .init(status: .awaitingInput, title: nil, plan: nil, reply: "Which one?", expected: .excerpt("Which one?")),
        .init(status: .failed, title: nil, plan: nil, reply: nil, expected: .none),
    ]

    @Test("body follows the status", arguments: bodyCases)
    func bodyFollowsStatus(_ c: BodyCase) {
        #expect(Model.body(status: c.status, permissionTitle: c.title, plan: c.plan, reply: c.reply) == c.expected)
    }

    @Test("chip text pairs the state with its age", arguments: [
        (Model.Status.running, "Working · 2m"),
        (.permission, "Waiting for you · 2m"),
        (.awaitingInput, "Waiting for you · 2m"),
        (.limited, "Usage limit · 2m"),
        (.failed, "Failed · 2m"),
        (.idle, "Idle · finished 2m ago"),
    ])
    func chipTextWithAge(_ status: Model.Status, _ expected: String) {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(model(status, since: now - 120).chipText(now: now) == expected)
    }

    @Test("chip text drops the age when unknown or under a minute")
    func chipTextEdges() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(model(.running).chipText(now: now) == "Working")
        #expect(model(.idle).chipText(now: now) == "Idle")
        #expect(model(.running, since: now - 5).chipText(now: now) == "Working · now")
        #expect(model(.idle, since: now - 5).chipText(now: now) == "Idle · finished now")
    }

    @Test("footer drops missing parts")
    func footer() {
        #expect(model(.idle, modelName: "Opus 5.5", context: 63).footerText == "Claude · Opus 5.5 · 63% context")
        #expect(model(.idle).footerText == "Claude")
    }

    @Test("hint asks to answer only for waiting states", arguments: [
        (Model.Status.permission, "Click to answer"), (.awaitingInput, "Click to answer"),
        (.running, "Click to open"), (.idle, "Click to open"), (.failed, "Click to open"), (.limited, "Click to open"),
    ])
    func hint(_ status: Model.Status, _ expected: String) {
        #expect(model(status).hintText == expected)
    }

    @Test("context percent rounds the ratio and needs a window size")
    func contextPercent() {
        #expect(Model.contextPercent(ACPUsageInfo(used: 63, size: 100, cost: nil)) == 63)
        #expect(Model.contextPercent(ACPUsageInfo(used: 63, size: 0, cost: nil)) == nil)
        #expect(Model.contextPercent(nil) == nil)
    }
}
