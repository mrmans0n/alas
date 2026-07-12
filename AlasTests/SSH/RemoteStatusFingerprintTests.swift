import Testing
@testable import Alas

struct RemoteStatusFingerprintTests {
    @Test func firstObservationRefreshes() {
        let value = RemoteStatusFingerprint.make(status: "s", head: "h")
        #expect(RemoteStatusFingerprint.shouldRefresh(previous: nil, current: value))
    }
    @Test func changesRefresh() {
        let first = RemoteStatusFingerprint.make(status: "s", head: "h")
        #expect(!RemoteStatusFingerprint.shouldRefresh(previous: first, current: first))
        #expect(RemoteStatusFingerprint.shouldRefresh(previous: first, current: RemoteStatusFingerprint.make(status: "s2", head: "h")))
        #expect(RemoteStatusFingerprint.shouldRefresh(previous: first, current: RemoteStatusFingerprint.make(
            status: "s",
            head: "h",
            unstagedDiff: "diff"
        )))
        #expect(RemoteStatusFingerprint.shouldRefresh(previous: first, current: RemoteStatusFingerprint.make(
            status: "s",
            head: "h",
            stagedDiff: "cached"
        )))
        #expect(RemoteStatusFingerprint.shouldRefresh(previous: first, current: RemoteStatusFingerprint.make(
            status: "s",
            head: "h",
            untrackedContent: "blob"
        )))
    }

    @Test func remoteUntrackedContentCommandAvoidsShellNulReadExtensions() {
        let command = RightPaneState.remoteUntrackedContentFingerprintCommand
        #expect(command.contains("git ls-files --others --exclude-standard -z"))
        #expect(command.contains("xargs -0 sh -c"))
        #expect(command.contains("[ \"$#\" -gt 0 ] || exit 0"))
        #expect(command.contains("git hash-object -- \"$@\""))
        #expect(!command.contains("read -d"))
    }
}
