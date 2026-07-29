import Testing
@testable import Alas

@MainActor
@Suite("Mermaid render service")
struct MermaidRenderServiceTests {
    @Test("same-key requests share one backend render")
    func coalescesSameKey() async {
        let backend = FakeMermaidBackend(outcome: .failed(.unsupported("test")))
        let service = MermaidRenderService(backend: backend)
        let key = TestMermaid.key(source: "graph TD; A-->B")

        async let first = service.render(key: key)
        async let second = service.render(key: key)
        _ = await (first, second)

        #expect(await backend.renderCount == 1)
    }

    @Test("deterministic failures are cached")
    func cachesFailures() async {
        let backend = FakeMermaidBackend(outcome: .failed(.unsupported("test")))
        let service = MermaidRenderService(backend: backend)
        let key = TestMermaid.key(source: "graph TD; A-->B")

        _ = await service.render(key: key)
        _ = await service.render(key: key)

        #expect(await backend.renderCount == 1)
    }

    @Test("at most two distinct renders use the backend concurrently")
    func limitsConcurrentRenders() async {
        let backend = FakeMermaidBackend(outcome: .failed(.unsupported("test")))
        let service = MermaidRenderService(backend: backend)

        async let first = service.render(key: TestMermaid.key(source: "a"))
        async let second = service.render(key: TestMermaid.key(source: "b"))
        async let third = service.render(key: TestMermaid.key(source: "c"))
        async let fourth = service.render(key: TestMermaid.key(source: "d"))
        _ = await (first, second, third, fourth)

        #expect(await backend.renderCount == 4)
        #expect(await backend.maximumActiveCount == 2)
    }

    @Test("render identity changes for source, theme, scale, and profile")
    func completeKeyIdentity() {
        let base = TestMermaid.key(source: "graph TD; A-->B")
        #expect(base != TestMermaid.key(source: "graph TD; A-->C"))
        #expect(base != TestMermaid.key(source: base.source, accent: "#445566"))
        #expect(base != TestMermaid.key(source: base.source, scale: 1))
        #expect(base != TestMermaid.key(source: base.source, profile: .compact))
    }
}

@MainActor
enum TestMermaid {
    static func key(
        source: String,
        accent: String = "#336699",
        scale: Double = 2,
        profile: MermaidPresentationProfile = .full
    ) -> MermaidRenderKey {
        var theme = try! Theme.loadBundled(id: "cool-slate")
        theme.accentOverrideHex = accent
        return MermaidRenderKey(
            source: source,
            theme: MermaidDiagramTheme(theme: theme),
            scale: scale,
            profile: profile
        )
    }
}

actor FakeMermaidBackend: MermaidRenderingBackend {
    private let outcome: MermaidRenderOutcome
    private(set) var renderCount = 0
    private var activeCount = 0
    private(set) var maximumActiveCount = 0

    init(outcome: MermaidRenderOutcome) {
        self.outcome = outcome
    }

    func render(key: MermaidRenderKey) async -> MermaidRenderOutcome {
        renderCount += 1
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        try? await Task.sleep(nanoseconds: 20_000_000)
        activeCount -= 1
        return outcome
    }
}
