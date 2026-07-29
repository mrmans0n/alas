import Testing
@testable import Alas

@Suite("Mermaid models")
struct MermaidModelsTests {
    @Test("recognizes only the first mermaid fence token")
    func fenceRecognition() {
        #expect(MermaidFence.isMermaid(language: "mermaid"))
        #expect(MermaidFence.isMermaid(language: "MERMAID title=Architecture"))
        #expect(!MermaidFence.isMermaid(language: "swift mermaid"))
        #expect(!MermaidFence.isMermaid(language: nil))
        #expect(!MermaidFence.isMermaid(language: ""))
    }

    @Test("profiles lock the approved height caps")
    func profileHeights() {
        #expect(MermaidPresentationProfile.full.maxEmbeddedHeight == 640)
        #expect(MermaidPresentationProfile.transcript.maxEmbeddedHeight == 420)
        #expect(MermaidPresentationProfile.compact.maxEmbeddedHeight == 180)
    }
}
