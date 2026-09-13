import Foundation
import Testing
@testable import Alas

struct RunScriptWritingHelpTests {
    @Test func identifiesOnlyDirectChildrenOfScriptDirectories() {
        let root = URL(fileURLWithPath: "/tmp/repository")
        let global = URL(fileURLWithPath: "/tmp/global-scripts")
        #expect(RunScriptWritingHelp.scope(for: root.appendingPathComponent(".alas/scripts/build.sh"), worktreeRoot: root, globalDir: global) == .repo)
        #expect(RunScriptWritingHelp.scope(for: global.appendingPathComponent("build.sh"), worktreeRoot: root, globalDir: global) == .global)
        for path in ["scripts/build.sh", ".alas/scripts-old/build.sh", ".alas/scripts/nested/build.sh"] {
            #expect(RunScriptWritingHelp.scope(for: root.appendingPathComponent(path), worktreeRoot: root, globalDir: global) == nil)
        }
    }

    @Test func globalPromptIncludesPortabilityAndReviewInstructions() {
        let prompt = RunScriptWritingHelp.prompt(
            scope: .global,
            scriptURL: URL(fileURLWithPath: "/tmp/global scripts/status.sh"),
            worktreeRoot: URL(fileURLWithPath: "/tmp/repository"),
            request: "  Show uncommitted changes  "
        )
        #expect(prompt.contains("Script path: /tmp/global scripts/status.sh"))
        #expect(prompt.contains("portable across repositories"))
        #expect(prompt.contains("preserve my work and metadata"))
        #expect(prompt.contains("Do not run it automatically"))
        #expect(prompt.hasSuffix("Show uncommitted changes"))
    }
}
