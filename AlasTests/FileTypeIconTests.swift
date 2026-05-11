import Testing
@testable import Alas

struct FileTypeIconTests {
    @Test func extensionLookupReturnsRustEntry() {
        let info = FileTypeIcon.info(for: "tab_bar.rs")
        #expect(info.symbol == "\u{E68B}")
        #expect(info.hex == "D97558")
        #expect(info.kind == .ext)
        #expect(info.style == .nerdFont)
    }

    @Test func extensionLookupIsCaseInsensitive() {
        let info = FileTypeIcon.info(for: "Main.SWIFT")
        #expect(info.symbol == "\u{E699}")
        #expect(info.hex == "F05138")
    }

    @Test func filenameOverrideBeatsExtension() {
        // cargo.toml should resolve to the Rust override, not the generic .toml entry.
        let info = FileTypeIcon.info(for: "Cargo.toml")
        #expect(info.symbol == "\u{E68B}")
        #expect(info.hex == "D97558")
        #expect(info.kind == .filename)
    }

    @Test func unknownExtensionFallsBackToGrayTileWithTruncatedExt() {
        let info = FileTypeIcon.info(for: "weird.zzz")
        #expect(info.symbol == "zzz")
        #expect(info.kind == .fallbackExt)
        #expect(info.style == .text)
    }

    @Test func unknownExtensionTruncatesToThreeChars() {
        let info = FileTypeIcon.info(for: "thing.abcdef")
        #expect(info.symbol == "abc")
        #expect(info.kind == .fallbackExt)
    }

    @Test func fileWithNoExtensionReturnsGenericMarker() {
        let info = FileTypeIcon.info(for: "Makefile")
        #expect(info.kind == .filename)
        #expect(info.symbol == "\u{E673}")
    }

    @Test func dotfileWithKnownNameMatchesFilename() {
        let info = FileTypeIcon.info(for: ".gitignore")
        #expect(info.symbol == "\u{E65D}")
        #expect(info.kind == .filename)
    }

    @Test func dotfileWithUnknownNameIsGeneric() {
        // ".something" — leading dot means lowercased == ".something",
        // no filename override, no extension to split on. Treat as generic.
        let info = FileTypeIcon.info(for: ".unknownrc")
        #expect(info.kind == .generic)
        #expect(info.symbol == "\u{F15B}")
        #expect(info.style == .nerdFont)
    }

    @Test func popularLanguagesUseNerdFontGlyphs() {
        #expect(FileTypeIcon.info(for: "Main.kt").symbol == "\u{E634}")
        #expect(FileTypeIcon.info(for: "App.java").symbol == "\u{E256}")
        #expect(FileTypeIcon.info(for: "server.ts").symbol == "\u{E628}")
        #expect(FileTypeIcon.info(for: "component.jsx").symbol == "\u{E625}")
        #expect(FileTypeIcon.info(for: "Dockerfile").symbol == "\u{E650}")
    }

    @Test func markdownAndJSONUseIconGlyphsInsteadOfTextLabels() {
        #expect(FileTypeIcon.info(for: "README.md").symbol == "\u{F48A}")
        #expect(FileTypeIcon.info(for: "package.json").symbol == "\u{E616}")
        #expect(FileTypeIcon.info(for: "data.json").symbol == "\u{E60B}")
    }

    @Test func supplementaryPlaneGlyphsResolveThroughCoreTextPathBuilder() {
        let terraform = FileTypeIcon.info(for: "main.tf")
        #expect(terraform.symbol == "\u{F1062}")
        #expect(NerdFontGlyphPath.path(for: terraform.symbol) != nil)
    }

    @Test func cFamilyExtensionsKeepExplicitMappings() {
        #expect(FileTypeIcon.info(for: "main.c").symbol == "\u{E649}")
        #expect(FileTypeIcon.info(for: "foo.h").symbol == "\u{E649}")
        #expect(FileTypeIcon.info(for: "widget.cpp").symbol == "\u{E646}")
        #expect(FileTypeIcon.info(for: "view.hpp").symbol == "\u{E646}")
    }
}
