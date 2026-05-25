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

    // MARK: - Folder icon lookup

    @Test func exactFolderNameMatchesResolve() {
        #expect(FileTypeIcon.folderInfo(name: ".github")?.symbol == "\u{EA84}")
        #expect(FileTypeIcon.folderInfo(name: ".vscode")?.symbol == "\u{E70C}")
        #expect(FileTypeIcon.folderInfo(name: "node_modules")?.symbol == "\u{E718}")
        #expect(FileTypeIcon.folderInfo(name: ".gradle")?.symbol == "\u{E660}")
        #expect(FileTypeIcon.folderInfo(name: ".git")?.symbol == "\u{E65D}")
        #expect(FileTypeIcon.folderInfo(name: ".gitlab")?.symbol == "\u{F296}")
        #expect(FileTypeIcon.folderInfo(name: ".docker")?.symbol == "\u{E650}")
        #expect(FileTypeIcon.folderInfo(name: "docker")?.symbol == "\u{E650}")
        #expect(FileTypeIcon.folderInfo(name: ".circleci")?.symbol == "\u{E63E}")
    }

    @Test func folderLookupIsCaseInsensitive() {
        #expect(FileTypeIcon.folderInfo(name: ".GitHub")?.symbol == "\u{EA84}")
        #expect(FileTypeIcon.folderInfo(name: ".GITHUB")?.symbol == "\u{EA84}")
        #expect(FileTypeIcon.folderInfo(name: "Node_Modules")?.symbol == "\u{E718}")
    }

    @Test func folderSuffixMatchesResolve() {
        #expect(FileTypeIcon.folderInfo(name: "Bleh.xcodeproj")?.symbol == "\u{E711}")
        #expect(FileTypeIcon.folderInfo(name: "Alas.xcworkspace")?.symbol == "\u{E711}")
        #expect(FileTypeIcon.folderInfo(name: "GhosttyKit.framework")?.symbol == "\u{E711}")
        #expect(FileTypeIcon.folderInfo(name: "My.app")?.symbol == "\u{E711}")
    }

    @Test func folderSuffixMatchesAreCaseInsensitive() {
        #expect(FileTypeIcon.folderInfo(name: "Foo.XCODEPROJ")?.symbol == "\u{E711}")
    }

    @Test func pathAwareFolderMatchesResolve() {
        #expect(FileTypeIcon.folderInfo(name: "resources", path: "src/main/resources")?.symbol == "\u{E256}")
        #expect(FileTypeIcon.folderInfo(name: "resources", path: "src/test/resources")?.symbol == "\u{E256}")
        #expect(FileTypeIcon.folderInfo(name: "resources", path: "server/src/main/resources")?.symbol == "\u{E256}")
        #expect(FileTypeIcon.folderInfo(name: "resources", path: "server\\src\\test\\resources")?.symbol == "\u{E256}")
    }

    @Test func pathAwareFolderMatchesRequireSegmentBoundary() {
        #expect(FileTypeIcon.folderInfo(name: "resources", path: "mysrc/main/resources") == nil)
        #expect(FileTypeIcon.folderInfo(name: "resources", path: "src/main/myresources") == nil)
        #expect(FileTypeIcon.folderInfo(name: "resources", path: "app/mysrc/test/resources") == nil)
    }

    @Test func plainResourcesFolderReturnsNil() {
        #expect(FileTypeIcon.folderInfo(name: "resources", path: "resources") == nil)
        #expect(FileTypeIcon.folderInfo(name: "resources") == nil)
    }

    @Test func genericFoldersReturnNil() {
        for name in ["src", "lib", "test", "tests", "__tests__", "build", "dist",
                     "public", "assets", "docs", "config", "scripts", "bin"] {
            #expect(FileTypeIcon.folderInfo(name: name) == nil, "Expected nil for \(name)")
        }
    }

    @Test func unsupportedFoldersReturnNil() {
        #expect(FileTypeIcon.folderInfo(name: ".husky") == nil)
        #expect(FileTypeIcon.folderInfo(name: "vendor") == nil)
    }

    @Test func folderInfoKindsAreCorrect() {
        #expect(FileTypeIcon.folderInfo(name: ".github")?.kind == .folderExact)
        #expect(FileTypeIcon.folderInfo(name: "Foo.xcodeproj")?.kind == .folderSuffix)
        #expect(FileTypeIcon.folderInfo(name: "resources", path: "src/main/resources")?.kind == .folderPath)
    }
}
