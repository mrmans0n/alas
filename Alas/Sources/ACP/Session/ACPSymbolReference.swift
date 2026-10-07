import CryptoKit
import Foundation

/// A code symbol the user attached to a prompt from the `@` picker.
///
/// Like `ACPSessionReference`, it rides the mention pipeline as a resource
/// link (`alas-symbol://symbol?path=…`), so chips, drafts, the queue, and the
/// recorded message treat it like a file mention. Just before sending, the
/// symbol is found again in its file and the link is replaced on the wire by
/// a reference line and, when requested, the declaration's code. Agents never
/// see the `alas-symbol` scheme.
enum ACPSymbolReference {
    static let scheme = "alas-symbol"
    /// Upper bound for parsed line numbers, so `+ 1` and range counting
    /// can never overflow on a crafted link.
    static let maxLineNumber = 10_000_000

    struct Target: Equatable, Hashable, Sendable {
        let path: String
        let name: String
        let kind: SymbolKind
        let container: String?
        /// 0-based, inclusive, at insertion time.
        let lineRange: ClosedRange<Int>
        var includeCode: Bool

        init(path: String, name: String, kind: SymbolKind, container: String?,
             lineRange: ClosedRange<Int>, includeCode: Bool) {
            self.path = path
            self.name = name
            self.kind = kind
            self.container = container
            self.lineRange = lineRange
            self.includeCode = includeCode
        }

        init(entry: SymbolEntry, includeCode: Bool) {
            self.init(path: entry.relativePath, name: entry.name, kind: entry.kind,
                      container: entry.container, lineRange: entry.lineRange, includeCode: includeCode)
        }

        var qualifiedName: String { container.map { "\($0).\(name)" } ?? name }
        var displayName: String { kind.isCallable ? qualifiedName + "()" : qualifiedName }
    }

    static func uri(for target: Target) -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "symbol"
        var items = [
            URLQueryItem(name: "path", value: target.path),
            URLQueryItem(name: "name", value: target.name),
            URLQueryItem(name: "kind", value: target.kind.rawValue),
            URLQueryItem(name: "start", value: String(target.lineRange.lowerBound)),
            URLQueryItem(name: "end", value: String(target.lineRange.upperBound)),
        ]
        if let container = target.container { items.append(URLQueryItem(name: "container", value: container)) }
        if target.includeCode { items.append(URLQueryItem(name: "code", value: "1")) }
        components.queryItems = items
        return components.string ?? "\(scheme)://symbol"
    }

    static func target(fromURI uri: String) -> Target? {
        // URI schemes are case-insensitive; Foundation keeps the original case.
        guard let components = URLComponents(string: uri), components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == "symbol" else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] { values[item.name] = item.value }
        guard let path = values["path"], SymbolSource.isSafeRelativePath(path),
              let name = values["name"], !name.isEmpty,
              let kind = values["kind"].flatMap(SymbolKind.init(rawValue:)),
              let start = values["start"].flatMap(Int.init),
              let end = values["end"].flatMap(Int.init),
              start >= 0, end >= start, end <= maxLineNumber else { return nil }
        return Target(path: path, name: name, kind: kind, container: values["container"],
                      lineRange: start...end, includeCode: values["code"] == "1")
    }

    static let maxExcerptLines = 400
    static let maxExcerptBytes = 32 * 1024

    struct Resolution: Equatable, Sendable {
        let target: Target
        let found: Bool
        /// Current range when found; the stored one otherwise.
        let lineRange: ClosedRange<Int>
        /// Full declaration text, uncapped. Nil when not found.
        let declaration: String?
    }

    struct Excerpt: Equatable {
        let text: String
        let shownLines: Int
        let totalLines: Int
        let truncated: Bool
    }

    /// A prompt's symbol mentions, resolved and rendered. Built off the main
    /// actor, so sending only swaps blocks and stamps attachments.
    struct Expansion: Equatable, Sendable {
        /// What was sent for each symbol link, for its recorded attachment.
        var snapshots: [String: ACPSymbolSnapshot] = [:]
        /// The blocks the agent gets in place of each symbol link.
        var replacements: [String: [ACPContentBlock]] = [:]
        /// Every block sent in place of a symbol link.
        var sentBlocks: [ACPContentBlock] { replacements.values.flatMap { $0 } }
    }

    /// Expands every symbol link in `blocks`, once per URI, off the main
    /// actor. Each file is read once per pass, however many mentions it has.
    static func expansion(of blocks: [ACPContentBlock], worktreeRoot: URL, embeddedContext: Bool) async -> Expansion {
        var sources: [String: String] = [:]
        var read: Set<String> = []
        for case .resourceLink(let uri, _) in blocks {
            guard let path = target(fromURI: uri)?.path, read.insert(path).inserted else { continue }
            sources[path] = await SymbolSource.read(root: worktreeRoot, relativePath: path)
        }
        return expansion(of: blocks, sources: sources, worktreeRoot: worktreeRoot, embeddedContext: embeddedContext)
    }

    /// `sources` maps each mentioned file's worktree-relative path to its
    /// text; a file missing from it could not be read. Each resolved link
    /// becomes its reference text, followed by the declaration when the
    /// user included code: a `resource` block when the agent accepts
    /// embedded context, otherwise a fenced block in the same text.
    static func expansion(
        of blocks: [ACPContentBlock], sources: [String: String], worktreeRoot: URL, embeddedContext: Bool
    ) -> Expansion {
        var expansion = Expansion()
        for case .resourceLink(let uri, let name) in blocks where expansion.replacements[uri] == nil {
            guard let target = target(fromURI: uri) else {
                // A symbol link that failed validation never reaches the agent.
                if uri.lowercased().hasPrefix("\(scheme):") {
                    expansion.replacements[uri] = [.text("Referenced symbol: \(name ?? "unknown") (unreadable link; not sent).")]
                }
                continue
            }
            let resolution = resolve(target, source: sources[target.path])
            let declaration = resolution.found ? resolution.declaration : nil
            let excerpt = target.includeCode ? declaration.map(Self.excerpt) : nil
            expansion.snapshots[uri] = ACPSymbolSnapshot(
                lineRange: resolution.lineRange,
                contentHash: declaration.map(Self.contentHash(of:)) ?? "",
                excerpt: excerpt?.text, truncated: excerpt?.truncated ?? false, found: resolution.found)
            let reference = referenceText(for: resolution)
            guard let code = excerpt?.text else {
                expansion.replacements[uri] = [.text(reference)]
                continue
            }
            if embeddedContext {
                let file = worktreeRoot.appendingPathComponent(target.path).absoluteString
                let anchor = "#L\(resolution.lineRange.lowerBound + 1)-L\(resolution.lineRange.upperBound + 1)"
                expansion.replacements[uri] = [.text(reference), .resource(uri: file + anchor, mimeType: "text/plain", text: code)]
                continue
            }
            var fence = "```"
            while code.contains(fence) { fence += "`" }
            let language = LanguageRegistry.codeFenceLanguage(forPath: target.path)
            expansion.replacements[uri] = [.text("\(reference)\n\n\(fence)\(language)\n\(code)\n\(fence)")]
        }
        return expansion
    }

    /// SHA-256 (hex) of a full declaration, as stored in `ACPSymbolSnapshot.contentHash`.
    /// Stamping a snapshot and judging live code against one both use it.
    static func contentHash(of declaration: String) -> String {
        SHA256.hash(data: Data(declaration.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func resolve(_ target: Target, source: String?) -> Resolution {
        let missing = Resolution(target: target, found: false, lineRange: target.lineRange, declaration: nil)
        guard let source else { return missing }
        let candidates = SymbolExtractor.symbols(in: source, relativePath: target.path)
            .filter { $0.name == target.name && $0.container == target.container }
        // Name, kind, and container must all match: a method replaced by a
        // same-named property is reported missing, not silently swapped.
        guard let match = candidates.filter({ $0.kind == target.kind }).min(by: {
            abs($0.lineRange.lowerBound - target.lineRange.lowerBound) < abs($1.lineRange.lowerBound - target.lineRange.lowerBound)
        }) else { return missing }
        let lines = source.components(separatedBy: "\n")
        guard match.lineRange.upperBound < lines.count else { return missing }
        let declaration = lines[match.lineRange].joined(separator: "\n")
        return Resolution(target: target, found: true, lineRange: match.lineRange, declaration: declaration)
    }

    /// Room kept for the cut marker, so marker plus code fit the byte cap.
    private static let markerReserve = 96

    static func excerpt(_ declaration: String) -> Excerpt {
        var lines = declaration.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let whole = lines.joined(separator: "\n")
        if lines.count <= maxExcerptLines, whole.utf8.count <= maxExcerptBytes {
            return Excerpt(text: whole, shownLines: lines.count, totalLines: lines.count, truncated: false)
        }
        let budget = maxExcerptBytes - markerReserve
        var kept: [String] = []
        var bytes = 0
        var shortened = false
        for line in lines {
            let cost = line.utf8.count + (kept.isEmpty ? 0 : 1)
            if kept.count == maxExcerptLines || bytes + cost > budget {
                if kept.isEmpty {
                    // One huge line (minified code): cut it to the byte
                    // budget on a scalar boundary, never mid-character.
                    var cut = String.UnicodeScalarView()
                    var used = 0
                    for scalar in line.unicodeScalars {
                        let width = UTF8.width(scalar)
                        if used + width > budget { break }
                        cut.append(scalar)
                        used += width
                    }
                    kept.append(String(cut))
                    shortened = true
                }
                break
            }
            kept.append(line)
            bytes += cost
        }
        let marker = "… cut: showing \(kept.count) of \(lines.count) lines" + (shortened ? ", first line shortened" : "")
        return Excerpt(text: kept.joined(separator: "\n") + "\n" + marker,
                       shownLines: kept.count, totalLines: lines.count, truncated: true)
    }

    static func referenceText(for resolution: Resolution) -> String {
        let target = resolution.target
        let lines = "lines \(resolution.lineRange.lowerBound + 1)–\(resolution.lineRange.upperBound + 1)"
        let suffix = resolution.found ? "." : " (last known location; not found when sent)."
        return "Referenced symbol: \(target.displayName), \(target.kind.label) in \(target.path), \(lines)\(suffix)"
    }

    /// `blocks` with each symbol link replaced as `expansion` rendered it.
    static func replacingReferences(in blocks: [ACPContentBlock], with expansion: Expansion) -> [ACPContentBlock] {
        guard !expansion.replacements.isEmpty else { return blocks }
        return blocks.flatMap { block -> [ACPContentBlock] in
            guard case .resourceLink(let uri, _) = block, let replacement = expansion.replacements[uri] else { return [block] }
            return replacement
        }
    }

    static func attachingSnapshots(
        to attachments: [ACPMessage.Attachment], from expansion: Expansion
    ) -> [ACPMessage.Attachment] {
        guard !expansion.snapshots.isEmpty else { return attachments }
        return attachments.map { attachment in
            guard let snapshot = expansion.snapshots[attachment.uri] else { return attachment }
            return ACPMessage.Attachment(
                uri: attachment.uri, name: attachment.name, mimeType: attachment.mimeType,
                textOffset: attachment.textOffset, symbol: snapshot
            )
        }
    }

    /// URL a transcript chip opens: the symbol's link, moved to the range
    /// that was sent. `ACPTabView` routes it to the editor.
    static func openURL(for target: Target, snapshot: ACPSymbolSnapshot?) -> URL? {
        let sent = Target(path: target.path, name: target.name, kind: target.kind, container: target.container,
                          lineRange: snapshot?.lineRange ?? target.lineRange, includeCode: target.includeCode)
        return URL(string: uri(for: sent))
    }
}

/// What a sent symbol mention looked like at send time. Stored on the
/// recorded attachment so the transcript can show it later.
struct ACPSymbolSnapshot: Codable, Equatable, Hashable, Sendable {
    /// 0-based, inclusive, as sent.
    let lineRange: ClosedRange<Int>
    /// SHA-256 (hex) of the declaration text as sent; empty when not found.
    let contentHash: String
    /// The code sent to the agent, only when "Include code" was on.
    let excerpt: String?
    let truncated: Bool
    let found: Bool
}
