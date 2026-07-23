import Foundation
import Testing
@testable import Alas

struct RunScriptMetadataTests {
    @Test func parsesAllKeys() {
        let contents = """
        #!/bin/zsh
        # alas-name: Dev Server
        # alas-on-exit: close
        # alas-cwd: apps/web
        echo hi
        """
        let meta = RunScriptMetadata.parse(fileName: "dev.sh", contents: contents)
        #expect(meta.displayName == "Dev Server")
        #expect(meta.onExit == .close)
        #expect(meta.cwd == "apps/web")
    }

    @Test func defaultsWhenNoHeader() {
        let meta = RunScriptMetadata.parse(fileName: "run-tests.sh", contents: "echo hi\n")
        #expect(meta.displayName == "run-tests")
        #expect(meta.onExit == .keep)
        #expect(meta.cwd == nil)
    }

    @Test func fileNameWithoutExtensionKeepsFullName() {
        let meta = RunScriptMetadata.parse(fileName: "Makefile", contents: "")
        #expect(meta.displayName == "Makefile")
    }

    @Test func unknownOnExitValueFallsBackToKeep() {
        let meta = RunScriptMetadata.parse(fileName: "a.sh", contents: "# alas-on-exit: explode\n")
        #expect(meta.onExit == .keep)
    }

    @Test func headerPastLine20IsIgnored() {
        let padding = String(repeating: "# filler\n", count: 20)
        let meta = RunScriptMetadata.parse(fileName: "a.sh", contents: padding + "# alas-name: Late\n")
        #expect(meta.displayName == "a")
    }

    @Test func toleratesSpacingVariants() {
        let meta = RunScriptMetadata.parse(fileName: "a.sh", contents: "#alas-name:   Spaced Out  \n")
        #expect(meta.displayName == "Spaced Out")
    }

    @Test func scriptKeyCombinesScopeAndFileName() {
        let script = RunScript(
            scope: .repo, fileName: "dev.sh",
            fileURL: URL(fileURLWithPath: "/tmp/dev.sh"),
            displayName: "Dev", onExit: .keep, cwd: nil, isExecutable: true
        )
        #expect(script.key == "repo:dev.sh")
        #expect(script.id == script.key)
    }
}
