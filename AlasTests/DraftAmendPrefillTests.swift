import Testing
@testable import Alas

struct DraftAmendPrefillTests {
    @Test func apply_prefillsWhenDraftIsBlank() {
        let result = DraftAmendPrefill.apply(
            priorSubject: "fix: bug",
            priorBody: "details",
            currentSubject: "",
            currentBody: ""
        )
        #expect(result?.subject == "fix: bug")
        #expect(result?.body == "details")
    }

    @Test func apply_treatsWhitespaceAsBlank() {
        let result = DraftAmendPrefill.apply(
            priorSubject: "fix: bug",
            priorBody: "details",
            currentSubject: "   ",
            currentBody: "\n\n"
        )
        #expect(result?.subject == "fix: bug")
    }

    @Test func apply_returnsNilWhenSubjectHasContent() {
        let result = DraftAmendPrefill.apply(
            priorSubject: "fix: bug",
            priorBody: "",
            currentSubject: "wip: foo",
            currentBody: ""
        )
        #expect(result == nil)
    }

    @Test func apply_returnsNilWhenBodyHasContent() {
        let result = DraftAmendPrefill.apply(
            priorSubject: "fix: bug",
            priorBody: "",
            currentSubject: "",
            currentBody: "user note"
        )
        #expect(result == nil)
    }

    @Test func shouldClear_falseWhenNeverPrefilled() {
        let r = DraftAmendPrefill.shouldClear(
            wasPrefilled: false,
            prefilledSubject: "a",
            prefilledBody: "b",
            currentSubject: "a",
            currentBody: "b"
        )
        #expect(r == false)
    }

    @Test func shouldClear_trueWhenDraftMatchesPrefill() {
        let r = DraftAmendPrefill.shouldClear(
            wasPrefilled: true,
            prefilledSubject: "fix: bug",
            prefilledBody: "details",
            currentSubject: "fix: bug",
            currentBody: "details"
        )
        #expect(r == true)
    }

    @Test func shouldClear_falseWhenSubjectEdited() {
        let r = DraftAmendPrefill.shouldClear(
            wasPrefilled: true,
            prefilledSubject: "fix: bug",
            prefilledBody: "details",
            currentSubject: "fix: bug (revised)",
            currentBody: "details"
        )
        #expect(r == false)
    }

    @Test func shouldClear_falseWhenBodyEdited() {
        let r = DraftAmendPrefill.shouldClear(
            wasPrefilled: true,
            prefilledSubject: "fix: bug",
            prefilledBody: "details",
            currentSubject: "fix: bug",
            currentBody: "details and more"
        )
        #expect(r == false)
    }
}
