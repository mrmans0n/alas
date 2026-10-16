import Testing
@testable import AlasCore

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
}
