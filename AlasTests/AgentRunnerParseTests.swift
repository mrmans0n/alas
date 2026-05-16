import Testing
import Foundation
@testable import Alas

struct AgentRunnerParseTests {
    @Test func splitsSubjectAndBodyOnBlankLine() {
        let m = AgentMessageParser.parse("""
        subject line

        body paragraph one.

        body paragraph two.
        """)
        #expect(m.subject == "subject line")
        #expect(m.body.contains("body paragraph one"))
        #expect(m.body.contains("body paragraph two"))
    }

    @Test func singleLineBecomesSubjectOnlyEmptyBody() {
        let m = AgentMessageParser.parse("single line message")
        #expect(m.subject == "single line message")
        #expect(m.body.isEmpty)
    }

    @Test func trimsLeadingAndTrailingWhitespace() {
        let m = AgentMessageParser.parse("\n\n  hello  \n\n  body  \n\n")
        #expect(m.subject == "hello")
        #expect(m.body == "body")
    }
}
