import Foundation
import Testing
@testable import Alas

@Suite("ACP upstream reference detector")
struct ACPUpstreamReferenceDetectorTests {
    private func spellings(_ text: String, _ host: CodeHostKind = .github,
                           precededBy: unichar? = nil, followedBy: unichar? = nil) -> [String] {
        ACPUpstreamReferenceDetector.references(in: text, host: host, precededBy: precededBy, followedBy: followedBy)
            .map(\.reference.spelling)
    }

    @Test("GitHub accepts only #, GitLab accepts # and !")
    func sigilsPerHost() {
        #expect(spellings("see #12 and !34") == ["#12"])
        #expect(spellings("see #12 and !34", .gitlab) == ["#12", "!34"])
    }

    @Test("tokens need a boundary on both sides")
    func boundaries() {
        #expect(spellings("(#12) \"#7\" #3. #4, #5!") == ["#12", "#7", "#3", "#4", "#5"])
        #expect(spellings("abc#12 #12abc #1_2 #") == [])
        #expect(spellings("x!3 !3", .gitlab) == ["!3"])
    }

    @Test("leading zeros and more than nine digits are not references")
    func digitGrammar() {
        #expect(spellings("#0 #012 #1234567890 #123456789") == ["#123456789"])
    }

    @Test("code spans and fenced blocks are skipped; an unclosed backtick is literal")
    func codeExclusion() {
        #expect(spellings("`#12` #13") == ["#13"])
        #expect(spellings("```\n#12\n```\n#14") == ["#14"])
        #expect(spellings("`#12") == ["#12"])
    }

    @Test(
        "an open fence extends to the end of the text only when asked",
        arguments: [
            (unclosedRunsExtendToEnd: false, expected: ["#13"]),
            (unclosedRunsExtendToEnd: true, expected: [] as [String]),
        ]
    )
    func openFenceExtendsOnlyWhenRequested(unclosedRunsExtendToEnd: Bool, expected: [String]) {
        let text = "```\nsee #13"
        let spellings = ACPUpstreamReferenceDetector.references(
            in: text, host: .github, unclosedRunsExtendToEnd: unclosedRunsExtendToEnd
        ).map(\.reference.spelling)
        #expect(spellings == expected)
    }

    @Test("a fragment's edges are boundaries only where its neighbours allow")
    func fragmentContext() {
        #expect(spellings("#12", precededBy: 0x61) == [])        // "a"
        #expect(spellings("#12", followedBy: 0x78) == [])        // "x"
        #expect(spellings("#12", precededBy: 0x20, followedBy: 0x2E) == ["#12"])
    }

    @Test("whitespace after a token completes it, carrying typed punctuation along")
    func keystrokeTarget() throws {
        let plain = try #require(ACPUpstreamReferenceDetector.chipTarget(
            completingWith: " ", at: NSRange(location: 7, length: 0), in: "see #12", host: .github
        ))
        #expect(plain.match.range == NSRange(location: 4, length: 3))
        #expect(plain.replaceRange == NSRange(location: 4, length: 3))

        let punctuated = try #require(ACPUpstreamReferenceDetector.chipTarget(
            completingWith: " ", at: NSRange(location: 6, length: 0), in: "(#12).", host: .github
        ))
        #expect(punctuated.match.range == NSRange(location: 1, length: 3))
        #expect(punctuated.replaceRange == NSRange(location: 1, length: 5))
    }

    @Test("non-whitespace keystrokes, glued tokens, and open code spans never complete")
    func keystrokeMisses() {
        func target(_ typed: String, _ text: String) -> Bool {
            ACPUpstreamReferenceDetector.chipTarget(
                completingWith: typed,
                at: NSRange(location: (text as NSString).length, length: 0),
                in: text,
                host: .github
            ) != nil
        }
        #expect(!target(".", "see #12"))
        #expect(!target(" ", "abc#12"))
        #expect(!target(" ", "`see #12"))
        #expect(!target(" ", "see #"))
    }

    private static let github = CodeHostRemote(
        kind: .github, host: "github.com", owner: "mrmans0n", repository: "alas",
        remoteName: "origin", webURL: URL(string: "https://github.com/mrmans0n/alas")!
    )
    private static let gitlab = CodeHostRemote(
        kind: .gitlab, host: "gitlab.example.com", owner: "platform/mobile", repository: "alas",
        remoteName: "origin", webURL: URL(string: "https://gitlab.example.com/platform/mobile/alas")!
    )

    private func urls(_ text: String, _ remote: CodeHostRemote = Self.github) -> [String] {
        ACPUpstreamReferenceDetector.urlReferences(in: text, remote: remote).map(\.reference.spelling)
    }

    @Test("same-repo PR and issue URLs map to their reference, keeping trailing punctuation outside")
    func urlMatches() {
        let text = "see https://github.com/mrmans0n/alas/pull/1506. and (HTTP://GitHub.com/MrMans0n/Alas/issues/12/)"
        let matches = ACPUpstreamReferenceDetector.urlReferences(in: text, remote: Self.github)
        #expect(matches.map(\.reference.spelling) == ["#1506", "#12"])
        let first = (text as NSString).substring(with: matches[0].range)
        #expect(first == "https://github.com/mrmans0n/alas/pull/1506")
        #expect(urls("https://gitlab.example.com/platform/mobile/alas/-/merge_requests/9 https://gitlab.example.com/platform/mobile/alas/-/issues/3", Self.gitlab)
            == ["!9", "#3"])
    }

    @Test("URLs into a PR, for another repo, inside a markdown link, or in code stay URLs")
    func urlMisses() {
        #expect(urls("https://github.com/mrmans0n/alas/pull/1506/files") == [])
        #expect(urls("https://github.com/mrmans0n/alas/pull/1506#issuecomment-1") == [])
        #expect(urls("https://github.com/mrmans0n/alas/pull/1506?w=1") == [])
        #expect(urls("https://github.com/someone/else/pull/1506") == [])
        #expect(urls("https://github.com/mrmans0n/alas-fork/pull/1506") == [])
        #expect(urls("[the fix](https://github.com/mrmans0n/alas/pull/1506)") == [])
        #expect(urls("`https://github.com/mrmans0n/alas/pull/1506`") == [])
        #expect(urls("xhttps://github.com/mrmans0n/alas/pull/1506") == [])
        #expect(urls("https://github.com/mrmans0n/alas/pull/0150") == [])
    }
}
