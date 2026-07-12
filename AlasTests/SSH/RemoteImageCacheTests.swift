import Foundation
import Testing
@testable import Alas

struct RemoteImageCacheTests {
    @Test func trustedRemotePathAcceptsFileURLAndRelativePath() {
        let root = URL(fileURLWithPath: "/srv/repo")

        #expect(
            ACPToolCallCard.trustedRemotePath(
                from: "file:///srv/repo/shot.png",
                trustedRoot: root
            ) == "/srv/repo/shot.png"
        )
        #expect(
            ACPToolCallCard.trustedRemotePath(
                from: "assets/shot.png",
                trustedRoot: root
            ) == "/srv/repo/assets/shot.png"
        )
    }

    @Test func trustedRemotePathRejectsEscapesAndNonFileSchemes() {
        let root = URL(fileURLWithPath: "/srv/repo")

        #expect(ACPToolCallCard.trustedRemotePath(from: "https://x/y.png", trustedRoot: root) == nil)
        #expect(ACPToolCallCard.trustedRemotePath(from: "../secrets.png", trustedRoot: root) == nil)
        #expect(ACPToolCallCard.trustedRemotePath(from: "/etc/passwd", trustedRoot: root) == nil)
    }
}
