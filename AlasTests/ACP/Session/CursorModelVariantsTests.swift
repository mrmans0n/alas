import Foundation
import Testing
@testable import Alas

@Suite("CursorModelVariants.parse / compose")
struct CursorModelVariantsTests {
    @Test("plain id with no brackets parses to base and empty attrs")
    func plainId() {
        let v = CursorModelVariants.parse("gpt-5.3-codex")
        #expect(v.base == "gpt-5.3-codex")
        #expect(v.attrs.isEmpty)
        #expect(CursorModelVariants.compose(base: v.base, attrs: v.attrs) == "gpt-5.3-codex")
    }

    @Test("bracketed id parses base and ordered attrs")
    func bracketed() {
        let id = "claude-opus-4-6[thinking=true,context=200k,effort=high,fast=false]"
        let v = CursorModelVariants.parse(id)
        #expect(v.base == "claude-opus-4-6")
        #expect(v.attrs.map { $0.key } == ["thinking", "context", "effort", "fast"])
        #expect(v.attrs.map { $0.value } == ["true", "200k", "high", "false"])
        #expect(CursorModelVariants.compose(base: v.base, attrs: v.attrs) == id)
    }

    @Test("single-attr bracketed id round-trips")
    func singleAttr() {
        let id = "m[effort=medium]"
        let v = CursorModelVariants.parse(id)
        #expect(v.base == "m")
        #expect(v.attrs.count == 1)
        #expect(v.attrs[0].key == "effort")
        #expect(v.attrs[0].value == "medium")
        #expect(CursorModelVariants.compose(base: v.base, attrs: v.attrs) == id)
    }

    @Test("malformed bracketed id (missing close) treats whole string as base")
    func malformedMissingClose() {
        let v = CursorModelVariants.parse("m[effort=high")
        #expect(v.base == "m[effort=high")
        #expect(v.attrs.isEmpty)
    }

    @Test("attr fragments without '=' are skipped")
    func skipsBareFragments() {
        let v = CursorModelVariants.parse("m[effort=high,broken,context=4k]")
        #expect(v.attrs.map { $0.key } == ["effort", "context"])
        #expect(v.attrs.map { $0.value } == ["high", "4k"])
    }
}
