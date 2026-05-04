import Foundation

enum NumstatParser {
    /// Parses `git diff --numstat HEAD` output keyed by destination path.
    ///
    /// Renamed entries surface as either:
    ///   - simple form: `path/old => path/new`
    ///   - prefix form: `path/{old => new}/file`
    /// Both must normalize to the destination path so callers (status v2,
    /// which only knows the new path) can join counts back by exact match.
    static func parse(_ raw: String) -> [String: (add: Int, del: Int)] {
        var result: [String: (add: Int, del: Int)] = [:]
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3 else { continue }
            let add = Int(parts[0]) ?? 0
            let del = Int(parts[1]) ?? 0
            let path = destinationPath(from: String(parts[2]))
            result[path] = (add: add, del: del)
        }
        return result
    }

    /// If `raw` is a rename token, return the post-rename path; otherwise
    /// return it unchanged.
    static func destinationPath(from raw: String) -> String {
        // Brace form: `dir/{old => new}/file` → `dir/new/file`
        if let openBrace = raw.firstIndex(of: "{"),
           let arrow = raw.range(of: " => "),
           let closeBrace = raw[arrow.upperBound...].firstIndex(of: "}") {
            let prefix = raw[..<openBrace]
            let newName = raw[arrow.upperBound..<closeBrace]
            let suffix = raw[raw.index(after: closeBrace)...]
            return String(prefix) + String(newName) + String(suffix)
        }
        // Plain form: `old => new` → `new`
        if let arrow = raw.range(of: " => ") {
            return String(raw[arrow.upperBound...])
        }
        return raw
    }
}
