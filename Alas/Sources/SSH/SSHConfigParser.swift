import Foundation
import Darwin

/// One selectable host alias parsed from `~/.ssh/config`.
struct SSHConfigHost: Identifiable, Equatable {
    let alias: String
    var hostName: String?
    var user: String?
    var port: Int?
    var id: String { alias }
}

/// Parses `~/.ssh/config` into pickable host aliases. Read-only, no side effects.
enum SSHConfigParser {
    private static let maxIncludeDepth = 16

    static func parse(
        home: URL,
        configPath: URL? = nil,
        fileManager: FileManager = .default
    ) -> [SSHConfigHost] {
        let root = configPath ?? home.appendingPathComponent(".ssh/config")
        var hosts: [SSHConfigHost] = []
        var seenAliases = Set<String>()
        var visitedFiles = Set<String>()
        parseFile(root, home: home, fileManager: fileManager,
                  hosts: &hosts, seenAliases: &seenAliases,
                  visitedFiles: &visitedFiles, depth: 0)
        return hosts
    }

    private static func parseFile(
        _ url: URL,
        home: URL,
        fileManager: FileManager,
        hosts: inout [SSHConfigHost],
        seenAliases: inout Set<String>,
        visitedFiles: inout Set<String>,
        depth: Int
    ) {
        guard depth <= maxIncludeDepth else { return }
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard !visitedFiles.contains(canonical) else { return }
        visitedFiles.insert(canonical)

        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }

        var stanza: [Int] = []   // indices into `hosts` for the current Host stanza

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let (keyword, value) = splitKeyword(line) else { continue }

            switch keyword.lowercased() {
            case "host":
                stanza = []
                for token in tokenize(value) where isPlainAlias(token) {
                    guard !seenAliases.contains(token) else { continue }
                    seenAliases.insert(token)
                    hosts.append(SSHConfigHost(alias: token, hostName: nil, user: nil, port: nil))
                    stanza.append(hosts.count - 1)
                }
            case "hostname":
                if let v = tokenize(value).first {
                    for i in stanza where hosts[i].hostName == nil { hosts[i].hostName = v }
                }
            case "user":
                if let v = tokenize(value).first {
                    for i in stanza where hosts[i].user == nil { hosts[i].user = v }
                }
            case "port":
                if let v = tokenize(value).first, let p = Int(v) {
                    for i in stanza where hosts[i].port == nil { hosts[i].port = p }
                }
            case "include":
                for pattern in tokenize(value) {
                    for file in expandInclude(pattern, home: home, fileManager: fileManager) {
                        parseFile(file, home: home, fileManager: fileManager,
                                  hosts: &hosts, seenAliases: &seenAliases,
                                  visitedFiles: &visitedFiles, depth: depth + 1)
                    }
                }
            default:
                continue
            }
        }
    }

    /// Splits "Keyword value" or "Keyword=value"; nil for blank keywords.
    private static func splitKeyword(_ line: String) -> (String, String)? {
        let scalars = Array(line.unicodeScalars)
        let isSep: (Unicode.Scalar) -> Bool = { $0 == " " || $0 == "\t" || $0 == "=" }
        guard let sep = scalars.firstIndex(where: isSep) else {
            return line.isEmpty ? nil : (line, "")
        }
        let key = String(String.UnicodeScalarView(scalars[..<sep]))
        var rest = scalars[scalars.index(after: sep)...]
        while let first = rest.first, isSep(first) { rest = rest.dropFirst() }
        let value = String(String.UnicodeScalarView(rest))
        return key.isEmpty ? nil : (key, value)
    }

    private static func tokenize(_ value: String) -> [String] {
        value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    private static func isPlainAlias(_ token: String) -> Bool {
        !token.isEmpty && !token.hasPrefix("!") && !token.contains("*") && !token.contains("?")
    }

    /// Resolves an `Include` pattern to concrete files. Supports a glob only in
    /// the final path component (covers `config.d/*`, `config.d/*.conf`).
    private static func expandInclude(
        _ pattern: String, home: URL, fileManager: FileManager
    ) -> [URL] {
        var relative = pattern
        var base: URL
        if relative.hasPrefix("~/") {
            base = home
            relative = String(relative.dropFirst(2))
        } else if relative.hasPrefix("/") {
            base = URL(fileURLWithPath: "/")
            relative = String(relative.dropFirst())
        } else {
            base = home.appendingPathComponent(".ssh")   // user-config relative Includes → ~/.ssh
        }
        let comps = relative.split(separator: "/").map(String.init)
        guard let last = comps.last else { return [] }
        let dir = comps.dropLast().reduce(base) { $0.appendingPathComponent($1) }
        if last.contains("*") || last.contains("?") {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return [] }
            return entries.sorted()
                .filter { fnmatch(last, $0, 0) == 0 }
                .map { dir.appendingPathComponent($0) }
        }
        return [dir.appendingPathComponent(last)]
    }
}
