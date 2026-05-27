import Testing
@testable import Alas

@Suite
struct ZmxSunPathBudgetTests {
    /// Longest socket basename we ever produce:
    ///   "alas-" + UUID() + ".sock" = 5 + 36 + 5 = 46 chars
    /// Plus the path separator after the directory = 47 chars overhead.
    /// sun_path holds 104 bytes including the NUL terminator, so usable
    /// path is 103 bytes — budget allows directories up to 103 - 47 = 56 chars.

    @Test
    func fitsShortTmpPath() {
        #expect(ZmxSunPathBudget.fits(dir: "/tmp/alas-zmx-501") == true)
    }

    @Test
    func fitsExactBoundary() {
        // 56 chars exactly should fit (leaving 1 byte for the NUL terminator).
        let dir = String(repeating: "a", count: 56)
        #expect(dir.count == 56)
        #expect(ZmxSunPathBudget.fits(dir: dir) == true)
    }

    @Test
    func rejectsOneOverBoundary() {
        // 57 chars would consume all 104 sun_path bytes, leaving no room
        // for the NUL terminator that `bind(2)` requires.
        let dir = String(repeating: "a", count: 57)
        #expect(ZmxSunPathBudget.fits(dir: dir) == false)
    }

    @Test
    func rejectsLongUserCachesPath() {
        // A long username pushes ~/Library/Caches/io.nlopez.alas/zmx past the budget.
        let dir = "/Users/jonathandoeextra-developer/Library/Caches/io.nlopez.alas/zmx"
        #expect(ZmxSunPathBudget.fits(dir: dir) == false)
    }
}
