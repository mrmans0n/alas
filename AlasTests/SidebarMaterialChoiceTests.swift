import Testing
import Foundation
@testable import Alas

struct SidebarMaterialChoiceTests {
    @Test func noneIsACase() {
        #expect(SidebarMaterialChoice.allCases.contains(.none))
    }

    @Test func noneIsFirstCase() {
        // `.none` reads as the lowest-translucency option, so we want it
        // at the top of the picker.
        #expect(SidebarMaterialChoice.allCases.first == SidebarMaterialChoice.none)
    }

    @Test func noneHasReadableDisplayName() {
        #expect(SidebarMaterialChoice.none.displayName == "None — solid theme color")
    }

    @Test func noneReturnsNilForBothMaterials() {
        #expect(SidebarMaterialChoice.none.appKitMaterial == nil)
        #expect(SidebarMaterialChoice.none.swiftUIMaterial == nil)
    }

    @Test func codableRoundTripIncludesNone() throws {
        let data = try JSONEncoder().encode(SidebarMaterialChoice.none)
        let decoded = try JSONDecoder().decode(SidebarMaterialChoice.self, from: data)
        #expect(decoded == .none)
    }

    @Test func unknownRawValueDecodeFailsCleanly() {
        let json = "\"some-unknown-material\"".data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(SidebarMaterialChoice.self, from: json)
        }
    }
}
