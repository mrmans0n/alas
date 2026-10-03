import Foundation

/// Disables OpenCode's native `task` tool for a session and proves it.
///
/// OpenCode drops a tool from the model request when the last permission
/// rule matching it is a blanket (`"*"`) deny. `OPENCODE_CONFIG_CONTENT`
/// merges after the global and project configuration, so a top-level
/// `permission.task = "deny"` there wins over their top-level rules. It does
/// not win over agent-specific rules, managed configuration, legacy `mode`
/// entries, `OPENCODE_PERMISSION`, or a permission block that lists `"*"`
/// after `"task"` (rules are evaluated in key order). So before every launch
/// Alas asks OpenCode itself for each agent's effective ruleset
/// (`opencode agent list`, same binary, environment, and directory as the
/// session), adds agent-specific denies where they help, and refuses to
/// launch if any agent — including ones the session can switch to — still
/// keeps `task`.
enum ACPOpenCodeTaskPolicy {
    static let agentID = "opencode"
    /// `agentInfo.name` reported by `opencode acp`.
    static let adapterName = "OpenCode"
    static let configKey = "OPENCODE_CONFIG_CONTENT"

    /// The version `opencode --version` printed: `1.18.34` on 1.x,
    /// `opencode v2.0.22` on 2.x. Nil when it printed no version.
    static func reportedVersion(_ versionOutput: String) -> String? {
        guard var token = versionOutput.split(whereSeparator: \.isWhitespace).last.map(String.init)
        else { return nil }
        if token.hasPrefix("v") { token.removeFirst() }
        guard token.split(separator: ".").first.flatMap({ Int($0) }) != nil else { return nil }
        return token
    }

    /// One agent from `opencode agent list`.
    struct Agent: Equatable, Sendable {
        let name: String
        let rules: [Rule]
    }

    /// One flattened OpenCode permission rule.
    struct Rule: Decodable, Equatable, Sendable {
        let permission: String
        let pattern: String
        let action: String
    }

    /// Runs `opencode agent list` with `OPENCODE_CONFIG_CONTENT` set to the
    /// given value and returns its standard output.
    typealias AgentListRunner = @Sendable (_ configContent: String) async throws -> String

    // MARK: Configuration merge

    /// `existing` with `permission.task` (and `agent.<name>.permission.task`
    /// for each name in `denyingAgents`) set to `"deny"`. Everything else,
    /// including the order of every permission block, is kept: OpenCode
    /// evaluates rules in key order, so reordering would change what the
    /// user's own rules allow. The `task` key moves to the end of its block
    /// so a `"*"` rule in the same block cannot override it.
    static func mergedConfig(existing: String?, denyingAgents: [String] = []) throws -> String {
        var root: [OrderedJSON.Member] = []
        if let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed: OrderedJSON
            do {
                parsed = try OrderedJSON.parse(existing)
            } catch {
                throw ACPNativeDelegationError.malformedOpenCodeConfig("it is not valid JSON")
            }
            guard case .object(let members) = parsed else {
                throw ACPNativeDelegationError.malformedOpenCodeConfig("it must be a JSON object")
            }
            root = members
        }

        OrderedJSON.set(&root, "permission", to: try denyingTask(in: OrderedJSON.value(root, "permission"), at: "permission"))
        if !denyingAgents.isEmpty {
            var agents = try objectMembers(OrderedJSON.value(root, "agent"), at: "agent")
            for name in denyingAgents {
                var agent = try objectMembers(OrderedJSON.value(agents, name), at: "agent.\(name)")
                OrderedJSON.set(&agent, "permission", to: try denyingTask(
                    in: OrderedJSON.value(agent, "permission"),
                    at: "agent.\(name).permission"
                ))
                OrderedJSON.set(&agents, name, to: .object(agent))
            }
            OrderedJSON.set(&root, "agent", to: .object(agents))
        }
        return OrderedJSON.object(root).serialized()
    }

    private static let deny = OrderedJSON.scalar(#""deny""#)

    /// A permission block with a trailing blanket `task` deny. The string
    /// form (`"permission": "ask"`) is OpenCode shorthand for `{"*": "ask"}`.
    private static func denyingTask(in value: OrderedJSON?, at path: String) throws -> OrderedJSON {
        var members: [OrderedJSON.Member]
        switch value {
        case nil:
            members = []
        case .object(let existing):
            members = existing.filter { $0.key != "task" }
        case .scalar(let raw) where OrderedJSON.decodedString(raw) != nil:
            members = [.init(key: "*", value: .scalar(raw))]
        default:
            throw ACPNativeDelegationError.malformedOpenCodeConfig("\"\(path)\" must be an object or an action")
        }
        members.append(.init(key: "task", value: deny))
        return .object(members)
    }

    private static func objectMembers(_ value: OrderedJSON?, at path: String) throws -> [OrderedJSON.Member] {
        switch value {
        case nil: return []
        case .object(let members): return members
        default: throw ACPNativeDelegationError.malformedOpenCodeConfig("\"\(path)\" must be an object")
        }
    }

    // MARK: Effective-permission check

    /// Parses `opencode agent list`: a `name (mode)` header per agent,
    /// followed by that agent's rules as a JSON array.
    static func parseAgentList(_ output: String) throws -> [Agent] {
        var agents: [Agent] = []
        var current: (name: String, body: [Substring])?
        func flush() throws {
            guard let block = current else { return }
            let json = block.body.joined(separator: "\n")
            guard let rules = try? JSONDecoder().decode([Rule].self, from: Data(json.utf8)) else {
                throw ACPNativeDelegationError.openCodePolicyUnverifiable(
                    "printed rules for \(block.name) that Alas could not read"
                )
            }
            agents.append(Agent(name: block.name, rules: rules))
        }
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if let name = agentHeaderName(line) {
                try flush()
                current = (name, [])
            } else {
                current?.body.append(line)
            }
        }
        try flush()
        guard !agents.isEmpty else {
            throw ACPNativeDelegationError.openCodePolicyUnverifiable("listed no agents")
        }
        return agents
    }

    private static func agentHeaderName(_ line: Substring) -> String? {
        guard let first = line.first, !first.isWhitespace else { return nil }
        for mode in ["primary", "subagent", "all"] {
            let suffix = " (\(mode))"
            if line.hasSuffix(suffix), line.count > suffix.count {
                return String(line.dropLast(suffix.count))
            }
        }
        return nil
    }

    /// Mirrors OpenCode's `Permission.disabled`: a tool is left out of the
    /// model request when the last rule whose permission matches it is a
    /// blanket deny. A pattern-scoped deny (`task: {"general": "deny"}`)
    /// only filters which subagents `task` offers; the tool stays.
    static func removesTask(_ rules: [Rule]) -> Bool {
        guard let last = rules.last(where: { wildcardMatches("task", pattern: $0.permission) }) else {
            return false
        }
        return last.pattern == "*" && last.action == "deny"
    }

    /// OpenCode's `Wildcard.match`: `*` is any run, `?` any character, and a
    /// trailing `" *"` also matches nothing.
    static func wildcardMatches(_ input: String, pattern: String) -> Bool {
        var regex = NSRegularExpression.escapedPattern(for: pattern.replacingOccurrences(of: "\\", with: "/"))
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        if regex.hasSuffix(" .*") {
            regex = String(regex.dropLast(3)) + "( .*)?"
        }
        guard let compiled = try? NSRegularExpression(pattern: "^" + regex + "$", options: [.dotMatchesLineSeparators])
        else { return false }
        let normalized = input.replacingOccurrences(of: "\\", with: "/")
        return compiled.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) != nil
    }

    /// Returns configuration content under which every OpenCode agent drops
    /// `task`, or throws. Starts from `content` (the top-level deny); agents
    /// that still keep `task` get an agent-specific deny and are checked
    /// again. Anything still open after that is overridden by configuration
    /// Alas cannot outrank, so the launch fails rather than run unenforced.
    static func verifiedConfig(startingFrom content: String, runAgentList: AgentListRunner) async throws -> String {
        let open = try await agentsKeepingTask(content, runAgentList)
        guard !open.isEmpty else { return content }
        let forced = try mergedConfig(existing: content, denyingAgents: open)
        let stillOpen = try await agentsKeepingTask(forced, runAgentList)
        guard stillOpen.isEmpty else {
            throw ACPNativeDelegationError.openCodeTaskStillEnabled(agents: stillOpen)
        }
        return forced
    }

    private static func agentsKeepingTask(_ content: String, _ runAgentList: AgentListRunner) async throws -> [String] {
        try parseAgentList(try await runAgentList(content))
            .filter { !removesTask($0.rules) }
            .map(\.name)
    }

    /// Applies `verifiedConfig` to a local OpenCode launch whose policy is
    /// on; other launches pass through unchanged.
    static func verifyingLaunch(
        _ spec: ACPLaunchSpec,
        nativeSubagentsDisabled: Bool,
        cwd: String
    ) async throws -> ACPLaunchSpec {
        guard nativeSubagentsDisabled,
              ACPNativeDelegationSupport.resolve(agentID: spec.agentID).mechanism == .openCodeConfigContent,
              let content = spec.extraEnv[configKey]
        else { return spec }
        // Fail on a major whose policy Alas has not verified before running
        // `opencode agent list`, which OpenCode 2 no longer has.
        try ACPNativeDelegationControls.checkAdapterVersion(
            reportedVersion(await versionOutput(command: spec.command, extraEnv: spec.extraEnv, cwd: cwd)),
            mechanism: .openCodeConfigContent,
            agentID: spec.agentID
        )
        let runner = agentListRunner(command: spec.command, extraEnv: spec.extraEnv, cwd: cwd)
        let verified = try await verifiedConfig(startingFrom: content, runAgentList: runner)
        return spec.mergingExtraEnv([configKey: verified])
    }

    /// `opencode --version` stdout, or "" when it cannot run; an empty
    /// result fails the version check as an unidentified version.
    static func versionOutput(command: String, extraEnv: [String: String], cwd: String) async -> String {
        let absolute = command.hasPrefix("/")
        guard let result = try? await Process.run(
            absolute ? command : "/usr/bin/env",
            args: (absolute ? [] : [command]) + ["--version"],
            cwd: URL(fileURLWithPath: cwd),
            env: ACPProcessEnvironment.sanitizedForACP(extra: extraEnv),
            timeout: 30
        ), result.exitCode == 0 else { return "" }
        return result.stdout
    }

    /// `opencode agent list` in the environment and directory the adapter
    /// will run in, so it resolves the same configuration layers.
    static func agentListRunner(command: String, extraEnv: [String: String], cwd: String) -> AgentListRunner {
        { content in
            var extra = extraEnv
            extra[configKey] = content
            let result: ProcessResult
            do {
                // A bare command (the catalog default) is resolved against
                // the launch PATH, exactly like the adapter launch itself.
                let absolute = command.hasPrefix("/")
                result = try await Process.run(
                    absolute ? command : "/usr/bin/env",
                    args: (absolute ? [] : [command]) + ["agent", "list"],
                    cwd: URL(fileURLWithPath: cwd),
                    env: ACPProcessEnvironment.sanitizedForACP(extra: extra),
                    timeout: 60
                )
            } catch {
                throw ACPNativeDelegationError.openCodePolicyUnverifiable("could not run: \(error)")
            }
            guard result.exitCode == 0 else {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300)
                throw ACPNativeDelegationError.openCodePolicyUnverifiable(
                    "exited with status \(result.exitCode)\(detail.isEmpty ? "" : ": \(detail)")"
                )
            }
            return result.stdout
        }
    }
}

/// JSON that keeps object key order, for editing configuration whose
/// meaning depends on it. Scalars keep their source text. Accepts the JSONC
/// OpenCode reads (comments, trailing commas); output is plain JSON.
indirect enum OrderedJSON: Equatable, Sendable {
    struct Member: Equatable, Sendable {
        let key: String
        var value: OrderedJSON
    }

    case object([Member])
    case array([OrderedJSON])
    /// A string, number, boolean, or null, as written in the source.
    case scalar(String)

    static func value(_ members: [Member], _ key: String) -> OrderedJSON? {
        members.last { $0.key == key }?.value
    }

    /// Replaces `key` in place (dropping duplicates), or appends it.
    static func set(_ members: inout [Member], _ key: String, to value: OrderedJSON) {
        guard let index = members.firstIndex(where: { $0.key == key }) else {
            members.append(Member(key: key, value: value))
            return
        }
        members[index].value = value
        members = members.enumerated().filter { $0.offset <= index || $0.element.key != key }.map(\.element)
    }

    static func decodedString(_ raw: String) -> String? {
        guard raw.hasPrefix("\"") else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed) as? String
    }

    func serialized() -> String {
        switch self {
        case .scalar(let raw):
            return raw
        case .array(let items):
            return "[" + items.map { $0.serialized() }.joined(separator: ",") + "]"
        case .object(let members):
            return "{" + members.map { Self.encoded($0.key) + ":" + $0.value.serialized() }.joined(separator: ",") + "}"
        }
    }

    private static func encoded(_ string: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    struct ParseError: Error {}

    static func parse(_ text: String) throws -> OrderedJSON {
        var parser = Parser(bytes: Array(text.utf8))
        let value = try parser.value()
        try parser.skipTrivia()
        guard parser.index == parser.bytes.count else { throw ParseError() }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func value() throws -> OrderedJSON {
            try skipTrivia()
            guard index < bytes.count else { throw ParseError() }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                var members: [Member] = []
                while true {
                    try skipTrivia()
                    if consume("}") { return .object(members) }
                    guard case .scalar(let raw) = try string(), let key = decodedString(raw) else { throw ParseError() }
                    try skipTrivia()
                    guard consume(":") else { throw ParseError() }
                    members.append(Member(key: key, value: try value()))
                    try skipTrivia()
                    if consume("}") { return .object(members) }
                    guard consume(",") else { throw ParseError() }
                }
            case UInt8(ascii: "["):
                index += 1
                var items: [OrderedJSON] = []
                while true {
                    try skipTrivia()
                    if consume("]") { return .array(items) }
                    items.append(try value())
                    try skipTrivia()
                    if consume("]") { return .array(items) }
                    guard consume(",") else { throw ParseError() }
                }
            case UInt8(ascii: "\""):
                return try string()
            default:
                let start = index
                while index < bytes.count, !Self.isDelimiter(bytes[index]) { index += 1 }
                let raw = String(decoding: bytes[start..<index], as: UTF8.self)
                // Validates numbers, true, false, and null.
                guard !raw.isEmpty,
                      (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed)) != nil
                else { throw ParseError() }
                return .scalar(raw)
            }
        }

        mutating func string() throws -> OrderedJSON {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw ParseError() }
            let start = index
            index += 1
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\\"): index += 2
                case UInt8(ascii: "\""):
                    index += 1
                    let raw = String(decoding: bytes[start..<index], as: UTF8.self)
                    guard decodedString(raw) != nil else { throw ParseError() }
                    return .scalar(raw)
                default: index += 1
                }
            }
            throw ParseError()
        }

        mutating func consume(_ character: Unicode.Scalar) -> Bool {
            guard index < bytes.count, bytes[index] == UInt8(ascii: character) else { return false }
            index += 1
            return true
        }

        /// Skips whitespace and `//` / `/* */` comments.
        mutating func skipTrivia() throws {
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 {
                    index += 1
                } else if byte == UInt8(ascii: "/"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "/") {
                    while index < bytes.count, bytes[index] != 0x0A { index += 1 }
                } else if byte == UInt8(ascii: "/"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "*") {
                    index += 2
                    while index + 1 < bytes.count, !(bytes[index] == UInt8(ascii: "*") && bytes[index + 1] == UInt8(ascii: "/")) {
                        index += 1
                    }
                    // An unterminated block comment is malformed, not trailing trivia.
                    guard index + 1 < bytes.count else { throw ParseError() }
                    index += 2
                } else {
                    return
                }
            }
        }

        static func isDelimiter(_ byte: UInt8) -> Bool {
            [0x20, 0x0A, 0x0D, 0x09, UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), UInt8(ascii: "/")]
                .contains(byte)
        }
    }
}
