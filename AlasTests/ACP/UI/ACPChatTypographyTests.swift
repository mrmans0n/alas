import Testing
@testable import Alas

@Suite("ACP chat typography")
struct ACPChatTypographyTests {
    @Test func clampsBaseSize() {
        #expect(ACPChatTypography(fontFamily: "", fontSize: 2).baseSize == 8)
        #expect(ACPChatTypography(fontFamily: "", fontSize: 200).baseSize == 64)
    }

    @Test func derivesReadableSizesFromBaseSize() {
        let typography = ACPChatTypography(fontFamily: "SF Mono", fontSize: 14)

        #expect(typography.baseSize == 14)
        #expect(typography.paragraphSize == 14.5)
        #expect(typography.quoteSize == 14)
        #expect(typography.codeSize == 13)
        #expect(typography.tableBodySize == 13)
        #expect(typography.tableHeaderSize == 12.5)
        #expect(typography.labelSize == 11)
    }

    @Test func derivesHeadingSizesFromBaseSize() {
        let typography = ACPChatTypography(fontFamily: "SF Mono", fontSize: 13)

        #expect(typography.headingSize(level: 1) == 19)
        #expect(typography.headingSize(level: 2) == 17)
        #expect(typography.headingSize(level: 3) == 15)
        #expect(typography.headingSize(level: 4) == 14)
        #expect(typography.headingSize(level: 99) == 14)
    }
}
