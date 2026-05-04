import Testing
@testable import Alas

struct NumstatParserTests {
    @Test func parsesAddDelByPath() throws {
        let raw = """
        12\t3\tsrc/foo.rs
        0\t24\tsrc/bar.rs
        -\t-\tassets/binary.png
        """
        let map = NumstatParser.parse(raw)
        #expect(map["src/foo.rs"]?.add == 12)
        #expect(map["src/foo.rs"]?.del == 3)
        #expect(map["src/bar.rs"]?.del == 24)
        #expect(map["assets/binary.png"]?.add == 0)
    }

    @Test func parsesPlainRenameToDestination() {
        let raw = "5\t2\told/path.rs => new/path.rs"
        let map = NumstatParser.parse(raw)
        #expect(map["new/path.rs"]?.add == 5)
        #expect(map["new/path.rs"]?.del == 2)
        // Should NOT be keyed by the raw rename string.
        #expect(map["old/path.rs => new/path.rs"] == nil)
    }

    @Test func parsesBraceRenameToDestination() {
        let raw = "1\t0\tsrc/{old => new}/file.swift"
        let map = NumstatParser.parse(raw)
        #expect(map["src/new/file.swift"]?.add == 1)
        #expect(map["src/{old => new}/file.swift"] == nil)
    }
}
