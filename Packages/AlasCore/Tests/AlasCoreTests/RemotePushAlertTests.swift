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
