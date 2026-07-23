import Testing
@testable import Alas

struct ImageFileTypeTests {
    @Test func recognizesSupportedExtensionsCaseInsensitively() {
        #expect(ImageFileType.isSupported(relativePath: "Assets/logo.PNG"))
        #expect(ImageFileType.isSupported(relativePath: "photo.Jpeg"))
        #expect(ImageFileType.isSupported(relativePath: "screenshots/preview.webp"))
        #expect(ImageFileType.isSupported(relativePath: "images/raw.HEIC"))
        #expect(ImageFileType.isSupported(relativePath: "scans/page.tiff"))
        #expect(ImageFileType.isSupported(relativePath: "Assets/icon.svg"))
    }

    @Test func recognizesOnlySvgAsTextBackedImage() {
        #expect(ImageFileType.isTextBacked(relativePath: "Assets/icon.svg"))
        #expect(ImageFileType.isTextBacked(relativePath: "Assets/icon.SVG"))
        #expect(!ImageFileType.isTextBacked(relativePath: "Assets/logo.png"))
        #expect(!ImageFileType.isTextBacked(relativePath: "photo.jpeg"))
    }

    @Test func rejectsNonImagePaths() {
        #expect(!ImageFileType.isSupported(relativePath: "Sources/AppState.swift"))
        #expect(!ImageFileType.isSupported(relativePath: "README.md"))
    }

    @Test func rejectsExtensionlessPaths() {
        #expect(!ImageFileType.isSupported(relativePath: "Makefile"))
        #expect(!ImageFileType.isSupported(relativePath: ".gitignore"))
    }

    @Test func recognizesAChangeWhenOnlyTheOriginalPathIsAnImage() {
        #expect(ImageFileType.isSupported(
            currentPath: "Assets/logo.bin",
            originalPath: "Assets/logo.png"
        ))
        #expect(ImageFileType.isSupported(
            currentPath: "Assets/logo.png",
            originalPath: "Assets/logo.bin"
        ))
        #expect(!ImageFileType.isSupported(
            currentPath: "Assets/logo.bin",
            originalPath: "Assets/logo.dat"
        ))
    }
}
