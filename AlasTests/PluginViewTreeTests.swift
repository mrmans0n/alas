import Foundation
import Testing
@testable import Alas

struct PluginViewTreeTests {
    private func decode(_ json: String, api: Int = 8) -> Result<PluginViewNode, PluginViewTreeError> {
        PluginViewTree.decode(Data(json.utf8), api: api)
    }

    @Test func aValidTreeDecodesAndIgnoresUnknownOptionalFields() throws {
        let tree = try decode(#"""
        {"id":"root","kind":"vstack","spacing":8,"width":280,"future":true,"children":[
          {"id":"t","kind":"text","text":"Hi","style":"title","tone":"dim"},
          {"id":"s","kind":"scroll","axis":"horizontal","child":{"id":"c","kind":"card","clickable":true,"children":[
            {"id":"b","kind":"button","label":"Start","style":"primary","icon":"play"},
            {"id":"f","kind":"textField","value":"","placeholder":"Title","multiline":true},
            {"id":"m","kind":"menu","label":"Move to","items":[{"id":"done","label":"Done"}]}]}}]}
        """#).get()
        #expect(tree.children.count == 2)
        #expect(tree.width == 280)
        #expect(tree.children[1].horizontal)
        #expect(tree.children[1].children.first?.clickable == true)
        #expect(tree.children[1].children.first?.children[2].items == [.init(id: "done", label: "Done")])
    }

    @Test(arguments: [
        (#"{"id":"a","kind":"vstack","children":[{"id":"a","kind":"divider"}]}"#, "duplicate id \"a\""),
        (#"{"id":"a","kind":"table"}"#, "unknown kind \"table\""),
        (#"{"id":"a","kind":"text"}"#, "text \"a\" needs text"),
        (#"{"id":"a","kind":"button","label":5}"#, "not a valid view tree"),
        (#"{"id":"a","kind":"text","text":"x","style":"huge"}"#, "text \"a\" has unknown style \"huge\""),
        (#"{"id":"a","kind":"vstack","spacing":99,"children":[]}"#, "vstack \"a\" spacing must be 0 to 32"),
        (#"{"id":"a","kind":"vstack","width":39,"children":[]}"#, "vstack \"a\" width must be 40 to 1000"),
        (#"{"id":"a","kind":"card","width":1001,"children":[]}"#, "card \"a\" width must be 40 to 1000"),
        (#"{"id":"a","kind":"scroll","axis":"diagonal","child":{"id":"b","kind":"spacer"}}"#, "scroll \"a\" needs an axis"),
        (#"{"id":"","kind":"spacer"}"#, "node ids must be 1 to 64 bytes"),
        (#"{"id":"a","kind":"menu","label":"m","items":[{"id":"","label":"x"}]}"#, "menu item ids must be 1 to 64 bytes"),
        (#"{"id":"a","kind":"menu","label":"m","items":[{"id":"\#(String(repeating: "i", count: 65))","label":"x"}]}"#, "menu item ids must be 1 to 64 bytes"),
        (#"{"id":"a","kind":"menu","label":"m","items":[{"id":"i","label":"\#(String(repeating: "x", count: 4_001))"}]}"#, "menu item label is longer than 4000 characters"),
        (#"{"id":"a","kind":"link","label":"PR"}"#, "link \"a\" needs url"),
        (#"{"id":"a","kind":"link","label":"PR","url":"http://github.com/x"}"#, "link \"a\" url must be an absolute https URL of at most 2048 bytes"),
        (#"{"id":"a","kind":"link","label":"PR","url":"/pulls"}"#, "link \"a\" url must be an absolute https URL of at most 2048 bytes"),
        (#"{"id":"a","kind":"link","label":"PR","url":"javascript:alert(1)"}"#, "link \"a\" url must be an absolute https URL of at most 2048 bytes"),
        (#"{"id":"a","kind":"link","label":"PR","url":"https://a.com/\#(String(repeating: "x", count: 2_035))"}"#, "link \"a\" url must be an absolute https URL of at most 2048 bytes"),
    ])
    func invalidTreesAreRejected(json: String, reason: String) {
        #expect(throws: PluginViewTreeError(reason: reason)) { try decode(json).get() }
    }

    @Test func progressAndLinkDecode() throws {
        let tree = try decode(#"""
        {"id":"r","kind":"hstack","children":[{"id":"p","kind":"progress"},{"id":"q","kind":"progress","text":"Loading"},
          {"id":"l","kind":"link","label":"PR","url":"https://github.com/\#(String(repeating: "x", count: 2_029))"}]}
        """#).get()
        #expect(tree.children.map(\.text) == [nil, "Loading", nil])
        #expect(tree.children[2].url?.host == "github.com")
    }

    @Test(arguments: [
        (#"{"id":"a","kind":"progress"}"#, "progress", 8),
        (#"{"id":"a","kind":"link","label":"PR","url":"https://a.com"}"#, "link", 8),
        (#"{"id":"a","kind":"markdown","text":"**Hi**"}"#, "markdown", 9),
    ])
    func newerKindsNeedTheirAPI(json: String, kind: String, api: Int) {
        #expect(throws: PluginViewTreeError(reason: "kind \"\(kind)\" needs \"api\": \(api)")) { try decode(json, api: api - 1).get() }
    }

    /// Markdown has its own 32 KiB bound, in bytes, above the 4,000-character cap on other strings.
    @Test(arguments: [(32 * 1024, nil), (32 * 1024 + 1, "markdown \"m\" text is longer than 32768 bytes"), (nil, "markdown \"m\" needs text")] as [(Int?, String?)])
    func markdownTextIsRequiredAndBounded(bytes: Int?, reason: String?) {
        let text = bytes.map { #","text":"\#(String(repeating: "x", count: $0))""# } ?? ""
        let result = decode(#"{"id":"m","kind":"markdown"\#(text)}"#, api: 9)
        if let reason {
            #expect(throws: PluginViewTreeError(reason: reason)) { try result.get() }
        } else {
            #expect((try? result.get())?.text?.utf8.count == bytes)
        }
    }

    @Test(arguments: [(17, "tree is deeper than 16 levels"), (2_001, "tree has more than 2000 nodes")])
    func oversizedTreesAreRejected(size: Int, reason: String) {
        let json = size == 17
            ? (0..<16).reduce(#"{"id":"leaf","kind":"spacer"}"#) { inner, i in #"{"id":"n\#(i)","kind":"card","children":[\#(inner)]}"# }
            : #"{"id":"root","kind":"vstack","children":[\#((0..<2_000).map { #"{"id":"n\#($0)","kind":"spacer"}"# }.joined(separator: ","))]}"#
        #expect(throws: PluginViewTreeError(reason: reason)) { try decode(json).get() }
    }

    @Test func aSixteenLevelTreeIsAccepted() throws {
        let json = (0..<15).reduce(#"{"id":"leaf","kind":"spacer"}"#) { inner, i in #"{"id":"n\#(i)","kind":"card","children":[\#(inner)]}"# }
        _ = try decode(json).get()
    }

    @Test func excessiveNestingIsRejectedBeforeDecoding() {
        let json = String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)
        #expect(throws: PluginViewTreeError(reason: "tree is deeper than 16 levels")) { try decode(json).get() }
    }

    @Test func overlongStringsAreRejected() {
        let long = String(repeating: "x", count: PluginViewTree.maxString + 1)
        #expect(throws: PluginViewTreeError(reason: "text \"a\" is longer than 4000 characters")) {
            try decode(#"{"id":"a","kind":"text","text":"\#(long)"}"#).get()
        }
    }
}
