import Testing
@testable import Alas

@MainActor
@Suite("Beautiful Mermaid smoke")
struct BeautifulMermaidSmokeTests {
    @Test(arguments: [
        "graph TD; A-->B",
        "stateDiagram-v2\n[*] --> Ready",
        "sequenceDiagram\nA->>B: Hello",
        "classDiagram\nAnimal <|-- Cat",
        "erDiagram\nCUSTOMER ||--o{ ORDER : places",
        "xychart-beta\nx-axis [a, b]\ny-axis 0 --> 2\nbar [1, 2]",
    ])
    func rendersSupportedFamily(_ source: String) async throws {
        let theme = MermaidDiagramTheme(
            theme: try Theme.loadBundled(id: "cool-slate")
        )
        let outcome = await BeautifulMermaidBackend().render(
            key: MermaidRenderKey(
                source: source,
                theme: theme,
                scale: 2,
                profile: .full
            )
        )

        guard case .rendered(let diagram) = outcome else {
            Issue.record("expected rendered diagram for \(source)")
            return
        }
        #expect(diagram.pixelSize.width > 0)
        #expect(diagram.pixelSize.height > 0)
    }
}
