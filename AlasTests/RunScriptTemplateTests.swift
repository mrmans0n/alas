import Testing
@testable import Alas

struct RunScriptTemplateTests {
    @Test func fileNameSlugifies() {
        #expect(RunScriptTemplate.fileName(for: "Dev Server") == "dev-server.sh")
        #expect(RunScriptTemplate.fileName(for: "run: all/the tests!") == "run-all-the-tests.sh")
        #expect(RunScriptTemplate.fileName(for: "build.sh") == "build-sh.sh")
    }

    @Test func contentsEmbedNameAndDefaults() {
        let contents = RunScriptTemplate.contents(name: "Dev Server")
        #expect(contents.hasPrefix("#!/bin/zsh\n"))
        #expect(contents.contains("# alas-name: Dev Server"))
        #expect(contents.contains("# alas-on-exit: keep"))
        #expect(contents.hasSuffix("\n"))
    }

    @Test func templateRoundTripsThroughMetadataParser() {
        let meta = RunScriptMetadata.parse(
            fileName: RunScriptTemplate.fileName(for: "Dev Server"),
            contents: RunScriptTemplate.contents(name: "Dev Server")
        )
        #expect(meta.displayName == "Dev Server")
        #expect(meta.onExit == .keep)
    }

    @Test func emptyOrAllPunctuationNameFallsBackToScript() {
        #expect(RunScriptTemplate.fileName(for: "") == "script.sh")
        #expect(RunScriptTemplate.fileName(for: "!!!") == "script.sh")
    }
}
