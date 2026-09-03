import Testing
@testable import Alas

struct RemoteFileOpsTests {
    @Test func moveCommandCreatesParentAndMoves() {
        #expect(RemoteFileOps.moveCommand(
            from: "/srv/repo/a.txt", to: "/srv/repo/sub dir/b.txt"
        ) == "mkdir -p '/srv/repo/sub dir' && [ ! -e '/srv/repo/sub dir/b.txt' ] && [ ! -L '/srv/repo/sub dir/b.txt' ] && mv '/srv/repo/a.txt' '/srv/repo/sub dir/b.txt'")
    }

    @Test func mkdirCommandTargetsParent() {
        #expect(RemoteFileOps.mkdirCommand(parentOf: "/srv/repo/x/y.txt") == "mkdir -p '/srv/repo/x'")
    }

    @Test func removeCommandQuotesPathAndAvoidsGNUSeparator() {
        #expect(RemoteFileOps.removeCommand(path: "/srv/repo/a b.txt") == "p='/srv/repo/a b.txt'; rm -rf \"$p\"")
    }

    @Test func createEmptyFileCommandCreatesParentAndDoesNotClobber() {
        #expect(RemoteFileOps.createEmptyFileCommand(
            path: "/srv/repo/sub dir/new.txt"
        ) == "mkdir -p '/srv/repo/sub dir' && f='/srv/repo/sub dir/new.txt' && [ ! -e \"$f\" ] && [ ! -L \"$f\" ] && (set -C; : > \"$f\")")
    }

    @Test func createDirectoryCommandDoesNotClobber() {
        #expect(RemoteFileOps.createDirectoryCommand(
            path: "/srv/repo/sub dir/new folder"
        ) == "d='/srv/repo/sub dir/new folder'; [ ! -e \"$d\" ] && [ ! -L \"$d\" ] && mkdir \"$d\"")
    }
}
