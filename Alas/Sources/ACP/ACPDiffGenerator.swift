import Foundation

enum ACPDiffGenerator {
    static func generate(oldText: String?, newText: String) async throws -> ParsedDiff {
        let old = oldText ?? ""
        let new = newText

        if old.isEmpty && new.isEmpty {
            return ParsedDiff(hunks: [])
        }

        if oldText == nil {
            var lines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if let last = lines.last, last.isEmpty { _ = lines.popLast() }
            let hunkLines = lines.enumerated().map { (i, text) in
                ParsedDiff.Hunk.Line(
                    kind: .add,
                    text: text,
                    oldNumber: nil,
                    newNumber: i + 1
                )
            }
            let hunk = ParsedDiff.Hunk(
                header: "@@ -0,0 +1,\(lines.count) @@",
                oldStart: 0,
                newStart: 1,
                lines: hunkLines
            )
            return ParsedDiff(hunks: [hunk])
        }

        if old == new {
            return ParsedDiff(hunks: [])
        }

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("acp-diff-\(UUID())")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let oldPath = tmpDir.appendingPathComponent("a")
        let newPath = tmpDir.appendingPathComponent("b")
        try old.write(to: oldPath, atomically: true, encoding: .utf8)
        try new.write(to: newPath, atomically: true, encoding: .utf8)

        let result = try await Process.git(
            ["diff", "--no-index", "--", oldPath.path, newPath.path],
            cwd: tmpDir
        )
        return DiffParser.parse(result.stdout)
    }
}
