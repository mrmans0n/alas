import Testing
import Foundation
@testable import Alas

struct MergeConflictBinaryDetectionTests {
    @Test func imageExtensionsAreImages() {
        #expect(ImageFileType.isSupported(relativePath: "assets/cat.png"))
        #expect(ImageFileType.isSupported(relativePath: "logo.jpg"))
        #expect(ImageFileType.isSupported(relativePath: "icon.WEBP"))
    }

    @Test func nonImageBinariesAreNotImages() {
        #expect(!ImageFileType.isSupported(relativePath: "compiled/program"))
        #expect(!ImageFileType.isSupported(relativePath: "asset.bin"))
        #expect(!ImageFileType.isSupported(relativePath: "lib.so"))
    }
}
