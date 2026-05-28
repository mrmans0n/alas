import Testing
@testable import Alas

@Suite
struct ZmxSunPathBudgetTests {
    /// Longest socket basename we ever produce:
    ///   "alas-" + 16-char worktree hash + "-" + 16-char leaf hash + ".sock" = 43 chars
    /// Plus the path separator after the directory = 44 chars overhead.
    /// sun_path holds 104 bytes including the NUL terminator, so usable
    /// path is 103 bytes — budget allows directories up to 103 - 44 = 59 chars.

    @Test
    func fitsShortTmpPath() {
        #expect(ZmxSunPathBudget.fits(dir: "/tmp/alas-zmx-501") == true)
    }

    @Test
    func fitsExactBoundary() {
        // 59 chars exactly should fit (leaving 1 byte for the NUL terminator).
        let dir = String(repeating: "a", count: 59)
        #expect(dir.count == 59)
        #expect(ZmxSunPathBudget.fits(dir: dir) == true)
    }

    @Test
    func rejectsOneOverBoundary() {
        // 60 chars would consume all 104 sun_path bytes, leaving no room
        // for the NUL terminator that `bind(2)` requires.
        let dir = String(repeating: "a", count: 60)
        #expect(ZmxSunPathBudget.fits(dir: dir) == false)
    }

    @Test
    func rejectsLongUserCachesPath() {
        // A long username pushes ~/Library/Caches/io.nlopez.alas/zmx past the budget.
        let dir = "/Users/jonathandoeextra-developer/Library/Caches/io.nlopez.alas/zmx"
        #expect(ZmxSunPathBudget.fits(dir: dir) == false)
    }
}
