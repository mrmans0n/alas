import Foundation
import Testing
@testable import AlasCore

/// File scope so `@Test(arguments:)` can interpolate it.
private let visualHost = "6f0c2d4e-8b1a-4c3d-9e5f-1a2b3c4d5e6f"

struct RemoteVisualAidWebPolicyTests {
    private static let id = UUID(uuidString: "6F0C2D4E-8B1A-4C3D-9E5F-1A2B3C4D5E6F")!
    private static let template = "<html class=\"{{HTML_CLASS}}\"><head>{{HEAD}}</head><body>{{CONTENT}}</body></html>"

    @Test(arguments: [
        ("alas-visual://\(visualHost)/", true, true),
        ("alas-visual://\(visualHost)/#section", true, true),
        ("alas-visual://\(visualHost)/", false, false),
        ("https://example.com/", true, false),
    ])
    func navigationStaysOnTheDocument(url: String, mainFrame: Bool, allowed: Bool) {
        #expect(RemoteVisualAidWebPolicy.allowsNavigation(to: URL(string: url), mainFrame: mainFrame, visualID: Self.id) == allowed)
    }

    @Test(arguments: [
        ("<!DOCTYPE html><html></html>", true),
        ("  \n<!doctype html>", true),
        ("<!-- note --> <HTML lang=\"en\">", true),
        ("<!-- unterminated <html>", false),
        ("<div>hi</div>", false),
        ("<h2>html</h2>", false),
        ("<html-preview>x</html-preview>", false),
        ("<!doctype-widget>", false),
        ("<html>", true),
        ("<html/>", true),
        ("<!DOCTYPE\nhtml>", true),
    ])
    func fullDocumentDetection(html: String, full: Bool) {
        #expect(RemoteVisualAidWebPolicy.isFullDocument(html) == full)
    }

    @Test("fragments go inside the template verbatim, placeholders included")
    func fragmentAssembly() {
        let html = "<p>{{CONTENT}} and {{HEAD}}</p>"
        let document = String(decoding: RemoteVisualAidWebPolicy.document(html: html, themeVariables: ["--alas-text": "red"], frameTemplate: Self.template, presentation: .card), as: UTF8.self)
        #expect(document.contains("<body><p>{{CONTENT}} and {{HEAD}}</p></body>"))
        #expect(document.contains("--alas-text: red;"))
        #expect(document.contains(RemoteVisualAidWebPolicy.contentSecurityPolicy))
    }

    @Test("the frame carries the presentation class and never rewrites agent HTML", arguments: [
        (ACPVisualAid.Presentation.embedded, "alas-embedded"), (.card, "alas-card"),
    ])
    func fragmentGetsPresentationClass(presentation: ACPVisualAid.Presentation, expected: String) {
        let document = String(decoding: RemoteVisualAidWebPolicy.document(
            html: "<p>{{HTML_CLASS}}</p>", themeVariables: [:], frameTemplate: Self.template, presentation: presentation), as: UTF8.self)
        #expect(document.contains(#"<html class="\#(expected)">"#))
        #expect(document.contains("<body><p>{{HTML_CLASS}}</p></body>"))
    }

    @Test("content height clamps per presentation", arguments: [
        (ACPVisualAid.Presentation.card, Double(5000), Double(720)),
        (.embedded, 5000, 2000), (.embedded, 900, 900), (.embedded, 10, 120),
    ])
    func contentHeightClamps(presentation: ACPVisualAid.Presentation, content: Double, expected: Double) {
        #expect(RemoteVisualAidWebPolicy.contentHeight(forContentHeight: content, presentation: presentation) == expected)
    }

    @Test("a full document is returned unchanged", arguments: [
        "<!DOCTYPE html><html><HEAD lang=\"x\"><title>t</title></HEAD><body>b</body></html>",
        "<html><body>b</body></html>",
        "<html><!-- <head> --><head><title>t</title></head></html>",
        "<html><head data-x=\"a>b\"><title>t</title></head></html>",
        "<html><header>h</header><head><title>t</title></head></html>",
        "<html data-note=\"<head>\"><body>b</body></html>",
        "<html><body><script>const tag = '<head>';</script></body></html>",
    ])
    func fullDocumentIsReturnedUnchanged(html: String) {
        for presentation in [ACPVisualAid.Presentation.embedded, .card] {
            let document = RemoteVisualAidWebPolicy.document(html: html, themeVariables: ["--alas-text": "red"], frameTemplate: Self.template, presentation: presentation)
            #expect(document == Data(html.utf8), "\(presentation)")
        }
    }

    @Test("the sandbox never allows connections or form posts")
    func cspBlocksExfiltrationChannels() {
        #expect(RemoteVisualAidWebPolicy.contentSecurityPolicy.contains("connect-src 'none'"))
        #expect(RemoteVisualAidWebPolicy.contentSecurityPolicy.contains("form-action 'none'"))
    }

    @Test("a question visual's links stay dead until it is answered, and a dismissal does not unlock them", arguments: [
        (false, ACPVisualAid.Answer?.none, true),
        (true, ACPVisualAid.Answer?.none, false),
        (true, .dismissed(at: Date(timeIntervalSince1970: 0)), false),
        (true, .answered(selectedOptionIds: ["a"], note: nil, at: Date(timeIntervalSince1970: 0)), true),
    ])
    func externalLinksWaitForTheAnswer(hasQuestion: Bool, answer: ACPVisualAid.Answer?, allowed: Bool) {
        #expect(RemoteVisualAidWebPolicy.allowsExternalLinks(hasQuestion: hasQuestion, answer: answer) == allowed)
    }

    @Test("only the loading rules let https resources in; the locked rules keep the scheme, data and blob")
    func lockedRulesDropHttps() throws {
        func filters(_ rules: String) throws -> [String] {
            let list = try #require(JSONSerialization.jsonObject(with: Data(rules.utf8)) as? [[String: Any]])
            return list.compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String }
        }
        let loading = try filters(RemoteVisualAidWebPolicy.contentRules)
        let locked = try filters(RemoteVisualAidWebPolicy.lockedContentRules)
        #expect(loading.contains { $0.hasPrefix("^https:") })
        #expect(!locked.contains { $0.hasPrefix("^https:") })
        #expect(locked.contains("^alas-visual:"))
    }

    private static func question(allowMultiple: Bool = false) -> ACPVisualAid.Question {
        .init(prompt: "Which?", options: [.init(id: "a", label: "One"), .init(id: "b", label: "Two")], allowMultiple: allowMultiple)
    }

    @Test func visualAnswersKeepQuestionOrderAndTrimTheNote() throws {
        let question = Self.question(allowMultiple: true)
        #expect(RemoteVisualAidAnswer.answer(
            to: question, action: "answer", selectedOptionIds: ["b", "a"], note: "  keep it  ", at: .distantPast
        ) == .answered(selectedOptionIds: ["a", "b"], note: "keep it", at: .distantPast))
        #expect(RemoteVisualAidAnswer.answer(
            to: question, action: "dismiss", selectedOptionIds: [], note: nil, at: .distantPast
        ) == .dismissed(at: .distantPast))
    }

    @Test(arguments: [(2000, true), (2001, false)])
    func aNoteIsLimitedByGraphemesNotBytes(count: Int, accepted: Bool) throws {
        let question = Self.question()
        let note = String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}", count: count)
        #expect((RemoteVisualAidAnswer.answer(to: question, action: "answer", selectedOptionIds: ["a"], note: note) != nil) == accepted)
    }

    /// The same vectors run in scripts/tests/remote-web-visual-aid/test-visual-aid.js against `trimNote`: the phone
    /// must count and send exactly what this side trims (CharacterSet.whitespacesAndNewlines).
    @Test(arguments: [
        (0x85, true), (0x200B, true), (0xA0, true), (0x2028, true), (0x3000, true), (0x1680, true),
        (0x202F, true), (0xFEFF, false),
    ] as [(UInt32, Bool)])
    func noteEdgesTrimLikeThePhone(scalar: UInt32, trimmed: Bool) throws {
        let question = Self.question()
        let edge = String(Unicode.Scalar(scalar)!)
        let body = String(repeating: "x", count: 2000)
        for (note, expectedNote) in [(edge + body, trimmed ? body : nil), (edge + body + edge, trimmed ? body : nil), (edge, trimmed ? "" : edge)] {
            let answer = RemoteVisualAidAnswer.answer(to: question, action: "answer", selectedOptionIds: ["a"], note: note)
            // Kept edge characters push the 2000-character body over the limit; the edge-only note stays valid.
            let accepted = trimmed || note == edge
            #expect((answer != nil) == accepted, "U+\(String(scalar, radix: 16)) \(note.count)")
            if accepted, case .answered(_, let stored, _) = answer {
                #expect(stored == (expectedNote?.isEmpty == true ? nil : expectedNote))
            }
        }
    }
}
