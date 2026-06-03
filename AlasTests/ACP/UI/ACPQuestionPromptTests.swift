import Testing
@testable import Alas

@Suite("ACPQuestionPrompt response builder")
struct ACPQuestionPromptTests {
    @Test("builds answered response from complete selections")
    func buildsAnsweredResponse() {
        let params = ACPQuestionRequestParams(
            toolCallId: "call_123",
            title: "Need input",
            questions: [
                .init(
                    id: "q1",
                    prompt: "Pick one",
                    options: [.init(id: "a", label: "A")],
                    allowMultiple: false
                ),
                .init(
                    id: "q2",
                    prompt: "Pick many",
                    options: [.init(id: "b", label: "B"), .init(id: "c", label: "C")],
                    allowMultiple: true
                )
            ]
        )

        let response = ACPQuestionPrompt.answeredResponse(
            for: params,
            selection: ["q1": ["a"], "q2": ["b", "c"]]
        )

        #expect(response == .init(outcome: .answered(answers: [
            .init(questionId: "q1", selectedOptionIds: ["a"]),
            .init(questionId: "q2", selectedOptionIds: ["b", "c"])
        ])))
    }

    @Test("returns nil until every question has a selection")
    func requiresEveryQuestion() {
        let params = ACPQuestionRequestParams(
            toolCallId: "call_123",
            title: nil,
            questions: [
                .init(
                    id: "q1",
                    prompt: "Pick one",
                    options: [.init(id: "a", label: "A")],
                    allowMultiple: false
                )
            ]
        )

        #expect(ACPQuestionPrompt.answeredResponse(for: params, selection: [:]) == nil)
    }
}
