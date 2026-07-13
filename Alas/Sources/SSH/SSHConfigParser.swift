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
        // Directives are governed by the most recent Host/Match block. An
        // `Include` inside a conditional block (any `Host`/`Match` other than
        // the catch-all `Host *` / `Match all`) only applies when connecting
        // to a matching host, so those aliases are not usable top-level — we
        // skip them rather than offer hosts `ssh` would not resolve.
        var conditionalScope = false

        for rawLine in contents.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let line = stripInlineComment(trimmed)
            if line.isEmpty { continue }
            guard let (keyword, value) = splitKeyword(line) else { continue }

            switch keyword.lowercased() {
            case "host":
                stanza = []
                let tokens = tokenize(value)
                conditionalScope = tokens != ["*"]
                for token in tokens where isPlainAlias(token) {
                    guard !seenAliases.contains(token) else { continue }
                    seenAliases.insert(token)
                    hosts.append(SSHConfigHost(alias: token, hostName: nil, user: nil, port: nil))
                    stanza.append(hosts.count - 1)
                }
            case "match":
                stanza = []
                conditionalScope = tokenize(value).map { $0.lowercased() } != ["all"]
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
                if conditionalScope { continue }
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

    /// Removes an inline `# comment`. OpenSSH treats an unquoted `#` that
    /// starts a token as the beginning of a comment; we don't track quotes,
    /// so we strip from the first `#` at the start of the line or following
    /// whitespace (a mid-token `#`, e.g. `foo#bar`, is preserved).
    private static func stripInlineComment(_ line: String) -> String {
        var prevWasSpace = true   // start of line is a token boundary
        for (offset, scalar) in line.unicodeScalars.enumerated() {
            if scalar == "#" && prevWasSpace {
                let idx = line.unicodeScalars.index(line.unicodeScalars.startIndex, offsetBy: offset)
                return String(line.unicodeScalars[..<idx]).trimmingCharacters(in: .whitespaces)
            }
            prevWasSpace = (scalar == " " || scalar == "\t")
        }
        return line
    }

    /// Splits a directive value into arguments the way ssh_config does:
    /// single or double quotes group an argument containing spaces (and are
    /// removed — a quote of the other kind inside stays literal), and a
    /// backslash escapes a following space, tab, quote, or backslash (so
    /// `Application\ Support` stays one token). Other backslashes are kept.
    private static func tokenize(_ value: String) -> [String] {
        let chars = Array(value)
        var tokens: [String] = []
        var current = ""
        var hasToken = false
        var quoteChar: Character?
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\\", i + 1 < chars.count {
                let next = chars[i + 1]
                if next == " " || next == "\t" || next == "\"" || next == "'" || next == "\\" {
                    current.append(next)
                    hasToken = true
                    i += 2
                    continue
                }
            }
            if let open = quoteChar {
                if ch == open {
                    quoteChar = nil
                    hasToken = true
                    i += 1
                    continue
                }
            } else if ch == "\"" || ch == "'" {
                quoteChar = ch
                hasToken = true
                i += 1
                continue
            }
            if (ch == " " || ch == "\t") && quoteChar == nil {
                if hasToken {
                    tokens.append(current)
                    current = ""
                    hasToken = false
                }
                i += 1
                continue
            }
            current.append(ch)
            hasToken = true
            i += 1
        }
        if hasToken { tokens.append(current) }
        return tokens
    }

    private static func isPlainAlias(_ token: String) -> Bool {
        !token.isEmpty && !token.hasPrefix("!") && !token.contains("*") && !token.contains("?")
    }

    /// Resolves an `Include` pattern to concrete files. Globs are expanded in
    /// every path component (covers `config.d/*`, `config.d/*.conf`, and nested
    /// `config.d/*/*.conf`); intermediate components only descend into
    /// directories.
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
        guard !comps.isEmpty else { return [] }

        var current = [base]
        for (index, comp) in comps.enumerated() {
            let isLast = index == comps.count - 1
            if comp.contains("*") || comp.contains("?") {
                var next: [URL] = []
                for dir in current {
                    guard let entries = try? fileManager.contentsOfDirectory(atPath: dir.path) else { continue }
                    for name in entries.sorted() where fnmatch(comp, name, 0) == 0 {
                        let candidate = dir.appendingPathComponent(name)
                        if isLast {
                            next.append(candidate)
                        } else {
                            var isDir: ObjCBool = false
                            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                                next.append(candidate)
                            }
                        }
                    }
                }
                current = next
            } else {
                current = current.map { $0.appendingPathComponent(comp) }
            }
        }
        return current
    }
}
