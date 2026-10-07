import Foundation
import Testing
@testable import Alas

/// File scope so `@Test(arguments:)` can use it.
private let questionOptions: [ACPVisualAid.Option] = [
    .init(id: "a", label: "One"), .init(id: "b", label: "Two"), .init(id: "c", label: "Three"),
]

struct ACPVisualAidTests {
    private static func visual(allowMultiple: Bool = false) -> ACPVisualAid {
        ACPVisualAid(
            id: UUID(), title: "Homepage layout", html: "<h2>Pick</h2>",
            question: .init(prompt: "Which layout feels right?", options: questionOptions, allowMultiple: allowMultiple),
            answer: nil, createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test("limits match the visual_show contract", arguments: [
        ("T", "<p>", [ACPVisualAid.Option]?.some(questionOptions), true),
        ("", "<p>", nil, false),
        (String(repeating: "x", count: 121), "<p>", nil, false),
        ("T", " \n ", nil, false),
        ("T", String(repeating: "x", count: 512 * 1024 + 1), nil, false),
        ("T", "<p>", [.init(id: "a", label: "One")], false),
        ("T", "<p>", [.init(id: "a", label: "One"), .init(id: "a", label: "Two")], false),
        ("T", "<p>", [.init(id: "a b", label: "One"), .init(id: "b", label: "Two")], false),
        ("T", "<p>", [.init(id: "a", label: ""), .init(id: "b", label: "Two")], false),
    ] as [(String, String, [ACPVisualAid.Option]?, Bool)])
    func validation(title: String, html: String, options: [ACPVisualAid.Option]?, valid: Bool) {
        let question = options.map { ACPVisualAid.Question(prompt: "Q", options: $0, allowMultiple: false) }
        #expect((ACPVisualAid.validationFailure(title: title, html: html, question: question) == nil) == valid)
    }

    @Test("a page click selects only an exact option id", arguments: [
        ("b", true), ("B", false), (" b", false), ("z", false),
    ])
    func choiceField(choice: String, matches: Bool) throws {
        let request = try #require(ACPVisualAidQuestionForm.request(for: Self.visual()))
        let field = ACPVisualAidQuestionForm.choiceField(for: choice, in: request)
        #expect((field?.key == ACPVisualAidQuestionForm.choiceKey) == matches)
    }

    @Test("a multi-select answer keeps the question's option order")
    func multiSelectAnswerOrder() throws {
        let visual = Self.visual(allowMultiple: true)
        let question = try #require(visual.question)
        let answer = try #require(ACPVisualAidQuestionForm.answer(
            from: [ACPVisualAidQuestionForm.choiceKey: .strings(["c", "a"]), ACPVisualAidQuestionForm.noteKey: .string("  ")],
            question: question,
            at: Date(timeIntervalSince1970: 1)
        ))
        #expect(answer == .answered(selectedOptionIds: ["a", "c"], note: nil, at: Date(timeIntervalSince1970: 1)))
        #expect(ACPVisualAidQuestionForm.answerPrompt(for: visual, answer: answer)
            == "[Visual aid: Homepage layout] Which layout feels right?\nSelected: a (One), c (Three)")
    }

    @Test("the answer prompt carries a non-empty note and dismissal sends nothing")
    func answerPrompt() {
        let visual = Self.visual()
        let answered = ACPVisualAid.Answer.answered(selectedOptionIds: ["b"], note: "Keep the sidebar collapsible.", at: Date())
        #expect(ACPVisualAidQuestionForm.answerPrompt(for: visual, answer: answered)
            == "[Visual aid: Homepage layout] Which layout feels right?\nSelected: b (Two)\nNote: Keep the sidebar collapsible.")
        #expect(ACPVisualAidQuestionForm.answerPrompt(for: visual, answer: .dismissed(at: Date())) == nil)
    }
}
