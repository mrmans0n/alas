import Testing
import AlasModel

struct ChangedFileTests {
    /// A rename git reported without its origin acts on the new path alone,
    /// rather than inventing one.
    @Test(arguments: [nil, ""] as [String?])
    func aRenameWithoutItsOriginIsOnePath(_ renameFrom: String?) {
        let file = ChangedFile(path: "b.txt", status: "R", stage: .staged, add: 0, del: 0, renameFrom: renameFrom)
        #expect(file.gitPaths == ["b.txt"])
    }
}
