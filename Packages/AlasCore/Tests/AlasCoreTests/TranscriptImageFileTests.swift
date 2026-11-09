import Foundation
import Testing
@testable import AlasPlatform

struct TranscriptImageFileTests {
    @Test(arguments: ["/tmp/shot.png", "file:///tmp/shot.png", "../shot.png", "images/shot.png"])
    func pathsResolveOnSessionHost(_ source: String) {
        let localRoot = URL(fileURLWithPath: "/repo")
        let sshRoot = URL(fileURLWithPath: "/.alas-remote/test-host/repo")
        let expected = source == "images/shot.png" ? "/repo/images/shot.png"
            : source == "../shot.png" ? "/shot.png" : "/tmp/shot.png"
        #expect(TranscriptImageFile.resolve(source, root: localRoot) == .local(URL(fileURLWithPath: expected)))
        #expect(TranscriptImageFile.resolve(source, root: sshRoot) == .ssh(host: "test-host", path: expected))
    }

    @Test(arguments: ["https://example.com/shot.png", "file://other-host/tmp/shot.png", "", "/.alas-remote/other/tmp/shot.png"])
    func invalidSourcesDoNotReadLocalDisk(_ source: String) {
        #expect(TranscriptImageFile.resolve(source, root: URL(fileURLWithPath: "/.alas-remote/test-host/repo")) == nil)
    }

    @Test func localReadsAreBounded() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("image-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let bytes = Data([137, 80, 78, 71])
        try bytes.write(to: file)
        let read = await TranscriptImageFile.read(file.path, root: file.deletingLastPathComponent(), maxBytes: 4)
        #expect(read == bytes)
        let oversized = await TranscriptImageFile.read(file.path, root: file.deletingLastPathComponent(), maxBytes: 3)
        #expect(oversized == nil)
    }
}
