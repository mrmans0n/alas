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
}
