import Foundation
import Testing
@testable import Alas

struct PluginViewTreeTests {
    private func decode(_ json: String) -> Result<PluginViewNode, PluginViewTreeError> {
        PluginViewTree.decode(Data(json.utf8))
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
    ])
    func invalidTreesAreRejected(json: String, reason: String) {
        #expect(throws: PluginViewTreeError(reason: reason)) { try decode(json).get() }
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

    /// Review focus 2.
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
