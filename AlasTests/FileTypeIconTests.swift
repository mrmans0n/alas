import Testing
@testable import Alas

struct FileTypeIconTests {
    @Test func extensionLookupReturnsRustEntry() {
        let info = FileTypeIcon.info(for: "tab_bar.rs")
        #expect(info.label == "rs")
        #expect(info.hex == "D97558")
        #expect(info.kind == .ext)
    }

    @Test func extensionLookupIsCaseInsensitive() {
        let info = FileTypeIcon.info(for: "Main.SWIFT")
        #expect(info.label == "swift")
        #expect(info.hex == "F05138")
    }

    @Test func filenameOverrideBeatsExtension() {
        // cargo.toml should resolve to the Rust override, not the generic .toml entry.
        let info = FileTypeIcon.info(for: "Cargo.toml")
        #expect(info.label == "rs")
        #expect(info.hex == "D97558")
        #expect(info.kind == .filename)
    }

    @Test func unknownExtensionFallsBackToGrayTileWithTruncatedExt() {
        let info = FileTypeIcon.info(for: "weird.zzz")
        #expect(info.label == "zzz")
        #expect(info.kind == .fallbackExt)
    }

    @Test func unknownExtensionTruncatesToThreeChars() {
        let info = FileTypeIcon.info(for: "thing.abcdef")
        #expect(info.label == "abc")
        #expect(info.kind == .fallbackExt)
    }

    @Test func fileWithNoExtensionReturnsGenericMarker() {
        let info = FileTypeIcon.info(for: "Makefile")
        #expect(info.kind == .generic)
    }

    @Test func dotfileWithKnownNameMatchesFilename() {
        let info = FileTypeIcon.info(for: ".gitignore")
        #expect(info.label == "git")
        #expect(info.kind == .filename)
    }

    @Test func dotfileWithUnknownNameIsGeneric() {
        // ".something" — leading dot means lowercased == ".something",
        // no filename override, no extension to split on. Treat as generic.
        let info = FileTypeIcon.info(for: ".unknownrc")
        #expect(info.kind == .generic)
    }
}
