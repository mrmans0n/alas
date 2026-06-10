import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPTranscriptMarkdown")
struct ACPTranscriptMarkdownTests {
    @Test("document renders user + agent only, in order, with role headings")
    func documentRendersConversation() {
        let messages: [ACPMessage] = [
            .user(id: UUID(), text: "hi", attachments: []),
            .thought(id: UUID(), StreamingText("secret reasoning")),
            .agent(id: UUID(), StreamingText("hello")),
            .toolCall(.init(toolCallId: "t1", title: "Read", status: "completed")),
            .plan(id: UUID(), []),
            .systemNotice(id: UUID(), text: "noticed"),
        ]
        let md = ACPTranscriptMarkdown.document(
            title: "Chat", agentName: "Claude Code", messages: messages)
        #expect(md == "# Chat\n\n## You\n\nhi\n\n## Claude Code\n\nhello\n")
    }

    @Test("document falls back to default title and agent heading")
    func documentFallbacks() {
        let messages: [ACPMessage] = [.agent(id: UUID(), StreamingText("yo"))]
        #expect(
            ACPTranscriptMarkdown.document(title: "New session", agentName: nil, messages: messages)
            == "# ACP session\n\n## Agent\n\nyo\n")
        #expect(
            ACPTranscriptMarkdown.document(title: "   ", agentName: "  ", messages: messages)
            == "# ACP session\n\n## Agent\n\nyo\n")
    }

    @Test("empty conversation renders just the title line")
    func documentEmpty() {
        #expect(
            ACPTranscriptMarkdown.document(title: "", agentName: nil, messages: [])
            == "# ACP session\n")
    }

    @Test("message bodies pass through verbatim (markdown not mangled)")
    func documentVerbatim() {
        let raw = "## Heading\n\n- a\n- b\n\n```swift\nlet x = 1\n```"
        let messages: [ACPMessage] = [.agent(id: UUID(), StreamingText(raw))]
        let md = ACPTranscriptMarkdown.document(title: "T", agentName: "A", messages: messages)
        #expect(md == "# T\n\n## A\n\n\(raw)\n")
    }

    @Test("document autolinks bare prose URLs")
    func documentAutolinksBareProseURLs() {
        let messages: [ACPMessage] = [
            .agent(id: UUID(), StreamingText("See https://example.com/path."))
        ]
        let md = ACPTranscriptMarkdown.document(title: "T", agentName: "A", messages: messages)
        #expect(md == "# T\n\n## A\n\nSee <https://example.com/path>.\n")
    }

    @Test("document does not autolink fenced code URLs")
    func documentSkipsFencedCodeURLs() {
        let raw = """
        Before https://example.com/start.

        ```sh
        curl https://example.com/api
        ```
        """
        let messages: [ACPMessage] = [.agent(id: UUID(), StreamingText(raw))]
        let md = ACPTranscriptMarkdown.document(title: "T", agentName: "A", messages: messages)
        #expect(md == """
        # T

        ## A

        Before <https://example.com/start>.

        ```sh
        curl https://example.com/api
        ```

        """)
    }

    @Test("messageBody returns serialized Markdown with bare URL autolinks")
    func messageBodyAutolinksBareURLs() {
        #expect(ACPTranscriptMarkdown.messageBody(
            .user(id: UUID(), text: "Open https://example.com/docs.", attachments: [])
        ) == "Open <https://example.com/docs>.")
        #expect(ACPTranscriptMarkdown.messageBody(
            .agent(id: UUID(), StreamingText("Use `https://example.com/api`."))
        ) == "Use `https://example.com/api`.")
    }

    @Test("messageBody returns serialized text for user/agent, nil otherwise")
    func messageBody() {
        #expect(ACPTranscriptMarkdown.messageBody(
            .user(id: UUID(), text: "u", attachments: [])) == "u")
        #expect(ACPTranscriptMarkdown.messageBody(
            .agent(id: UUID(), StreamingText("a"))) == "a")
        #expect(ACPTranscriptMarkdown.messageBody(
            .thought(id: UUID(), StreamingText("t"))) == nil)
        #expect(ACPTranscriptMarkdown.messageBody(
            .toolCall(.init(toolCallId: "t1", title: "Read", status: "done"))) == nil)
        #expect(ACPTranscriptMarkdown.messageBody(
            .systemNotice(id: UUID(), text: "s")) == nil)
    }

    @Test("sanitizedFilename strips illegal chars and appends .md")
    func sanitizedFilename() {
        #expect(ACPTranscriptMarkdown.sanitizedFilename(title: "a/b\nc") == "a-b-c.md")
        #expect(ACPTranscriptMarkdown.sanitizedFilename(title: "Hello World") == "Hello-World.md")
        #expect(ACPTranscriptMarkdown.sanitizedFilename(title: "New session") == "acp-session.md")
        #expect(ACPTranscriptMarkdown.sanitizedFilename(title: "   ") == "acp-session.md")
    }
}
