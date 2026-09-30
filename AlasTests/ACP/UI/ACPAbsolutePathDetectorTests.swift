import Foundation
import Testing
@testable import Alas

@Suite("ACP absolute path detector")
struct ACPAbsolutePathDetectorTests {
    private let existing: [String: Bool] = [
        "/Users/me/Desktop/clip.mp4": false,
        "/Users/me/Desktop": true,
        "/tmp/a.txt": false,
    ]

    private func found(_ text: String, precededBy: unichar? = nil, followedBy: unichar? = nil) -> [String] {
        ACPAbsolutePathDetector
            .matches(in: text, precededBy: precededBy, followedBy: followedBy, probe: { existing[$0] })
            .map { (text as NSString).substring(with: $0.range) }
    }

    @Test("only paths that exist count, at word boundaries", arguments: [
        ("see /Users/me/Desktop/clip.mp4", ["/Users/me/Desktop/clip.mp4"]),
        ("(/tmp/a.txt)", ["/tmp/a.txt"]),
        ("\"/tmp/a.txt\"", ["/tmp/a.txt"]),
        ("/tmp/a.txt, then /Users/me/Desktop.", ["/tmp/a.txt", "/Users/me/Desktop"]),
        ("/review the diff", []),
        ("and/or /tmp/missing.txt", []),
        ("https://example.com/tmp/a.txt", []),
        ("//tmp/a.txt", []),
        ("x/tmp/a.txt", []),
    ])
    func boundariesAndExistence(text: String, expected: [String]) {
        #expect(found(text) == expected)
    }

    @Test("a token cut off by a fragment edge waits for its neighbour")
    func fragmentEdges() {
        #expect(found("/tmp/a.txt", followedBy: 0x78) == [])
        #expect(found("/tmp/a.txt", followedBy: 0x20) == ["/tmp/a.txt"])
        #expect(found("/tmp/a.txt", precededBy: 0x78) == [])
    }

    @Test("tilde paths resolve against the home directory and report directories")
    func tildeExpansion() {
        let home = NSHomeDirectory()
        let matches = ACPAbsolutePathDetector.matches(in: "open ~/Desktop now", probe: { $0 == home + "/Desktop" ? true : nil })
        #expect(matches.map(\.path) == [home + "/Desktop"])
        #expect(matches.first?.isDirectory == true)
        #expect(matches.first?.range == NSRange(location: 5, length: 9))
    }
}
