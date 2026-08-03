import Testing
@testable import Alas

@Suite("ACPTranscriptScrollerFlag")
struct ACPTranscriptScrollerFlagTests {
    @Test("explicit override wins in both build types")
    func overrideWins() {
        #expect(ACPTranscriptScrollerFlag.resolve(override: true, isDebugBuild: false) == true)
        #expect(ACPTranscriptScrollerFlag.resolve(override: false, isDebugBuild: true) == false)
    }

    @Test("no override: on for debug builds, off for release")
    func defaults() {
        #expect(ACPTranscriptScrollerFlag.resolve(override: nil, isDebugBuild: true) == true)
        #expect(ACPTranscriptScrollerFlag.resolve(override: nil, isDebugBuild: false) == false)
    }
}
