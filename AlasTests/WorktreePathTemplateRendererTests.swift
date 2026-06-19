import Foundation
import Testing
@testable import Alas

struct WorktreePathTemplateRendererTests {
    @Test func rendersConfiguredTemplate() {
        let rendered = WorktreePathTemplateRenderer.render(
            template: "{worktreeRoot}/{repo}-{branch}-{user}-{ts}",
            worktreeRoot: "/tmp/worktrees",
            repoName: "mrmans0n/alas",
            branch: "feature/review-cli",
            userName: "nacho",
            date: Date(timeIntervalSince1970: 0)
        )

        #expect(rendered.path == "/tmp/worktrees/alas-feature-review-cli-nacho-1970-01-01T00:00:00Z")
    }

    @Test func expandsTildeInRenderedPath() {
        let rendered = WorktreePathTemplateRenderer.render(
            template: "~/worktrees/{repo}/{branch}",
            worktreeRoot: "/unused",
            repoName: "alas",
            branch: "main",
            userName: "nacho",
            date: Date(timeIntervalSince1970: 0)
        )

        #expect(!rendered.path.hasPrefix("~"))
        #expect(rendered.path.hasSuffix("/worktrees/alas/main"))
    }
}
