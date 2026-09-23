import Testing
@testable import Alas

@Suite("ACP local title generator")
struct ACPLocalTitleGeneratorTests {
    @Test("the first user request excludes injected context, markup, attachments and code")
    func extractsFirstProse() {
        let prompt = """
            <alas-workspace-context>
            internal workspace and credentials
            </alas-workspace-context>
            <metadata>
            internal task description
            </metadata>
            [Attachment: screenshot.png]
            ```swift
            let token = "hidden"
            ```
            Please fix the sign-in flow
            without losing saved accounts.

            Later, also add an export feature.
            """
        #expect(ACPLocalTitleGenerator.candidate(from: prompt) ==
            "Please fix the sign-in flow without losing saved accounts.")
        #expect(ACPLocalTitleGenerator.candidate(from: "<alas-workspace-context>private") == nil)
        #expect(ACPLocalTitleGenerator.candidate(from: "\n```swift\nlet a = 1\n```\n") == nil)
        #expect(ACPLocalTitleGenerator.candidate(from: "Hi") == nil)
        #expect(ACPLocalTitleGenerator.candidate(from: "Fix login") == "Fix login")
        #expect(ACPLocalTitleGenerator.candidate(from: "Fix the login") == "Fix the login")
    }
    @Test("the candidate is bounded before reaching the model")
    func boundsCandidate() {
        let candidate = ACPLocalTitleGenerator.candidate(from: String(repeating: "longword ", count: 250))
        #expect(candidate?.count == 1_000)
    }

    @Test("only a short, plain-language title is accepted")
    func validatesTitles() {
        #expect(ACPLocalTitleGenerator.validTitle("  Fix sign-in race  ") == "Fix sign-in race")
        for invalid in [
            " ", "123", "First line\nSecond line", "First\u{2028}Second",
            "one two three four five six seven eight", String(repeating: "a", count: 61),
            "`fix`", "# Sign-in fix", "- Sign-in fix", "func login() {}",
            "https://example.com", "./Sources/Login.swift", "<title>Login</title>"
        ] {
            #expect(ACPLocalTitleGenerator.validTitle(invalid) == nil)
        }
    }
}
