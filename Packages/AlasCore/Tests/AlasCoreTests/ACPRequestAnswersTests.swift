import Testing
@testable import AlasCore
@testable import AlasHostCore

struct ACPRequestAnswersTests {
    /// Every question needs a selection of its own options, and a question
    /// that allows one takes only one, whatever a client sends.
    @Test(arguments: [
        (["a"], false, true),
        (["a", "b"], false, false),
        (["a", "b"], true, true),
        (["z"], true, false),
        (["a", "z"], true, false),
        (["a", "a"], false, false),
        ([], true, false),
    ])
    func questionAnswersFitTheirQuestion(_ selected: [String], _ allowMultiple: Bool, _ accepted: Bool) {
        let pending = ACPSession.PendingQuestion(id: .number(1), params: ACPQuestionRequestParams(
            toolCallId: "call", title: nil,
            questions: [ACPQuestion(
                id: "q", prompt: "Which?",
                options: [ACPQuestionOption(id: "a", label: "A"), ACPQuestionOption(id: "b", label: "B")],
                allowMultiple: allowMultiple
            )]
        ))
        let response = ACPRequestAnswers.question(pending, answers: [ACPQuestionAnswer(questionId: "q", selectedOptionIds: selected)])
        #expect((response != nil) == accepted)
    }

    /// An answer covers exactly the questions asked: none missing, none extra,
    /// none twice.
    @Test(arguments: [
        (["q"], true),
        (["q", "extra"], false),
        (["q", "q"], false),
        ([], false),
    ])
    func answersCoverExactlyTheQuestionsAsked(_ questionIDs: [String], _ accepted: Bool) {
        let pending = ACPSession.PendingQuestion(id: .number(1), params: ACPQuestionRequestParams(
            toolCallId: "call", title: nil,
            questions: [ACPQuestion(id: "q", prompt: "Which?", options: [ACPQuestionOption(id: "a", label: "A")], allowMultiple: false)]
        ))
        let answers = questionIDs.map { ACPQuestionAnswer(questionId: $0, selectedOptionIds: ["a"]) }
        #expect((ACPRequestAnswers.question(pending, answers: answers) != nil) == accepted)
    }

    /// Plan reviews are never remembered: Claude's "Yes, and auto-accept" options
    /// are `allow_always`, and one click must not approve every later plan.
    @Test(arguments: [ACPRequestAnswers.PermissionScope.optionDefault, .session, .project])
    func planReviewAnswerIsOneShot(_ scope: ACPRequestAnswers.PermissionScope) {
        func pending(toolCallId: String, kind: String?) -> ACPSession.PendingPermission {
            ACPSession.PendingPermission(id: .number(1), params: ACPPermissionRequestParams(
                sessionId: "s",
                toolCall: .init(toolCallId: toolCallId, title: "Approve Plan", kind: kind),
                options: [.init(optionId: "keep", name: "Yes, keep context", kind: "allow_always")]
            ))
        }
        let review = ACPRequestAnswers.permission(pending(toolCallId: "toolu_1", kind: "switch_mode"), optionId: "keep", scope: scope)
        #expect(review?.persistScope == nil)
        let codex = ACPRequestAnswers.permission(pending(toolCallId: "plan-review:item_1", kind: nil), optionId: "keep", scope: scope)
        #expect(codex?.persistScope == nil)
        let ordinary = ACPRequestAnswers.permission(pending(toolCallId: "toolu_2", kind: "execute"), optionId: "keep", scope: scope)
        #expect(ordinary?.persistScope == (scope == .session ? .session : .project))
    }
}
