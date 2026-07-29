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
}
