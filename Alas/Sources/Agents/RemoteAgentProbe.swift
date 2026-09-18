enum RemoteAgentProbe {
    private static let outputPrefix = "__ALAS_AGENT_PROBE_AVAILABLE__ "

    static func command(agents: [AgentDefinition], workingDirectory: String) -> String {
        agents.enumerated().compactMap { index, agent in
            guard let check = BinaryClassification(agent.configuredBinary).check(
                workingDirectory: workingDirectory
            ) else {
                return nil
            }
            return "if \(check); then printf '%s%s\\n' '\(outputPrefix)' '\(index)'; fi"
        }
        .joined(separator: "\n")
    }

    static func availableAgentIDs(stdout: String, agents: [AgentDefinition]) -> Set<String> {
        Set(stdout.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.hasPrefix(outputPrefix) else { return nil }
            let rawIndex = line.dropFirst(outputPrefix.count)
            guard let index = Int(rawIndex), agents.indices.contains(index) else { return nil }
            return agents[index].id
        })
    }

    private enum BinaryClassification {
        case empty
        case bare(String)
        case absolute(String)
        case homeRelative(String)
        case relative(String)

        init(_ binary: String) {
            if binary.isEmpty {
                self = .empty
            } else if binary.hasPrefix("/") {
                self = .absolute(binary)
            } else if binary.hasPrefix("~/") {
                self = .homeRelative(String(binary.dropFirst(2)))
            } else if binary.contains("/") {
                self = .relative(binary)
            } else {
                self = .bare(binary)
            }
        }

        func check(workingDirectory: String) -> String? {
            switch self {
            case .empty:
                return nil
            case .bare(let binary):
                return "command -v \(SSHCommand.shellQuote(binary)) >/dev/null 2>&1"
            case .absolute(let path):
                let path = SSHCommand.shellQuote(path)
                return "[ -f \(path) ] && [ -x \(path) ]"
            case .homeRelative(let suffix):
                let suffix = SSHCommand.shellQuote(suffix)
                return "[ -f \"$HOME/\"\(suffix) ] && [ -x \"$HOME/\"\(suffix) ]"
            case .relative(let path):
                let path = SSHCommand.shellQuote(path)
                return "(cd \(SSHCommand.shellQuote(workingDirectory)) && [ -f \(path) ] && [ -x \(path) ])"
            }
        }
    }
}
