import AppKit
import Foundation
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

    @Test func semanticDefaultUsesSystemFont() {
        let typography = ACPChatTypography(fontFamily: "", fontSize: 13)
        let font = typography.appKitFont()

        #expect(font.familyName == NSFont.systemFont(ofSize: 13).familyName)
        #expect(font.pointSize == 13)
    }

    @Test func missingFamilyFallsBackToSystemFont() {
        let typography = ACPChatTypography(
            fontFamily: "Missing Chat Font \(UUID().uuidString)",
            fontSize: 15
        )
        let font = typography.appKitFont()

        #expect(font.familyName == NSFont.systemFont(ofSize: 15).familyName)
        #expect(font.pointSize == 15)
    }
}
