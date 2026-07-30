import Testing
@testable import Alas

@MainActor
@Suite("Beautiful Mermaid backend")
struct BeautifulMermaidBackendTests {
    @Test("renders a native flowchart image")
    func rendersFlowchart() async throws {
        let theme = MermaidDiagramTheme(theme: try Theme.loadBundled(id: "cool-slate"))
        let outcome = await BeautifulMermaidBackend().render(key: MermaidRenderKey(
            source: "graph TD; A-->B;",
            theme: theme,
            scale: 2,
            profile: .full
        ))

        guard case .rendered(let diagram) = outcome else {
            Issue.record("expected a rendered flowchart")
            return
        }
        #expect(diagram.pixelSize.width > 0)
        #expect(diagram.pixelSize.height > 0)
    }

    @Test("rejects source over 256 KiB before rendering")
    func rejectsOversizedSource() async throws {
        let source = String(
            repeating: "a",
            count: BeautifulMermaidBackend.maximumSourceBytes + 1
        )
        let key = MermaidRenderKey(
            source: source,
            theme: MermaidDiagramTheme(
                theme: try Theme.loadBundled(id: "cool-slate")
            ),
            scale: 2,
            profile: .full
        )

        let outcome = await BeautifulMermaidBackend().render(key: key)

        #expect(
            outcome.failure
                == .sourceTooLarge(actualBytes: source.utf8.count)
        )
    }

    @Test("invalid source retains a renderer diagnostic")
    func invalidSourceFallsBack() async throws {
        let outcome = try await render(source: "not a Mermaid diagram")

        switch outcome.failure {
        case .parseFailed(let diagnostic), .renderFailed(let diagnostic):
            #expect(!diagnostic.isEmpty)
        default:
            Issue.record("expected invalid source to fail parsing or rendering")
        }
    }

    @Test("unsupported family retains a renderer diagnostic")
    func unsupportedFamilyFallsBack() async throws {
        let outcome = try await render(
            source: """
            gantt
                title Unsupported
                section Example
                Item :done, 2026-07-29, 1d
            """
        )

        switch outcome.failure {
        case .unsupported(let diagnostic), .renderFailed(let diagnostic):
            #expect(!diagnostic.isEmpty)
        default:
            Issue.record("expected gantt to be unsupported or fail rendering")
        }
    }

    private func render(source: String) async throws -> MermaidRenderOutcome {
        await BeautifulMermaidBackend().render(
            key: MermaidRenderKey(
                source: source,
                theme: MermaidDiagramTheme(
                    theme: try Theme.loadBundled(id: "cool-slate")
                ),
                scale: 2,
                profile: .full
            )
        )
    }
}
