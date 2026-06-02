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

@Suite("CursorModelVariants.derive")
struct CursorModelVariantsDeriveTests {
    private func model(_ id: String, _ name: String) -> ACPModelInfo {
        ACPModelInfo(id: id, name: name)
    }

    @Test("derives Model + Thinking from effort-bearing variants")
    func effortVariants() {
        let models = [
            model("claude-opus-4-6[effort=low,context=200k]",    "Opus 4.6"),
            model("claude-opus-4-6[effort=medium,context=200k]", "Opus 4.6"),
            model("claude-opus-4-6[effort=high,context=200k]",   "Opus 4.6"),
            model("gpt-5.3-codex[effort=medium]",                "GPT 5.3 Codex"),
        ]
        let d = CursorModelVariants.derive(
            availableModels: models,
            currentModel: "claude-opus-4-6[effort=medium,context=200k]")

        #expect(d.model?.options.map { $0.name }.sorted() == ["GPT 5.3 Codex", "Opus 4.6"])
        // Selecting GPT switches base while preserving the user's current effort=medium.
        let gpt = d.model?.options.first { $0.name == "GPT 5.3 Codex" }
        #expect(gpt?.id == "gpt-5.3-codex[effort=medium]")
        #expect(d.model?.currentId == "claude-opus-4-6[effort=medium,context=200k]")

        #expect(d.thinking?.options.map { $0.name } == ["low", "medium", "high"])
        let medium = d.thinking?.options.first { $0.name == "medium" }
        #expect(medium?.id == "claude-opus-4-6[effort=medium,context=200k]")
        #expect(d.thinking?.currentId == "claude-opus-4-6[effort=medium,context=200k]")
    }

    @Test("falls back to `thinking` bool when no `effort` attrs present")
    func thinkingBoolFallback() {
        let models = [
            model("claude-sonnet-4-6[thinking=true,context=200k]",  "Sonnet 4.6"),
            model("claude-sonnet-4-6[thinking=false,context=200k]", "Sonnet 4.6"),
        ]
        let d = CursorModelVariants.derive(
            availableModels: models,
            currentModel: "claude-sonnet-4-6[thinking=true,context=200k]")
        #expect(d.thinking?.options.map { $0.name } == ["true", "false"])
        let on = d.thinking?.options.first { $0.name == "true" }
        #expect(on?.id == "claude-sonnet-4-6[thinking=true,context=200k]")
    }

    @Test("no brackets anywhere -> both chips nil")
    func noBrackets() {
        let d = CursorModelVariants.derive(
            availableModels: [model("a", "A"), model("b", "B")],
            currentModel: "a")
        #expect(d.model == nil)
        #expect(d.thinking == nil)
    }

    @Test("currentModel not in availableModels -> nil chips")
    func unknownCurrentModel() {
        let models = [model("a[effort=high]", "A")]
        let d = CursorModelVariants.derive(
            availableModels: models,
            currentModel: "z[effort=low]")
        #expect(d.model == nil)
        #expect(d.thinking == nil)
    }

    @Test("base group with no effort/thinking attr -> Thinking nil, Model still derived")
    func modelOnlyWhenNoThinkingAttr() {
        let models = [
            model("a[context=4k]", "A"),
            model("b[context=4k]", "B"),
        ]
        let d = CursorModelVariants.derive(
            availableModels: models,
            currentModel: "a[context=4k]")
        #expect(d.model?.options.map { $0.name }.sorted() == ["A", "B"])
        #expect(d.thinking == nil)
    }
}
