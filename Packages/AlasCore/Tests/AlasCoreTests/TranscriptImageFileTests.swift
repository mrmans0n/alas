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

    /// A prompt's attached images are staged on the Mac, so an SSH session
    /// reads them locally; anything else still resolves on the session's host.
    @Test(arguments: [
        ("file:///Support/acp-attachments/w1/shot%201.png", true),
        ("/Support/acp-attachments/w1/shot.png", true),
        ("file:///Support/acp-attachments/w1/../w2/shot.png", false),
        ("/Support/acp-attachments/w1", false),
        ("/tmp/shot.png", false),
        ("images/shot.png", false),
    ])
    func stagedAttachmentsReadOnThisMac(_ source: String, staged: Bool) {
        let attachments = URL(fileURLWithPath: "/Support/acp-attachments/w1")
        let sshRoot = URL(fileURLWithPath: "/.alas-remote/test-host/repo")
        let root = TranscriptImageFile.readRoot(for: source, worktreeRoot: sshRoot, attachments: attachments)
        #expect(root == (staged ? attachments : sshRoot))
        if staged {
            guard case .local? = TranscriptImageFile.resolve(source, root: root) else {
                Issue.record("\(source) should resolve on this Mac")
                return
            }
        }
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
