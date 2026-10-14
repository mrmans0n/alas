import Foundation
import Testing
@testable import AlasCore

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
    .init(testDescription: "no request offers Create PR",
          record: nil, request: nil, gate: false, badge: .noRequest, number: nil, tooltip: "Not shepherded"),
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
          badge: .waiting, number: "#7", tooltip: "#7 · waiting for a push"),
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
    @Test("badge state, number and tooltip follow the record and request", arguments: presentationCases)
    func presentation(_ c: ShepherdPresentationCase) {
        let presentation = ShepherdPresentation.make(record: c.record, request: c.request, mergeGatePasses: c.gate)
        #expect(presentation.badge == c.badge)
        #expect(presentation.number == c.number)
        #expect(presentation.tooltip == c.tooltip)
    }
}
