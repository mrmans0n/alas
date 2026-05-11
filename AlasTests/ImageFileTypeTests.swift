import Testing
@testable import Alas

struct ImageFileTypeTests {
    @Test func recognizesSupportedExtensionsCaseInsensitively() {
        #expect(ImageFileType.isSupported(relativePath: "Assets/logo.PNG"))
        #expect(ImageFileType.isSupported(relativePath: "photo.Jpeg"))
        #expect(ImageFileType.isSupported(relativePath: "screenshots/preview.webp"))
        #expect(ImageFileType.isSupported(relativePath: "images/raw.HEIC"))
        #expect(ImageFileType.isSupported(relativePath: "scans/page.tiff"))
    }

    @Test func rejectsSvgAndNonImagePaths() {
        #expect(!ImageFileType.isSupported(relativePath: "Assets/icon.svg"))
        #expect(!ImageFileType.isSupported(relativePath: "Sources/AppState.swift"))
        #expect(!ImageFileType.isSupported(relativePath: "README.md"))
    }

    @Test func rejectsExtensionlessPaths() {
        #expect(!ImageFileType.isSupported(relativePath: "Makefile"))
        #expect(!ImageFileType.isSupported(relativePath: ".gitignore"))
    }
}
