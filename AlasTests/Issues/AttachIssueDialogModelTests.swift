import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("Attach Issue dialog model")
struct AttachIssueDialogModelTests {
    @Test("resolving a URL preselects its exact candidate project and seeds the draft")
    func resolvesURLAndSeedsDraft() async {
        let fixture = Fixture()
        let model = AttachIssueDialogModel(environment: fixture.environment)
        model.reference = " https://github.com/mrmans0n/alas/issues/42 "

        await model.resolve()

        #expect(model.phase == .confirmation)
        #expect(model.projectID == "alas")
        #expect(model.branchSeed == "feature/42-fix-offline-sync-conflicts")
        #expect(model.prompt == IssuePromptBuilder.build(source: fixture.resolution.source))
        #expect(model.makeDraft()?.attachment == IssueAttachment(
            canonicalURL: fixture.resolution.source.canonicalURL,
            providerLabel: "GitHub",
            displayReference: "#42",
            title: "Fix offline sync conflicts"
        ))
    }

    @Test("resolving a short issue reference uses the matching configured project")
    func resolvesShortReference() async {
        let fixture = Fixture(candidateProjectIDs: ["missing", "alas"])
        let model = AttachIssueDialogModel(environment: fixture.environment)
        model.reference = "#42"

        await model.resolve()

        #expect(model.phase == .confirmation)
        #expect(model.projectID == "alas")
    }

    @Test("a GitHub fallback can be adopted and edited manually")
    func adoptsGitHubFallbackManually() async {
        let fixture = Fixture(resolutionFailure: .init(
            fallback: Fixture.manualResolution(providerLabel: "GitHub"),
            message: "Authentication is required for github.com."
        ))
        let model = AttachIssueDialogModel(environment: fixture.environment)
        model.reference = "https://github.com/mrmans0n/alas/issues/42"

        await model.resolve()
        #expect(model.phase == .entry)
        #expect(model.canContinueManually)
        #expect(model.errorMessage == "Authentication is required for github.com.")

        await model.continueManually()
        model.title = "Fix fallback"
        model.context = "Use the issue page as context."

        let draft = model.makeDraft()
        #expect(model.phase == .confirmation)
        #expect(draft?.source.title == "Fix fallback")
        #expect(draft?.source.body == "Use the issue page as context.")
    }

    @Test("a GitLab fallback can be adopted manually")
    func adoptsGitLabFallbackManually() async {
        let fixture = Fixture(resolutionFailure: .init(
            fallback: Fixture.manualResolution(providerLabel: "GitLab"),
            message: "Authentication is required for gitlab.com."
        ))
        let model = AttachIssueDialogModel(environment: fixture.environment)
        model.reference = "https://gitlab.com/acme/alas/-/issues/42"

        await model.resolve()
        await model.continueManually()

        #expect(model.phase == .confirmation)
        #expect(model.title.isEmpty)
        #expect(model.projectID == "alas")
    }

    @Test("a user-owned prompt survives a later resolution")
    func preservesUserOwnedPrompt() async {
        let fixture = Fixture(suspendResolution: true)
        let model = AttachIssueDialogModel(environment: fixture.environment)
        model.reference = "#42"
        let resolution = Task { await model.resolve() }
        await fixture.waitUntilResolutionStarts()

        model.setPrompt("Keep this prompt.")
        fixture.finishResolution()
        await resolution.value

        #expect(model.prompt == "Keep this prompt.")
    }

    @Test("manual edits regenerate the prompt until the user edits the prompt")
    func manualEditsRegenerateGeneratedPrompt() async {
        let fixture = Fixture(resolution: Fixture.manualResolution(providerLabel: "Manual"))
        let model = AttachIssueDialogModel(environment: fixture.environment)
        model.reference = "https://example.com/issues/42"

        await model.resolve()
        model.title = "Fix retry flow"
        model.context = "Retry should preserve the issue prompt."

        #expect(model.prompt.contains("Fix retry flow"))
        #expect(model.prompt.contains("Retry should preserve the issue prompt."))

        model.setPrompt("Keep this custom prompt.")
        model.title = "A later title"
        model.context = "Later context."

        #expect(model.makeDraft()?.source.title == "A later title")
        #expect(model.makeDraft()?.source.body == "Later context.")
        #expect(model.makeDraft()?.prompt == "Keep this custom prompt.")
    }

    @Test("changing references resets prompt ownership for the new issue")
    func changingReferenceResetsPromptOwnership() async {
        let project = ProjectConfig(
            id: "alas",
            name: "Alas",
            path: "/tmp/alas",
            color: "blue",
            addedAt: .distantPast
        )
        let model = AttachIssueDialogModel(environment: .init(
            resolve: { reference in
                reference == "#43"
                    ? Fixture.resolvedIssue(displayReference: "#43", title: "Fix second issue")
                    : Fixture.resolvedIssue(displayReference: "#42", title: "Fix first issue")
            },
            projects: { [project] },
            configuredBranchPrefix: { _ in "feature/" }
        ))
        model.reference = "#42"
        await model.resolve()
        model.setPrompt("Keep this only for the first issue.")

        model.reference = "#43"
        await model.resolve()

        #expect(model.prompt.contains("Fix second issue"))
        #expect(!model.prompt.contains("Keep this only for the first issue."))
    }

    @Test("changing input rejects a stale generation")
    func rejectsStaleGenerationAfterInputChange() async {
        let fixture = Fixture(suspendResolution: true)
        let model = AttachIssueDialogModel(environment: fixture.environment)
        model.reference = "#42"
        let resolution = Task { await model.resolve() }
        await fixture.waitUntilResolutionStarts()

        model.reference = "#43"
        fixture.finishResolution()
        await resolution.value

        #expect(model.phase == .entry)
        #expect(model.resolved == nil)
        #expect(model.reference == "#43")
    }

    @Test("dismissing resolution rejects a late result")
    func rejectsStaleResultAfterDismissal() async {
        let fixture = Fixture(suspendResolution: true)
        let model = AttachIssueDialogModel(environment: fixture.environment)
        model.reference = "#42"
        let resolution = Task { await model.resolve() }
        await fixture.waitUntilResolutionStarts()

        model.cancelResolution()
        fixture.finishResolution()
        await resolution.value

        #expect(model.phase == .entry)
        #expect(model.resolved == nil)
    }

    @Test("attaching requires confirmation, a title, and a prompt")
    func validatesAttach() async {
        let fixture = Fixture(resolution: Fixture.manualResolution(providerLabel: "Manual"))
        let model = AttachIssueDialogModel(environment: fixture.environment)

        #expect(model.makeDraft() == nil)
        model.reference = "https://example.com/issues/42"
        await model.resolve()
        #expect(model.makeDraft() == nil)

        model.title = "Manual issue"
        model.prompt = ""
        #expect(model.makeDraft() == nil)

        model.setPrompt("Implement the issue.")
        #expect(model.makeDraft() != nil)
    }

    @Test("the model allows duplicate issue attachments")
    func allowsDuplicateAttachments() async {
        let fixture = Fixture()
        let first = AttachIssueDialogModel(environment: fixture.environment)
        let second = AttachIssueDialogModel(environment: fixture.environment)
        first.reference = "#42"
        second.reference = "#42"

        await first.resolve()
        await second.resolve()

        #expect(first.makeDraft() == second.makeDraft())
    }
}

@MainActor
private final class Fixture {
    let resolution: ResolvedIssue
    let resolutionFailure: IssueResolutionFailure?
    let projects: [ProjectConfig]
    let suspendResolution: Bool
    private var continuation: CheckedContinuation<Void, Never>?

    init(
        resolution: ResolvedIssue? = nil,
        resolutionFailure: IssueResolutionFailure? = nil,
        candidateProjectIDs: [String] = ["alas"],
        suspendResolution: Bool = false
    ) {
        projects = [ProjectConfig(
            id: "alas",
            name: "Alas",
            path: "/tmp/alas",
            color: "blue",
            addedAt: .distantPast
        )]
        self.resolution = resolution ?? Self.resolvedIssue(candidateProjectIDs: candidateProjectIDs)
        self.resolutionFailure = resolutionFailure
        self.suspendResolution = suspendResolution
    }

    var environment: AttachIssueDialogModel.Environment {
        .init(
            resolve: { [self] _ in
                if suspendResolution {
                    await withCheckedContinuation { continuation in
                        self.continuation = continuation
                    }
                }
                if let resolutionFailure { throw resolutionFailure }
                return resolution
            },
            projects: { [self] in projects },
            configuredBranchPrefix: { _ in "feature/" }
        )
    }

    func waitUntilResolutionStarts() async {
        while continuation == nil { await Task.yield() }
    }

    func finishResolution() {
        continuation?.resume()
        continuation = nil
    }

    static func resolvedIssue(
        candidateProjectIDs: [String] = ["alas"],
        displayReference: String = "#42",
        title: String = "Fix offline sync conflicts"
    ) -> ResolvedIssue {
        let source = IssueSnapshot(
            identity: .init(providerID: .github, stableID: "github.com/mrmans0n/alas\(displayReference)"),
            canonicalURL: URL(string: "https://github.com/mrmans0n/alas/issues/\(displayReference.dropFirst())")!,
            providerLabel: "GitHub",
            displayReference: displayReference,
            repositoryLocator: .init(provider: .github, host: "github.com", repositorySlug: "mrmans0n/alas"),
            title: title,
            body: "Offline changes can overwrite newer server changes.",
            state: .open,
            labels: [],
            assignees: [],
            providerUpdatedAt: nil,
            capturedAt: .distantPast,
            refreshError: nil,
            contentOrigin: .provider,
            isEditable: false,
            isRefreshable: true
        )
        return .init(source: source, repositoryLocator: source.repositoryLocator, candidateProjectIDs: candidateProjectIDs, selectedProjectID: candidateProjectIDs.last)
    }

    static func manualResolution(providerLabel: String) -> ResolvedIssue {
        var resolution = resolvedIssue()
        resolution.source = IssueSnapshot(
            identity: .init(providerID: .manual, stableID: "manual-42"),
            canonicalURL: resolution.source.canonicalURL,
            providerLabel: providerLabel,
            displayReference: "#42",
            repositoryLocator: resolution.source.repositoryLocator,
            title: "",
            body: "",
            state: .unknown,
            labels: [],
            assignees: [],
            providerUpdatedAt: nil,
            capturedAt: .distantPast,
            refreshError: nil,
            contentOrigin: .manual,
            isEditable: true,
            isRefreshable: false
        )
        return resolution
    }
}
