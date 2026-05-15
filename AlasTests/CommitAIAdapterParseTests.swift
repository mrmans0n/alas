import Testing
import Foundation
@testable import Alas

struct CommitAIAdapterParseTests {
    @Test func parsesSubjectAndBody() {
        let m = CommitAIAdapterParser.parse("""
        feat: short subject

        body line 1
        body line 2
        """)
        #expect(m.subject == "feat: short subject")
        #expect(m.body == "body line 1\nbody line 2")
    }

    @Test func noBlankLineCollapsesToSubject() {
        let m = CommitAIAdapterParser.parse("single line message")
        #expect(m.subject == "single line message")
        #expect(m.body == "")
    }

    @Test func trimsLeadingTrailingWhitespace() {
        let m = CommitAIAdapterParser.parse("\n\n  hello  \n\n  body  \n\n")
        #expect(m.subject == "hello")
        #expect(m.body == "body")
    }

    @Test func emptyInput() {
        let m = CommitAIAdapterParser.parse("")
        #expect(m.subject == "")
        #expect(m.body == "")
    }

    @Test func preservesMultiParagraphBody() {
        let m = CommitAIAdapterParser.parse("""
        subject

        para 1

        para 2
        """)
        #expect(m.subject == "subject")
        #expect(m.body == "para 1\n\npara 2")
    }
}
