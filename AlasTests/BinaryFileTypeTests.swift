import Foundation
import Testing
@testable import Alas

@Suite struct BinaryFileTypeTests {
    @Test func knownBinaryExtensions() {
        #expect(BinaryFileType.isKnownBinary(relativePath: "foo.pdf"))
        #expect(BinaryFileType.isKnownBinary(relativePath: "foo.ZIP"))
        #expect(BinaryFileType.isKnownBinary(relativePath: "a/b/movie.mp4"))
        #expect(BinaryFileType.isKnownBinary(relativePath: "app.exe"))
        #expect(BinaryFileType.isKnownBinary(relativePath: "lib.dylib"))
    }

    @Test func nonBinaryExtensions() {
        #expect(!BinaryFileType.isKnownBinary(relativePath: "foo.swift"))
        #expect(!BinaryFileType.isKnownBinary(relativePath: "foo.png"))
        #expect(!BinaryFileType.isKnownBinary(relativePath: "README.md"))
        #expect(!BinaryFileType.isKnownBinary(relativePath: "Makefile"))
    }

    @Test func noExtensionIsNotKnownBinary() {
        #expect(!BinaryFileType.isKnownBinary(relativePath: "bin/run"))
        #expect(!BinaryFileType.isKnownBinary(relativePath: "executable"))
    }
}
