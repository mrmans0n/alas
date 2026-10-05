import Foundation
import Testing
@testable import Alas

struct IssueKindRulesTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let provider: IssueProviderID
        let nativeType: String?
        let labels: [String]
        let expected: IssueKindDecision?
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        .init(name: "GitHub issue type wins over labels", provider: .github, nativeType: "Bug",
              labels: ["enhancement"], expected: .init(kind: .bug, reason: "from GitHub issue type Bug")),
        .init(name: "GitHub Feature type", provider: .github, nativeType: "Feature",
              labels: [], expected: .init(kind: .enhancement, reason: "from GitHub issue type Feature")),
        .init(name: "GitHub Task type defers to labels", provider: .github, nativeType: "Task",
              labels: ["bug"], expected: .init(kind: .bug, reason: "from label `bug`")),
        .init(name: "GitLab incident is a bug", provider: .gitlab, nativeType: "incident",
              labels: [], expected: .init(kind: .bug, reason: "from GitLab incident")),
        .init(name: "GitLab test case is a chore", provider: .gitlab, nativeType: "test_case",
              labels: [], expected: .init(kind: .chore, reason: "from GitLab test case")),
        .init(name: "GitLab plain issue type defers to scoped label", provider: .gitlab, nativeType: "issue",
              labels: ["type::feature"], expected: .init(kind: .enhancement, reason: "from label `type::feature`")),
        .init(name: "scope that is itself a kind", provider: .gitlab, nativeType: nil,
              labels: ["bug::vulnerability"], expected: .init(kind: .bug, reason: "from label `bug::vulnerability`")),
        .init(name: "non-type scopes do not classify", provider: .gitlab, nativeType: nil,
              labels: ["priority::1", "workflow::in dev"], expected: nil),
        .init(name: "kind/ prefix", provider: .github, nativeType: nil,
              labels: ["kind/docs"], expected: .init(kind: .docs, reason: "from label `kind/docs`")),
        .init(name: "hyphen and case normalization", provider: .github, nativeType: nil,
              labels: ["Feature-Request"], expected: .init(kind: .enhancement, reason: "from label `Feature-Request`")),
        .init(name: "underscore normalization", provider: .github, nativeType: nil,
              labels: ["tech_debt"], expected: .init(kind: .chore, reason: "from label `tech_debt`")),
        .init(name: "unrelated labels are ignored", provider: .github, nativeType: nil,
              labels: ["help wanted", "spike"], expected: .init(kind: .research, reason: "from label `spike`")),
        .init(name: "same kind twice still decides", provider: .github, nativeType: nil,
              labels: ["bug", "regression"], expected: .init(kind: .bug, reason: "from label `bug`")),
        .init(name: "conflicting labels do not decide", provider: .github, nativeType: nil,
              labels: ["bug", "enhancement"], expected: nil),
        .init(name: "manual source without labels", provider: .manual, nativeType: nil,
              labels: [], expected: nil),
    ]

    @Test(arguments: cases)
    func classifies(_ testCase: Case) {
        #expect(IssueKindRules.classify(Self.source(testCase)) == testCase.expected)
    }

    static func source(_ testCase: Case) -> IssueSnapshot {
        IssueSnapshot(
            identity: .init(providerID: testCase.provider, stableID: "issue-1"),
            canonicalURL: URL(string: "https://example.com/issues/1")!,
            providerLabel: "Test",
            displayReference: "#1",
            repositoryLocator: nil,
            title: "Title",
            body: "Body",
            state: .open,
            labels: testCase.labels,
            assignees: [],
            providerUpdatedAt: nil,
            capturedAt: .distantPast,
            refreshError: nil,
            contentOrigin: testCase.provider == .manual ? .manual : .provider,
            isEditable: testCase.provider == .manual,
            isRefreshable: testCase.provider != .manual,
            nativeType: testCase.nativeType
        )
    }
}

struct IssueKindPolicyTests {
    @Test(arguments: [
        (#"{"kind": "bug"}"#, IssueKindPolicy.Answer.kind(.bug)),
        (#" {"kind":"Research"} "#, .kind(.research)),
        (#"{"kind": "chore"}"#, .kind(.chore)),
        (#"{"kind": "unknown"}"#, .unknown),
    ])
    func acceptsExactlyOneKind(output: String, expected: IssueKindPolicy.Answer) {
        #expect(IssueKindPolicy.parse(output) == expected)
    }

    @Test(arguments: [
        "bug",
        #"{"kind": "feature"}"#,
        #"{"kind": "bug", "why": "crash"}"#,
        #"{"kind": null}"#,
        #"{"type": "bug"}"#,
        #"```json {"kind": "bug"} ```"#,
        "",
    ])
    func rejectsAnythingElse(output: String) {
        #expect(IssueKindPolicy.parse(output) == nil)
    }
}
