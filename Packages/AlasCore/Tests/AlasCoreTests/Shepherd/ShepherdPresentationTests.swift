import Foundation
import Testing
@testable import AlasCore
@testable import AlasHostCore

private typealias F = ShepherdFixtures

struct ShepherdPresentationCase: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let record: ShepherdRecord?
    let request: ReviewRequest?
    let gate: Bool
    let badge: ShepherdBadgeState
    let number: String?
    let tooltip: String
}

private let fixingUnitTests = F.fingerprint(
    ShepherdFixRequest(hasConflict: false, failingChecks: [F.failing], threads: [])
)

private let presentationCases: [ShepherdPresentationCase] = [
    .init(testDescription: "unbound request shows its number",
          record: nil, request: F.request(), gate: false, badge: .unshepherded, number: "#7", tooltip: "#7 · not shepherded"),
    .init(testDescription: "no request offers Ship with agent",
          record: nil, request: nil, gate: false, badge: .noRequest, number: nil, tooltip: "Ship with agent"),
    .init(testDescription: "checks pending",
          record: F.record(), request: F.request(checks: [F.pending]), gate: false,
          badge: .waiting, number: "#7", tooltip: "#7 · checks running"),
    .init(testDescription: "fixing names the dispatched checks",
          record: F.record(phase: .fixing(dispatchedAt: F.earlier), lastDispatched: fixingUnitTests),
          request: F.request(checks: [F.failing]), gate: false,
          badge: .fixing, number: "#7", tooltip: "#7 · fixing unit-tests"),
    .init(testDescription: "awaiting push",
          record: F.record(phase: .awaitingPush(turnEndedAt: F.earlier, pollsWithoutProgress: 0)),
          request: F.request(checks: [F.failing]), gate: false,
          badge: .waiting, number: "#7", tooltip: "#7 · waiting for a push; automatic follow-up at \(F.earlier.addingTimeInterval(300).formatted(date: .omitted, time: .shortened))"),
    .init(testDescription: "merging",
          record: F.record(phase: .merging), request: F.request(), gate: false,
          badge: .merging, number: "#7", tooltip: "#7 · merging"),
    .init(testDescription: "queued",
          record: F.record(phase: .queued), request: F.request(isInMergeQueue: true), gate: false,
          badge: .queued, number: "#7", tooltip: "#7 · in merge queue"),
    .init(testDescription: "gate passes",
          record: F.record(), request: F.request(), gate: true,
          badge: .ready, number: "#7", tooltip: "#7 · ready to merge"),
    .init(testDescription: "failing with auto-fix off",
          record: F.record(autoFix: false), request: F.request(checks: [F.failing]), gate: false,
          badge: .attention, number: "#7", tooltip: "#7 · auto-fix off: unit-tests"),
    .init(testDescription: "failing with auto-fix on",
          record: F.record(), request: F.request(checks: [F.failing]), gate: false,
          badge: .waiting, number: "#7", tooltip: "#7 · needs a fix: unit-tests"),
    .init(testDescription: "escalated",
          record: F.record(phase: .escalated(.attemptsExhausted)), request: F.request(checks: [F.failing]), gate: false,
          badge: .attention, number: "#7", tooltip: "#7 · needs attention: fix attempts used up"),
    .init(testDescription: "paused",
          record: F.record(phase: .paused), request: nil, gate: false,
          badge: .attention, number: "#7", tooltip: "#7 · paused: provider sign-in failed"),
    .init(testDescription: "merged on GitLab",
          record: F.record(kind: .gitlab, phase: .merged), request: nil, gate: false,
          badge: .merged, number: "!7", tooltip: "!7 · merged"),
    .init(testDescription: "watching while waiting on review",
          record: F.record(), request: F.request(), gate: false,
          badge: .waiting, number: "#7", tooltip: "#7 · watching"),
    .init(testDescription: "closed",
          record: F.record(phase: .closed), request: nil, gate: false,
          badge: .closed, number: "#7", tooltip: "#7 · closed"),
]

@Suite struct ShepherdPresentationTests {
    @Test("automatic delivery recovery shows a wait and the next retry")
    func deliveryRetryPresentation() {
        var record = F.record()
        record.retryDelivery(after: F.now)
        let presentation = ShepherdPresentation.make(record: record, request: F.request(), mergeGatePasses: false)
        #expect(presentation.badge == .waiting)
        #expect(presentation.phaseLine.hasPrefix("retrying chat delivery at "))
    }

    @Test("awaiting a push shows CI while a rerun is active")
    func rerunPresentation() {
        let record = F.record(phase: .awaitingPush(turnEndedAt: F.now, pollsWithoutProgress: 0))
        let presentation = ShepherdPresentation.make(record: record, request: F.request(checks: [F.pending]), mergeGatePasses: false)
        #expect(presentation.badge == .waiting)
        #expect(presentation.phaseLine == "checks running")
    }

    @Test("badge state, number and tooltip follow the record and request", arguments: presentationCases)
    func presentation(_ c: ShepherdPresentationCase) {
        let presentation = ShepherdPresentation.make(record: c.record, request: c.request, mergeGatePasses: c.gate)
        #expect(presentation.badge == c.badge)
        #expect(presentation.number == c.number)
        #expect(presentation.tooltip == c.tooltip)
    }

    @Test(
        "Ship runs the popover's one action for the session",
        arguments: [
            (F.record(), nil, F.request(), false, ShepherdShipAction.shepherding(number: "#7")),
            (nil, F.record(), F.request(), true, .adopt(F.request())),
            (nil, F.record(), nil, false, .unavailable("Waiting for the PR status")),
            (nil, nil, F.request(), false, .adopt(F.request())),
            (nil, nil, F.request(state: .merged), false, .create(.github)),
            (nil, nil, nil, false, .create(.github)),
            (nil, nil, nil, true, .unavailable("Wait for the current turn to finish.")),
        ] as [(ShepherdRecord?, ShepherdRecord?, ReviewRequest?, Bool, ShepherdShipAction)]
    )
    func shipAction(
        record: ShepherdRecord?, otherRecord: ShepherdRecord?, request: ReviewRequest?, isBusy: Bool,
        expected: ShepherdShipAction
    ) {
        let action = ShepherdShipAction.resolve(
            record: record, otherRecord: otherRecord, request: request,
            snapshot: F.snapshot(request), isBusy: isBusy
        )
        #expect(action == expected)
    }

    @Test(
        "the pill stands out only when its action can run now",
        arguments: [
            (F.record(), nil, F.request(), false, false, true, false),
            (nil, F.record(), F.request(), true, false, true, true),
            (nil, F.record(), nil, false, false, true, false),
            (nil, nil, F.request(), true, false, true, true),
            (nil, nil, F.request(state: .merged), true, false, true, false),
            (nil, nil, nil, false, false, false, true),
            (nil, nil, nil, false, false, true, true),
            (nil, nil, nil, false, true, true, false),
        ] as [(ShepherdRecord?, ShepherdRecord?, ReviewRequest?, Bool, Bool, Bool, Bool)]
    )
    func invitesShip(
        record: ShepherdRecord?, otherRecord: ShepherdRecord?, request: ReviewRequest?, isBusy: Bool,
        cliMissing: Bool, snapshotKnown: Bool, expected: Bool
    ) {
        var snapshot = F.snapshot(request)
        if cliMissing {
            snapshot = ReviewLoopSnapshot(
                local: snapshot.local, remote: snapshot.remote, reviewRequest: request,
                providerAvailable: false, providerAuthenticated: false,
                providerCapabilities: .githubCLI, errorMessage: nil
            )
        }
        let invites = ShepherdShipAction.invitesShip(
            record: record, otherRecord: otherRecord, request: request,
            snapshot: snapshotKnown ? snapshot : nil, isBusy: isBusy
        )
        #expect(invites == expected)
    }

    @Test(
        "an agent's closing offer to ship is recognized",
        arguments: [
            ("Done.\n\nWant me to open a PR?", true),
            ("Tests pass. Want me to open a PR with these changes, or keep iterating on the edge cases?", true),
            ("Should I commit this and push the branch?", true),
            ("Shall I create a draft pull request for review?", true),
            ("**Ready to raise the MR?**", true),
            ("Let me know if you want me to open a PR.", true),
            ("Want me to ship it?", true),
            ("Want me to open a PR?\n\nFor context, the fix touches two files.", false),
            ("Want me to open a PR? I can also add more tests first.", false),
            ("I opened a PR. Want me to add tests too?", false),
            ("Did you already open a PR for this?", false),
            ("Can you open a PR when you're ready?", false),
            ("Could you commit and push from your machine?", false),
            ("Should I not open a PR yet?", false),
            ("Would you rather I don't create a PR?", false),
            ("Is there already an open PR?", false),
            ("Should I check whether there's an open PR first?", false),
            ("Want me to check if I can open a PR?", false),
            ("Want me to show you how to open a PR?", false),
            ("I can help you open a PR?", false),
            ("I can open a PR after we add tests; should I add them first?", false),
            ("All green: want me to open a PR?", true),
            ("Want me to open the existing PR in your browser?", false),
            ("Want me to send you the PR link?", false),
            ("Should I file a comment on the PR?", false),
            ("Want me to create a PR template?", false),
            ("Should I commit or push?", false),
            ("Should I commit these changes and push back on the reviewer?", false),
            ("Want me to commit to this approach and push for broader adoption?", false),
            ("Want me to commit the fix and push the branch to origin?", true),
            ("Want me to go ahead and commit these changes and open a pull request?", true),
            ("Want me to commit these changes?", false),
            ("Should I update the PR description?", false),
            ("I'll open a PR once the tests pass.", false),
        ]
    )
    func shipOffer(text: String, expected: Bool) {
        #expect(ShepherdShipOffer.isOffered(in: text) == expected)
    }

    @Test(
        "only events that end a request's shepherding get a transcript card",
        arguments: [
            (ReviewShepherd.Event.merged(F.record(phase: .merged), title: "Fix login"), ACPPromptCard.Origin.merged),
            (.closed(F.record(phase: .closed), title: "Fix login"), .closed),
            (.queued(F.record(phase: .queued), title: "Fix login"), .queued),
            (.ready(F.record(), title: "Fix login"), nil),
            (.escalated(F.record(phase: .escalated(.noProgress)), .noProgress, title: "Fix login"), nil),
        ] as [(ReviewShepherd.Event, ACPPromptCard.Origin?)]
    )
    func outcomeCard(event: ReviewShepherd.Event, origin: ACPPromptCard.Origin?) throws {
        guard let origin else {
            #expect(ShepherdNotification.outcomeCard(for: event) == nil)
            return
        }
        let outcome = try #require(ShepherdNotification.outcomeCard(for: event))
        #expect(outcome.card.origin == origin)
        #expect(outcome.card.title == "GitHub #7 · Fix login")
        #expect(outcome.card.facts.map(\.text) == ["fix-login → main"])
        #expect(outcome.card.action == .url(URL(string: "https://github.com/acme/app/pull/7")!))
        #expect(outcome.text == ShepherdNotification.review(for: event, host: { _ in nil }).body)
    }
}
