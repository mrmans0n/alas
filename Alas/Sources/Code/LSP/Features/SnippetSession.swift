import Foundation

struct SnippetExpansion: Sendable {
    let text: String
    let tabStops: [Int: [NSRange]]
    let finalCaret: Int
    let transforms: [Int: [(NSRange, SnippetTransform)]]
    let parents: [Int: Set<Int>]
    let stopOrders: [Int: [Int]]
    let transformOrders: [Int: [Int]]
    var orderedStops: [Int] { tabStops.keys.filter { $0 > 0 }.sorted() }
}

/// A parsed snippet never contains unexpanded protocol syntax. All offsets are UTF-16.
struct SnippetSession {
    enum Error: Swift.Error { case malformed, limitExceeded }
    private var stops: [Int: [NSRange]]
    private var transforms: [Int: [(NSRange, SnippetTransform)]]
    private var values: [Int: String]
    private var parents: [Int: Set<Int>]
    private let stopOrders: [Int: [Int]]
    private let transformOrders: [Int: [Int]]
    private var order: [Int]
    private var index = 0
    private var finalCaret: Int
    private(set) var isFinished = false
    var selection: NSRange? { !isFinished && order.indices.contains(index) ? stops[order[index]]?.first : nil }

    init(expansion: SnippetExpansion, offset: Int) {
        stops = expansion.tabStops.mapValues { $0.map { NSRange(location: $0.location + offset, length: $0.length) } }
        transforms = expansion.transforms.mapValues { $0.map { (NSRange(location: $0.0.location + offset, length: $0.0.length), $0.1) } }
        values = expansion.tabStops.compactMapValues { ranges in ranges.first.map { (expansion.text as NSString).substring(with: $0) } }
        parents = expansion.parents
        stopOrders = expansion.stopOrders
        transformOrders = expansion.transformOrders
        order = expansion.orderedStops
        finalCaret = expansion.finalCaret + offset
        isFinished = order.isEmpty
    }

    mutating func advance(backwards: Bool) -> NSRange? {
        guard !isFinished else { return nil }
        index = max(0, index + (backwards ? -1 : 1))
        if index == order.count { isFinished = true
        return NSRange(location: finalCaret, length: 0) }
        return selection
    }

    mutating func replacing(_ range: NSRange, with replacement: String) -> CompletionEditPlan? {
        guard let selected = selection, range.location >= selected.location, NSMaxRange(range) <= NSMaxRange(selected),
              let value = values[order[index]], replacement.utf16.count < 65536 else { return nil }
        let key = order[index]
        let relative = NSRange(location: range.location - selected.location, length: range.length)
        guard Range(relative, in: value) != nil else { return nil }
        let next = (value as NSString).replacingCharacters(in: relative, with: replacement)
        var edits = (stops[key] ?? []).map { CompletionTextEdit(range: $0, replacementText: next) }
        var editOrders = stopOrders[key] ?? []
        for (index, entry) in (transforms[key] ?? []).enumerated() {
            let (range, transform) = entry
            guard let transformed = try? transform.apply(next) else { return nil }
            edits.append(.init(range: range, replacementText: transformed))
            editOrders.append(transformOrders[key]?[index] ?? Int.max)
        }
        let ancestors = (parents[key] ?? []).sorted { (stops[$0]?.first?.length ?? 0) < (stops[$1]?.first?.length ?? 0) }
        for ancestor in ancestors {
            guard let primaryIndex = stops[ancestor]?.indices.last(where: {
                let range = stops[ancestor]![$0]
                return range.location <= selected.location && NSMaxRange(selected) <= NSMaxRange(range)
                    && (stopOrders[ancestor]?[$0] ?? 0) <= (stopOrders[key]?.first ?? Int.max)
            }), let primary = stops[ancestor]?[primaryIndex],
                  let original = values[ancestor] else { return nil }
            let changed = NSMutableString(string: original)
            let inside = zip(edits, editOrders).filter { primary.location <= $0.0.range.location && NSMaxRange($0.0.range) <= NSMaxRange(primary) }
            for (edit, _) in inside.sorted(by: {
                $0.0.range.location == $1.0.range.location ? $0.1 > $1.1 : $0.0.range.location > $1.0.range.location
            }) {
                changed.replaceCharacters(in: NSRange(location: edit.range.location - primary.location, length: edit.range.length), with: edit.replacementText)
            }
            values[ancestor] = changed as String
            for (index, mirror) in (stops[ancestor] ?? []).enumerated() where index != primaryIndex {
                edits.append(.init(range: mirror, replacementText: changed as String))
                editOrders.append(stopOrders[ancestor]?[index] ?? Int.max)
            }
            for (index, entry) in (transforms[ancestor] ?? []).enumerated() {
                let (range, transform) = entry
                guard let transformed = try? transform.apply(changed as String) else { return nil }
                edits.append(.init(range: range, replacementText: transformed))
                editOrders.append(transformOrders[ancestor]?[index] ?? Int.max)
            }
        }
        let orderedEdits = zip(edits, editOrders).sorted {
            $0.0.range.location == $1.0.range.location ? $0.1 < $1.1 : $0.0.range.location < $1.0.range.location
        }
        edits = orderedEdits.map(\.0)
        guard edits.reduce(0, { $0 + $1.replacementText.utf16.count }) <= 262144 else { return nil }
        var editedRanges: [Int: NSRange] = [:]
        var precedingDelta = 0
        for (edit, ordinal) in orderedEdits {
            editedRanges[ordinal] = NSRange(location: edit.range.location + precedingDelta, length: edit.replacementText.utf16.count)
            precedingDelta += edit.replacementText.utf16.count - edit.range.length
        }
        // Replacing a containing placeholder removes its nested stops.
        let removed = Set(stops.keys.filter { parents[$0]?.contains(key) == true })
        for other in removed { stops[other] = nil
        transforms[other] = nil }
        order.removeAll { removed.contains($0) }
        func mapped(_ range: NSRange) -> NSRange {
            var start = range.location
            var length = range.length
            for edit in edits {
                let delta = edit.replacementText.utf16.count - edit.range.length
                if edit.range == range { length = edit.replacementText.utf16.count }
                else if NSMaxRange(edit.range) <= range.location { start += delta }
                else if range.location <= edit.range.location && NSMaxRange(edit.range) <= NSMaxRange(range) { length += delta }
            }
            return NSRange(location: start, length: length)
        }
        func mappedCaret(_ location: Int, ordinal: Int = Int.max) -> Int {
            var result = location
            for (edit, editOrder) in orderedEdits {
                if edit.range.length == 0, edit.range.location == location, editOrder >= ordinal { continue }
                if NSMaxRange(edit.range) <= location {
                    result += edit.replacementText.utf16.count - edit.range.length
                } else if edit.range.location <= location {
                    result += edit.range.location + edit.replacementText.utf16.count - location
                }
            }
            return result
        }
        stops = Dictionary(uniqueKeysWithValues: stops.map { stopID, ranges in
            let updated = ranges.enumerated().map { index, range in
                let ordinal = stopOrders[stopID]?[index] ?? Int.max
                if let replacement = editedRanges[ordinal] { return replacement }
                if range.length == 0 { return NSRange(location: mappedCaret(range.location, ordinal: ordinal), length: 0) }
                return mapped(range)
            }
            return (stopID, updated)
        })
        transforms = Dictionary(uniqueKeysWithValues: transforms.map { key, entries in
            (key, entries.enumerated().map { index, entry in
                (editedRanges[transformOrders[key]?[index] ?? Int.max] ?? mapped(entry.0), entry.1)
            })
        })
        finalCaret = mappedCaret(finalCaret, ordinal: stopOrders[0]?.first ?? Int.max)
        values[key] = next
        let caret = (selection?.location ?? selected.location) + relative.location + replacement.utf16.count
        return CompletionEditPlan(edits: edits, finalSelection: NSRange(location: caret, length: 0))
    }

    static func parse(_ source: String, variables: [String: String] = [:]) throws -> SnippetExpansion {
        guard source.utf16.count <= 65536 else { throw Error.limitExceeded }
        var parser = SnippetParser(source)
        let nodes = try parser.parse()
        var renderer = SnippetRenderer(variables: variables)
        renderer.collect(nodes)
        try renderer.render(nodes)
        return SnippetExpansion(text: renderer.text, tabStops: renderer.stops,
                                finalCaret: renderer.stops[0]?.first?.location ?? renderer.text.utf16.count,
                                transforms: renderer.transforms, parents: renderer.parents,
                                stopOrders: renderer.stopOrders, transformOrders: renderer.transformOrders)
    }
}

private indirect enum SnippetNode {
    case text(String)
    case stop(Int, [SnippetNode]?)
    case variable(String, [SnippetNode]?)
    case transform(String, SnippetTransform)
}

private struct SnippetParser {
    var chars: [Character]
    var index = 0
    init(_ source: String) { chars = Array(source) }
    mutating func parse(nested: Bool = false, depth: Int = 0) throws -> [SnippetNode] {
        guard depth < 32 else { throw SnippetSession.Error.limitExceeded }
        var nodes: [SnippetNode] = []
        var literal = ""
        while index < chars.count {
            let c = chars[index]
            index += 1
            if c == "}", nested { if !literal.isEmpty { nodes.append(.text(literal)) }
            return nodes }
            if c == "\\", index < chars.count, ["$", "}", "\\"].contains(chars[index]) { literal.append(chars[index])
            index += 1
            continue }
            guard c == "$" else { literal.append(c)
            continue }
            if !literal.isEmpty { nodes.append(.text(literal))
            literal = "" }
            let braced = consume("{")
            let start = index
            let numeric = index < chars.count && chars[index].isNumber
            while index < chars.count, chars[index].isASCII,
                  numeric ? chars[index].isNumber : (chars[index].isLetter || chars[index].isNumber || chars[index] == "_") { index += 1 }
            let name = String(chars[start..<index])
            guard !name.isEmpty else {
                if braced { throw SnippetSession.Error.malformed }
                literal = "$"
                continue
            }
            let number = Int(name)
            if name.first?.isNumber == true, number == nil { throw SnippetSession.Error.malformed }
            var children: [SnippetNode]?
            if braced {
                if consume(":") { children = try parse(nested: true, depth: depth + 1) }
                else if consume("|") {
                    guard number != nil else { throw SnippetSession.Error.malformed }
                    var first = ""
                    var inFirst = true
                    var closed = false
                    while index < chars.count {
                        let c = chars[index]
                        index += 1
                        if c == "\\", index < chars.count, [",", "|", "\\"].contains(chars[index]) {
                            if inFirst { first.append(chars[index]) }
                            index += 1
                        } else if c == "," { inFirst = false }
                        else if c == "|", consume("}") { closed = true
                        break }
                        else if inFirst { first.append(c) }
                    }
                    guard closed else { throw SnippetSession.Error.malformed }
                    children = [.text(first)]
                } else if consume("/") {
                    let regex = try segment(format: false)
                    let format = try segment(format: true)
                    let start = index
                    while index < chars.count, chars[index] != "}" { index += 1 }
                    let options = String(chars[start..<index])
                    guard consume("}") else { throw SnippetSession.Error.malformed }
                    nodes.append(.transform(name, try SnippetTransform(pattern: regex, format: format, options: options)))
                    continue
                } else if !consume("}") { throw SnippetSession.Error.malformed }
            }
            nodes.append(number.map { .stop($0, children) } ?? .variable(name, children))
        }
        guard !nested else { throw SnippetSession.Error.malformed }
        if !literal.isEmpty { nodes.append(.text(literal)) }
        return nodes
    }
    mutating func consume(_ c: Character) -> Bool {
        guard index < chars.count, chars[index] == c else { return false }
        index += 1
        return true
    }
    mutating func segment(format: Bool) throws -> String {
        var result = ""
        var braces = 0
        while index < chars.count {
            let c = chars[index]
            index += 1
            if c == "\\", index < chars.count {
                let next = chars[index]
                index += 1
                if next != "/" { result.append(c) }
                result.append(next)
                continue
            }
            if format, c == "{" { braces += 1 }
            if format, c == "}" { braces -= 1 }
            if c == "/", braces == 0 { return result }
            result.append(c)
        }
        throw SnippetSession.Error.malformed
    }
}

private struct SnippetRenderer {
    let variables: [String: String]
    var definitions: [Int: [SnippetNode]] = [:]
    var values: [Int: String] = [:]
    var resolving = Set<Int>()
    var text = ""
    var stops: [Int: [NSRange]] = [:]
    var transforms: [Int: [(NSRange, SnippetTransform)]] = [:]
    var parents: [Int: Set<Int>] = [:]
    var stack: [Int] = []
    var unknownVariables: [String: Int] = [:]
    var reservedStops = Set<Int>()
    var renderedDefinitions = Set<Int>()
    var stopOrders: [Int: [Int]] = [:]
    var transformOrders: [Int: [Int]] = [:]
    var nextOrdinal = 0
    mutating func collect(_ nodes: [SnippetNode]) {
        for node in nodes {
            switch node {
            case .stop(let key, let children):
                reservedStops.insert(key)
                if let children {
                    if definitions[key] == nil { definitions[key] = children }
                    collect(children)
                }
            case .variable(_, let children?): collect(children)
            case .transform(let name, _):
                if let key = Int(name) { reservedStops.insert(key) }
            default: break
            }
        }
    }
    mutating func value(_ key: Int) throws -> String {
        if let value = values[key] { return value }
        guard resolving.insert(key).inserted else { throw SnippetSession.Error.malformed }
        var copy = self
        copy.text = ""
        copy.stops = [:]
        copy.transforms = [:]
        try copy.render(definitions[key] ?? [])
        resolving.remove(key)
        values[key] = copy.text
        return copy.text
    }
    mutating func render(_ nodes: [SnippetNode]) throws {
        for node in nodes {
            let start = text.utf16.count
            let ordinal = nextOrdinal
            nextOrdinal += 1
            switch node {
            case .text(let value): text += value
            case .stop(let key, let children):
                let rendered = try value(key)
                parents[key, default: []].formUnion(stack)
                if let children, renderedDefinitions.insert(key).inserted { stack.append(key)
                try render(children)
                stack.removeLast() } else { text += rendered }
                stops[key, default: []].append(NSRange(location: start, length: text.utf16.count - start))
                stopOrders[key, default: []].append(ordinal)
            case .variable(let name, let children):
                if let value = variables[name] { text += value }
                else if let children { try render(children) }
                else {
                    let key = unknownVariables[name] ?? max(reservedStops.max() ?? 0, stops.keys.max() ?? 0) + 1
                    unknownVariables[name] = key
                    text += name
                    stops[key, default: []].append(NSRange(location: start, length: name.utf16.count))
                    stopOrders[key, default: []].append(ordinal)
                    parents[key, default: []].formUnion(stack)
                }
            case .transform(let name, let transform):
                let value = try Int(name).map { try self.value($0) } ?? variables[name] ?? ""
                text += try transform.apply(value)
                if let key = Int(name) {
                    transforms[key, default: []].append((NSRange(location: start, length: text.utf16.count - start), transform))
                    transformOrders[key, default: []].append(ordinal)
                }
            }
            guard text.utf16.count <= 262144 else { throw SnippetSession.Error.limitExceeded }
        }
    }
}

struct SnippetTransform: Sendable {
    let pattern: String
    let format: String
    let options: String
    init(pattern: String, format: String, options: String) throws {
        guard pattern.utf16.count <= 512, format.utf16.count <= 2048, Set(options).isSubset(of: Set("gims")) else { throw SnippetSession.Error.limitExceeded }
        self.pattern = pattern
        self.format = format
        self.options = options
        _ = try expression()
        _ = try replacement(capture: { _ in "" })
    }
    private func expression() throws -> NSRegularExpression {
        var flags: NSRegularExpression.Options = []
        if options.contains("i") { flags.insert(.caseInsensitive) }
        if options.contains("m") { flags.insert(.anchorsMatchLines) }
        if options.contains("s") { flags.insert(.dotMatchesLineSeparators) }
        return try NSRegularExpression(pattern: pattern, options: flags)
    }
    func apply(_ value: String) throws -> String {
        guard value.utf16.count <= 65536 else { throw SnippetSession.Error.limitExceeded }
        let regex = try expression()
        var matches: [NSTextCheckingResult] = []
        var limited = false
        let deadline = Date().addingTimeInterval(0.025)
        regex.enumerateMatches(in: value, options: [.reportProgress], range: NSRange(location: 0, length: value.utf16.count)) { match, _, stop in
            if Date() > deadline || matches.count > 1024 { limited = true
            stop.pointee = true
            return }
            if let match { matches.append(match)
            if !options.contains("g") { stop.pointee = true } }
        }
        guard !limited else { throw SnippetSession.Error.limitExceeded }
        let result = NSMutableString(string: value)
        for match in matches.reversed() {
            let replacement = try replacement { index in
                guard index < match.numberOfRanges, match.range(at: index).location != NSNotFound else { return "" }
                return (value as NSString).substring(with: match.range(at: index))
            }
            result.replaceCharacters(in: match.range, with: replacement)
        }
        return result as String
    }
    private func replacement(capture: (Int) -> String) throws -> String {
        let chars = Array(format)
        var index = 0
        var output = ""
        while index < chars.count {
            let c = chars[index]
            index += 1
            if c == "\\", index < chars.count { output.append(chars[index])
            index += 1
            continue }
            guard c == "$" else { output.append(c)
            continue }
            let braced = index < chars.count && chars[index] == "{"
            if braced { index += 1 }
            let start = index
            while index < chars.count, chars[index].isNumber { index += 1 }
            guard let key = Int(String(chars[start..<index])) else { throw SnippetSession.Error.malformed }
            let value = capture(key)
            if !braced { output += value
            continue }
            let suffixStart = index
            while index < chars.count, chars[index] != "}" { index += 1 }
            guard index < chars.count else { throw SnippetSession.Error.malformed }
            let suffix = String(chars[suffixStart..<index])
            index += 1
            if suffix.isEmpty { output += value }
            else if suffix.hasPrefix(":/") {
                switch String(suffix.dropFirst(2)) {
                case "upcase": output += value.uppercased()
                case "downcase": output += value.lowercased()
                case "capitalize": output += value.prefix(1).uppercased() + value.dropFirst()
                case "camelcase", "pascalcase":
                    let words = value.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
                    output += words.enumerated().map { index, word in index == 0 && suffix == ":/camelcase" ? word.prefix(1).lowercased() + word.dropFirst() : word.prefix(1).uppercased() + word.dropFirst() }.joined()
                default: throw SnippetSession.Error.malformed
                }
            } else if suffix.hasPrefix(":+") { if !value.isEmpty { output += suffix.dropFirst(2) } }
            else if suffix.hasPrefix(":?") {
                let parts = suffix.dropFirst(2).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { throw SnippetSession.Error.malformed }
                output += String(parts[value.isEmpty ? 1 : 0])
            } else if suffix.hasPrefix(":-") { output += value.isEmpty ? String(suffix.dropFirst(2)) : value }
            else if suffix.hasPrefix(":") { output += value.isEmpty ? String(suffix.dropFirst()) : value }
            else { throw SnippetSession.Error.malformed }
        }
        return output
    }
}
