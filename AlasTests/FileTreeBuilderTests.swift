import Testing
@testable import Alas

struct FileTreeBuilderTests {
    @Test func buildsNestedTree() {
        let paths = ["a/b/c.rs", "a/d.rs", "e.txt"]
        let badges = ["a/b/c.rs": "M"]
        let tree = FileTreeBuilder.build(paths: paths, badges: badges)
        #expect(tree.count == 2)
        let aDir = tree.first { $0.name == "a" }!
        #expect(aDir.kind == .dir)
        #expect(aDir.children?.count == 2)
        let bDir = aDir.children!.first { $0.name == "b" }!
        let cFile = bDir.children!.first { $0.name == "c.rs" }!
        #expect(cFile.badge == "M")
    }
}
