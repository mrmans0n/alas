import CryptoKit
import Foundation

enum MCPTransportKind: String, Codable, Equatable {
    case stdio
    case http
    case sse
}

enum MCPAttachmentSkipReason: Equatable {
    case unsupportedTransport
    case missingVariable(String)
    case invalidConfiguration(String)
    /// A checkout snapshot retains the descriptor for diagnostics, but never
    /// retargets it to whichever member currently has focus.
    case unavailableMember
}

enum MCPAttachmentDisposition: Equatable {
    case requested
    case skipped(MCPAttachmentSkipReason)
}

/// Project-scoped input that is deliberately fetched at attach time, so a
/// fresh attach reflects the current project configuration without restarting
/// an already connected session.
struct MCPProjectContext: Equatable {
    let projectDirectory: String
    let configuredServers: [ProjectMCPServer]
}

struct MCPAttachmentServerStatus: Equatable, Identifiable {
    let id: String
    let name: String
    let transport: MCPTransportKind
    let disposition: MCPAttachmentDisposition

    init(
        id: String,
        name: String,
        transport: MCPTransportKind,
        disposition: MCPAttachmentDisposition
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.disposition = disposition
    }
}

struct MCPAttachmentPlan: Equatable {
    let wireServers: [ACPMCPServer]
    let statuses: [MCPAttachmentServerStatus]
    let configurationFingerprint: String
}

/// Session-visible attachment state. This intentionally excludes resolved
/// wire definitions, which may contain environment-expanded credentials.
struct MCPAttachmentSummary: Equatable {
    let statuses: [MCPAttachmentServerStatus]
    let configurationFingerprint: String

    init(statuses: [MCPAttachmentServerStatus], configurationFingerprint: String) {
        self.statuses = statuses
        self.configurationFingerprint = configurationFingerprint
    }

    init(plan: MCPAttachmentPlan) {
        self.init(
            statuses: plan.statuses,
            configurationFingerprint: plan.configurationFingerprint
        )
    }
}

struct MCPAttachmentPlannerInput {
    let configuredServers: [ProjectMCPServer]
    let projectDirectory: String
    let worktreeDirectory: String
    let environment: [String: String]
    let capabilities: ACPMCPServerCapabilities
    /// Checkout sessions supply descriptors captured during preflight. They
    /// must never fall back to current Project configuration on restore.
    let frozenServerDescriptors: [WorkspaceMCPServerDescriptor]?
    /// Descriptor identities whose frozen member is currently unavailable.
    /// The IDs are snapshot identities, not live Project or focus identities.
    let unavailableFrozenDescriptorIDs: Set<String>

    init(
        configuredServers: [ProjectMCPServer],
        projectDirectory: String,
        worktreeDirectory: String,
        environment: [String: String],
        capabilities: ACPMCPServerCapabilities,
        frozenServerDescriptors: [WorkspaceMCPServerDescriptor]? = nil,
        unavailableFrozenDescriptorIDs: Set<String> = []
    ) {
        self.configuredServers = configuredServers
        self.projectDirectory = projectDirectory
        self.worktreeDirectory = worktreeDirectory
        self.environment = environment
        self.capabilities = capabilities
        self.frozenServerDescriptors = frozenServerDescriptors
        self.unavailableFrozenDescriptorIDs = unavailableFrozenDescriptorIDs
    }
}

enum MCPAttachmentPlanner {
    private enum ResolutionError: Error {
        case missingVariable(String)
    }
    static func plan(_ input: MCPAttachmentPlannerInput) -> MCPAttachmentPlan {
        let descriptors = descriptors(for: input)
        let validationIssues = ProjectMCPValidation.validate(descriptors.map(\.server))
        var wireServers: [ACPMCPServer] = []
        var statuses: [MCPAttachmentServerStatus] = []

        for (index, descriptor) in descriptors.enumerated() {
            let server = descriptor.server
            let transport = transportKind(for: server.transport)
            let disposition: MCPAttachmentDisposition
            let environment = resolvedEnvironment(for: input, descriptor: descriptor)

            if input.unavailableFrozenDescriptorIDs.contains(descriptor.id) {
                disposition = .skipped(.unavailableMember)
            } else if validationIssues.contains(where: { applies($0, to: server) && !isDeferredTemplateURLIssue($0, server: server) }) {
                disposition = .skipped(.invalidConfiguration("The server configuration is invalid."))
            } else if !isSupported(transport, capabilities: input.capabilities) {
                disposition = .skipped(.unsupportedTransport)
            } else {
                switch makeWireServer(server, environment: environment) {
                case let .success(wireServer):
                    if hasValidResolvedWireServer(wireServer) {
                        wireServers.append(wireServer)
                        disposition = .requested
                    } else {
                        disposition = .skipped(.invalidConfiguration("The server configuration is invalid."))
                    }
                case let .failure(.missingVariable(variable)):
                    disposition = .skipped(.missingVariable(variable))
                }
            }

            // Configuration can be edited externally and contain duplicate names.
            // Keep the presentation identity unique without retaining sensitive values.
            statuses.append(.init(
                id: descriptor.id.isEmpty ? String(index) : descriptor.id,
                name: server.name,
                transport: transport,
                disposition: disposition
            ))
        }

        return .init(
            wireServers: wireServers,
            statuses: statuses,
            configurationFingerprint: configurationFingerprint(for: descriptors.map(\.server))
        )
    }

    private static func descriptors(for input: MCPAttachmentPlannerInput) -> [WorkspaceMCPServerDescriptor] {
        guard let frozenServerDescriptors = input.frozenServerDescriptors else {
            return input.configuredServers.enumerated().map { index, server in
                .init(id: String(index), server: server, projectDirectory: input.projectDirectory, worktreeDirectory: input.worktreeDirectory)
            }
        }
        return normalizedFrozenServerDescriptors(for: frozenServerDescriptors)
    }

    static func normalizedFrozenServerDescriptors(for frozenServerDescriptors: [WorkspaceMCPServerDescriptor]) -> [WorkspaceMCPServerDescriptor] {
        let nameCounts = Dictionary(
            grouping: frozenServerDescriptors.map { $0.server.name.trimmingCharacters(in: .whitespacesAndNewlines) },
            by: { $0 }
        ).mapValues(\.count)
        return frozenServerDescriptors.map { descriptor in
            let name = descriptor.server.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.isEmpty == false,
                  (nameCounts[name] ?? 0) > 1
            else { return descriptor }
            var server = descriptor.server
            server.name = "\(name) (\(descriptor.id))"
            return .init(
                id: descriptor.id,
                server: server,
                projectDirectory: descriptor.projectDirectory,
                worktreeDirectory: descriptor.worktreeDirectory,
                checkoutRoot: descriptor.checkoutRoot
            )
        }
    }

    static func configurationFingerprint(for servers: [ProjectMCPServer]) -> String {
        let definitions = servers.map(FingerprintDefinition.init)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(definitions)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func resolvedConfigurationFingerprint(for servers: [ACPMCPServer]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(servers)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func resolvedEnvironment(for input: MCPAttachmentPlannerInput, descriptor: WorkspaceMCPServerDescriptor) -> [String: String] {
        var environment = input.environment
        environment["PROJECT_DIR"] = descriptor.checkoutRoot
        environment["WORKTREE_DIR"] = descriptor.worktreeDirectory
        return environment
    }

    private static func transportKind(for transport: ProjectMCPTransport) -> MCPTransportKind {
        switch transport {
        case .stdio: .stdio
        case .http: .http
        case .sse: .sse
        }
    }

    private static func isSupported(_ transport: MCPTransportKind, capabilities: ACPMCPServerCapabilities) -> Bool {
        switch transport {
        case .stdio: true
        case .http: capabilities.http
        case .sse: capabilities.sse
        }
    }

    private static func applies(_ issue: ProjectMCPValidationIssue, to server: ProjectMCPServer) -> Bool {
        let name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch issue {
        case let .emptyServerName(serverId):
            return server.id == serverId
        case let .duplicateServerName(serverName),
             let .emptyCommand(serverName),
             let .invalidURL(serverName),
             let .invalidEnvironmentName(serverName, _),
             let .duplicateEnvironmentName(serverName, _),
             let .emptyHeaderName(serverName),
             let .invalidHeaderName(serverName, _),
             let .duplicateHeaderName(serverName, _):
            return name == serverName
        }
    }

    private static func isDeferredTemplateURLIssue(_ issue: ProjectMCPValidationIssue, server: ProjectMCPServer) -> Bool {
        guard case .invalidURL = issue else { return false }
        switch server.transport {
        case let .http(url, _), let .sse(url, _):
            return variableRegex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
        case .stdio:
            return false
        }
    }

    private static func hasValidResolvedWireServer(_ server: ACPMCPServer) -> Bool {
        let value: String?
        switch server {
        case let .stdio(_, command, _, _):
            let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
            return command == trimmedCommand && !trimmedCommand.isEmpty
        case let .http(_, url, _), let .sse(_, url, _):
            value = url
        }
        guard let value, value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.contains(where: \.isWhitespace),
              let url = URL(string: value), let host = url.host, !host.isEmpty else { return false }
        return url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https"
    }

    private static func makeWireServer(
        _ server: ProjectMCPServer,
        environment: [String: String]
    ) -> Result<ACPMCPServer, ResolutionError> {
        switch server.transport {
        case let .stdio(command, args, variables):
            guard let command = interpolate(command, environment: environment) else {
                return .failure(.missingVariable(firstMissingVariable(in: command, environment: environment)!))
            }
            var resolvedArgs: [String] = []
            for argument in args {
                guard let argument = interpolate(argument, environment: environment) else {
                    return .failure(.missingVariable(firstMissingVariable(in: argument, environment: environment)!))
                }
                resolvedArgs.append(argument)
            }
            var resolvedEnvironment: [ACPMCPKeyValue] = []
            for variable in variables {
                guard let value = interpolate(variable.value, environment: environment) else {
                    return .failure(.missingVariable(firstMissingVariable(in: variable.value, environment: environment)!))
                }
                resolvedEnvironment.append(.init(name: variable.name, value: value))
            }
            return .success(.stdio(name: server.name, command: command, args: resolvedArgs, env: resolvedEnvironment))

        case let .http(url, headers):
            return makeRemoteWireServer(name: server.name, url: url, headers: headers, environment: environment, type: .http)
        case let .sse(url, headers):
            return makeRemoteWireServer(name: server.name, url: url, headers: headers, environment: environment, type: .sse)
        }
    }

    private static func makeRemoteWireServer(
        name: String,
        url: String,
        headers: [MCPKeyValue],
        environment: [String: String],
        type: MCPTransportKind
    ) -> Result<ACPMCPServer, ResolutionError> {
        guard let url = interpolate(url, environment: environment) else {
            return .failure(.missingVariable(firstMissingVariable(in: url, environment: environment)!))
        }
        var resolvedHeaders: [ACPMCPKeyValue] = []
        for header in headers {
            guard let value = interpolate(header.value, environment: environment) else {
                return .failure(.missingVariable(firstMissingVariable(in: header.value, environment: environment)!))
            }
            resolvedHeaders.append(.init(name: header.name, value: value))
        }
        switch type {
        case .http:
            return .success(.http(name: name, url: url, headers: resolvedHeaders))
        case .sse:
            return .success(.sse(name: name, url: url, headers: resolvedHeaders))
        case .stdio:
            preconditionFailure("Remote server must use an HTTP transport")
        }
    }

    private static func interpolate(_ value: String, environment: [String: String]) -> String? {
        guard firstMissingVariable(in: value, environment: environment) == nil else { return nil }
        return replacingVariables(in: value, environment: environment)
    }

    private static func firstMissingVariable(in value: String, environment: [String: String]) -> String? {
        for match in variableMatches(in: value) where environment[match] == nil {
            return match
        }
        return nil
    }

    private static func replacingVariables(in value: String, environment: [String: String]) -> String {
        var result = value
        let matches = variableRegex.matches(in: value, range: NSRange(value.startIndex..., in: value))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result),
                  let nameRange = Range(match.range(at: 1), in: result),
                  let replacement = environment[String(result[nameRange])] else {
                continue
            }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    private static func variableMatches(in value: String) -> [String] {
        variableRegex.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: value) else { return nil }
            return String(value[range])
        }
    }

    private static let variableRegex = try! NSRegularExpression(pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}"#)
}

private extension MCPAttachmentPlanner {
    struct FingerprintDefinition: Encodable {
        let name: String
        let transport: FingerprintTransport

        init(_ server: ProjectMCPServer) {
            name = server.name
            transport = .init(server.transport)
        }
    }

    struct FingerprintKeyValue: Encodable {
        let name: String
        let value: String

        init(_ value: MCPKeyValue) {
            name = value.name
            self.value = value.value
        }
    }

    enum FingerprintTransport: Encodable {
        case stdio(command: String, args: [String], environment: [FingerprintKeyValue])
        case http(url: String, headers: [FingerprintKeyValue])
        case sse(url: String, headers: [FingerprintKeyValue])

        private enum CodingKeys: String, CodingKey {
            case kind
            case command
            case args
            case environment
            case url
            case headers
        }

        init(_ transport: ProjectMCPTransport) {
            switch transport {
            case let .stdio(command, args, environment):
                self = .stdio(command: command, args: args, environment: environment.map(FingerprintKeyValue.init))
            case let .http(url, headers):
                self = .http(url: url, headers: headers.map(FingerprintKeyValue.init))
            case let .sse(url, headers):
                self = .sse(url: url, headers: headers.map(FingerprintKeyValue.init))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .stdio(command, args, environment):
                try container.encode(MCPTransportKind.stdio, forKey: .kind)
                try container.encode(command, forKey: .command)
                try container.encode(args, forKey: .args)
                try container.encode(environment, forKey: .environment)
            case let .http(url, headers):
                try container.encode(MCPTransportKind.http, forKey: .kind)
                try container.encode(url, forKey: .url)
                try container.encode(headers, forKey: .headers)
            case let .sse(url, headers):
                try container.encode(MCPTransportKind.sse, forKey: .kind)
                try container.encode(url, forKey: .url)
                try container.encode(headers, forKey: .headers)
            }
        }
    }
}
