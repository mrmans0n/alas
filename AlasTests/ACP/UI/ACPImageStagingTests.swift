import Foundation
import Testing
@testable import Alas

@Suite("ACPImageStaging")
struct ACPImageStagingTests {
    // A minimal valid 1x1 PNG.
    private var pngBytes: Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
    }

    @Test("sniffs png mime and writes a content-addressed file")
    func stagesPNG() throws {
        let staged = try ACPImageStaging.stage(data: pngBytes, into: "wt-test")
        #expect(staged.mimeType == "image/png")
        #expect(staged.url.pathExtension == "png")
        #expect(FileManager.default.fileExists(atPath: staged.url.path))
        try? FileManager.default.removeItem(at: staged.url)
    }

    @Test("identical bytes dedupe to the same path")
    func dedupes() throws {
        let a = try ACPImageStaging.stage(data: pngBytes, into: "wt-test")
        let b = try ACPImageStaging.stage(data: pngBytes, into: "wt-test")
        #expect(a.url == b.url)
        try? FileManager.default.removeItem(at: a.url)
    }

    @Test("rejects non-image bytes")
    func rejectsNonImage() {
        #expect(throws: ACPImageStaging.StagingError.self) {
            _ = try ACPImageStaging.stage(data: Data("not an image".utf8), into: "wt-test")
        }
    }

    @Test("rejects oversized images")
    func rejectsOversize() {
        var big = pngBytes
        big.append(Data(count: ACPImageStaging.maxBytes + 1))
        #expect(throws: ACPImageStaging.StagingError.self) {
            _ = try ACPImageStaging.stage(data: big, into: "wt-test")
        }
    }
}
