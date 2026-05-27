import Testing
@testable import Alas

@Suite
struct ZmxSessionNameTests {
    @Test
    func derivePrefixesLeafIdWithAlas() {
        let leafId = "61F2A8E0-2D9F-4B1F-9E5A-9C0B6C3F0F0F"
        #expect(ZmxSessionName.derive(leafId: leafId) == "alas-61F2A8E0-2D9F-4B1F-9E5A-9C0B6C3F0F0F")
    }

    @Test
    func deriveDoesNotMutateInput() {
        let leafId = "abc-123"
        _ = ZmxSessionName.derive(leafId: leafId)
        #expect(leafId == "abc-123")
    }
}
