import AlasRemoteKit
import Testing

struct RemotePushAlertTests {
    typealias Message = RemoteServerMessageOf<OpaqueHostMessage, OpaqueHostMessage>

    private static let permission = RemotePermissionPayload(requestId: 1, toolName: "Bash", options: [], title: "git push")
    private static let visual = RemotePermissionPayload(requestId: 2, toolName: RemotePushAlert.visualAidToolName, options: [])
    private static let question = RemoteQuestionPayload(requestId: 3, title: nil, questions: [
        RemoteQuestion(id: "q", prompt: "Which branch?", options: [], allowMultiple: false),
    ])
    private static let plan = RemotePlanPayload(
        requestId: .number(4), toolCallId: "t", name: "Plan", overview: "", plan: "", todos: [], isProject: false, phases: [])
    private static let elicitation = RemoteElicitationPayload(
        requestId: "e", title: nil, message: "Paste the token", mode: "form", fields: [], elicitationId: nil, url: nil)

    @Test(arguments: [
        (Message.permissionRequest(sessionId: "s", payload: permission), "Wants to run git push", true),
        (.permissionRequest(sessionId: "s", payload: visual), "Has a visual for you", false),
        (.questionRequest(sessionId: "s", payload: question), "Which branch?", false),
        (.planRequest(sessionId: "s", payload: plan), "Plan ready for review", false),
        (.elicitationRequest(sessionId: "s", payload: elicitation), "Paste the token", false),
    ] as [(Message, String, Bool)])
    func wording(message: Message, body: String, isPermission: Bool) throws {
        let content = try #require(RemotePushAlert.content(for: message, sessionTitle: "Fix login"))
        #expect(content.title == "Fix login")
        #expect(content.body == body)
        #expect(content.isPermission == isPermission)
    }

    @Test func nonRequestsHaveNoAlertAndUntitledSessionsAreAlas() throws {
        #expect(RemotePushAlert.content(for: Message.stopPending(sessionId: "s"), sessionTitle: nil) == nil)
        let content = try #require(RemotePushAlert.content(
            for: Message.planRequest(sessionId: "s", payload: Self.plan), sessionTitle: nil))
        #expect(content.title == "Alas")
    }

    @Test func longBodiesTruncateAtTheNotificationLimit() throws {
        let long = RemoteElicitationPayload(
            requestId: "e", title: nil, message: String(repeating: "a", count: 300), mode: "form", fields: [],
            elicitationId: nil, url: nil)
        let content = try #require(RemotePushAlert.content(
            for: Message.elicitationRequest(sessionId: "s", payload: long), sessionTitle: nil))
        #expect(content.body == String(repeating: "a", count: 177) + "…")
    }
}

struct RemoteRequestIdentityTests {
    @Test(arguments: [
        (RemotePermissionPayload(requestId: 9, toolName: "Bash", options: [], title: "git push", toolCallId: "t1"), true),
        (RemotePermissionPayload(requestId: 1, toolName: "Bash", options: [], title: "git push --force", toolCallId: "t1"), false),
        (RemotePermissionPayload(requestId: 1, toolName: "Bash", options: [], title: "git push", toolCallId: "t2"), false),
    ] as [(RemotePermissionPayload, Bool)])
    func ignoresTheWireIdOnly(other: RemotePermissionPayload, same: Bool) {
        let shown = RemotePermissionPayload(requestId: 1, toolName: "Bash", options: [], title: "git push", toolCallId: "t1")
        #expect((RemoteRequestIdentity.of(shown) == RemoteRequestIdentity.of(other)) == same)
    }
}

struct RemotePermissionQuickAnswerTests {
    private static func options(_ kinds: [String]) -> [RemotePermissionOption] {
        kinds.map { RemotePermissionOption(optionId: "id-\($0)", name: $0, kind: $0) }
    }

    @Test(arguments: [
        (["allow_always", "allow_once", "reject_once"], true, "id-allow_once"),
        (["reject_once", "allow_always"], true, "id-allow_always"),
        (["reject_always", "reject_once", "allow_once"], false, "id-reject_once"),
        (["allow_once", "reject_always"], false, "id-reject_always"),
        (["allow_once"], false, nil),
        ([], true, nil),
    ] as [([String], Bool, String?)])
    func picksOnceThenPersistentAndNeverGuesses(kinds: [String], allow: Bool, expected: String?) {
        let payload = RemotePermissionPayload(requestId: 1, toolName: "Bash", options: Self.options(kinds))
        #expect(RemotePermissionQuickAnswer.optionId(in: payload, allow: allow) == expected)
    }
}

struct RemoteQuestionQuickAnswerTests {
    /// (questions, options per question, allowMultiple) → offers buttons.
    @Test(arguments: [
        (1, 2, false, true),
        (1, 4, false, true),
        (1, 5, false, false),
        (1, 0, false, false),
        (1, 2, true, false),
        (2, 2, false, false),
    ] as [(Int, Int, Bool, Bool)])
    func offersButtonsOnlyForOneSingleChoiceThatFits(questions: Int, options: Int, multiple: Bool, offered: Bool) {
        let payload = RemoteQuestionPayload(requestId: 1, title: nil, questions: (0 ..< questions).map { q in
            RemoteQuestion(id: "q\(q)", prompt: "?", options: (0 ..< options).map { RemoteQuestionOption(id: "o\($0)", label: "O\($0)") },
                           allowMultiple: multiple)
        })
        #expect((RemoteQuestionQuickAnswer.options(in: payload) != nil) == offered)
    }
}
