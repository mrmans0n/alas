import Foundation

struct ACPResolvedRemoteAdapter: Equatable, Sendable {
    let adapterPath: String
    let nodeBinDirectory: String
}

enum ACPRemoteAdapterResolution: Equatable, Sendable {
    case ready(ACPResolvedRemoteAdapter)
    case missing(reason: String)
    case error(message: String)
}

enum ACPRemoteAdapterInstallError: Error, Equatable, Sendable {
    case unsupportedAgent(String)
    case prerequisite(String)
    case connectionFailure(String)
    case executionFailure(exitCode: Int32?, detail: String)
}

extension ACPRemoteAdapterInstallError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsupportedAgent(let agentID):
            return "Alas cannot install an ACP adapter for \(agentID)."
        case .prerequisite(let detail), .connectionFailure(let detail):
            return detail
        case .executionFailure(let exitCode, let detail):
            let prefix = exitCode.map { "Remote ACP adapter installation failed (exit \($0))." }
                ?? "Remote ACP adapter installation failed."
            return detail.isEmpty ? prefix : "\(prefix) \(detail)"
        }
    }
}

struct ACPRemoteAdapterManagement {
    typealias Runner = @Sendable (
        _ host: String,
        _ cwd: String?,
        _ command: String,
        _ pathPolicy: SSHCommand.PathPolicy,
        _ timeout: TimeInterval
    ) async throws -> ProcessResult
    typealias NodeResolver = @Sendable (_ host: String) async throws -> ACPRemoteNodeEnvironment

    static let managedPrefixRoot = "$HOME/.alas/acp"
    static let protocolBegin = "ALAS_ACP_ADAPTER_V1_BEGIN"
    static let protocolEnd = "ALAS_ACP_ADAPTER_V1_END"
    static let absentExitCode: Int32 = 30
    static let missingExitCode: Int32 = 31
    static let prerequisiteExitCode: Int32 = 32
    static let corruptExitCode: Int32 = 33
    static let stagingExitCode: Int32 = 34
    static let npmInstallExitCode: Int32 = 35
    static let stagedPackageExitCode: Int32 = 36
    static let stagedBinaryExitCode: Int32 = 37
    static let backupExitCode: Int32 = 38
    static let promotionExitCode: Int32 = 39
    static let promotedValidationExitCode: Int32 = 40
    static let rollbackExitCode: Int32 = 41
    static let backupCleanupExitCode: Int32 = 42
    static let promotionLockExitCode: Int32 = 43
    static let maximumInstallDetailLength = 2_048
    static let installTimeout: TimeInterval = 5 * 60

    private let runner: Runner
    private let nodeResolver: NodeResolver

    init(
        runner: @escaping Runner = { host, cwd, command, pathPolicy, timeout in
            try await RemoteExec.run(
                host: host,
                cwd: cwd,
                command: command,
                timeout: timeout,
                pathPolicy: pathPolicy
            )
        },
        nodeResolver: @escaping NodeResolver = { host in
            try await ACPRemoteNodeEnvironmentResolver().resolve(host: host)
        }
    ) {
        self.runner = runner
        self.nodeResolver = nodeResolver
    }

    func resolve(
        host: String,
        descriptor: ACPManagedAdapterDescriptor,
        setupCheck: ACPSetupCheck
    ) async -> ACPRemoteAdapterResolution {
        let environmentResult: Result<ACPRemoteNodeEnvironment, Error>
        do {
            environmentResult = .success(try await nodeResolver(host))
        } catch {
            environmentResult = .failure(error)
        }
        let managedNodeBin: String?
        if case .success(let environment) = environmentResult {
            managedNodeBin = environment.binDirectory
        } else {
            // A managed adapter can still run with Node on PATH when npm is
            // unavailable. Keep this fallback for existing installations.
            managedNodeBin = nil
        }
        let managedResult = await runProbe(
            host: host,
            command: Self.managedProbeCommand(
                descriptor: descriptor,
                nodeBinDirectory: managedNodeBin
            )
        )
        let managedResolution = classifyManagedProbe(
            managedResult,
            descriptor: descriptor,
            host: host
        )
        switch managedResolution {
        case .ready, .missing, .error:
            return managedResolution!
        case nil:
            break
        }

        let environment: ACPRemoteNodeEnvironment
        switch environmentResult {
        case .success(let resolved):
            environment = resolved
        case .failure(let error):
            guard Self.allowsPathFallback(descriptor: descriptor, setupCheck: setupCheck) else {
                return .error(message: error.localizedDescription)
            }
            let pathResult = await runProbe(
                host: host,
                command: Self.pathProbeCommand(descriptor: descriptor),
                pathPolicy: .augmented
            )
            let pathResolution = classifyAdapterProbe(pathResult, descriptor: descriptor, host: host)
            if case .ready = pathResolution {
                return pathResolution
            }
            return .error(message: error.localizedDescription)
        }

        let globalResult = await runProbe(
            host: host,
            command: Self.globalProbeCommand(
                descriptor: descriptor,
                setupCheck: setupCheck,
                environment: environment
            )
        )
        return classifyAdapterProbe(globalResult, descriptor: descriptor, host: host)
    }

    func install(host: String, descriptor: ACPManagedAdapterDescriptor) async throws {
        let environment: ACPRemoteNodeEnvironment
        do {
            environment = try await nodeResolver(host)
        } catch let error as ACPRemoteNodeEnvironmentError {
            throw Self.installPrerequisiteError(error)
        } catch {
            throw ACPRemoteAdapterInstallError.prerequisite(
                Self.safeInstallDetail(error.localizedDescription, fallback: "Node.js and npm are required on \(host).")
            )
        }

        let command = Self.installCommand(
            descriptor: descriptor,
            environment: environment,
            transactionID: UUID().uuidString.lowercased()
        )
        let result: ProcessResult
        do {
            result = try await runner(host, nil, command, .inherited, Self.installTimeout)
        } catch {
            throw ACPRemoteAdapterInstallError.executionFailure(
                exitCode: nil,
                detail: Self.safeInstallDetail(error.localizedDescription)
            )
        }
        if RemoteExec.isConnectionFailure(exitCode: result.exitCode) {
            throw ACPRemoteAdapterInstallError.connectionFailure(
                Self.safeInstallDetail(result.stderr, fallback: "Could not reach \(host) over SSH.")
            )
        }
        guard result.exitCode == 0 else {
            throw ACPRemoteAdapterInstallError.executionFailure(
                exitCode: result.exitCode,
                detail: Self.safeInstallDetail(result.stderr)
            )
        }
    }

    static func managedPrefix(for descriptor: ACPManagedAdapterDescriptor) -> String {
        "\(managedPrefixRoot)/\(descriptor.agentID)"
    }

    static func installCommand(
        descriptor: ACPManagedAdapterDescriptor,
        environment: ACPRemoteNodeEnvironment,
        transactionID: String
    ) -> String {
        let npm = SSHCommand.shellQuote(environment.npmPath)
        let nodeBin = SSHCommand.shellQuote(environment.binDirectory)
        let package = SSHCommand.shellQuote(descriptor.packageName)
        let binary = SSHCommand.shellQuote(descriptor.binaryName)
        let agent = SSHCommand.shellQuote(descriptor.agentID)
        let legacyCleanup = descriptor.legacyPackageNames.map {
            "\(npm) --prefix \"$stage\" uninstall -g \(SSHCommand.shellQuote($0)) >/dev/null 2>&1 || :"
        }.joined(separator: "\n")

        return """
        PATH=\(nodeBin):"$PATH"
        export PATH
        staging_root=$HOME/.alas/acp/.staging
        live=$HOME/.alas/acp/\(agent)
        stage="$staging_root/\(descriptor.agentID)-\(transactionID)"
        backup="$staging_root/\(descriptor.agentID)-backup-\(transactionID)"
        lock="$staging_root/.locks/\(descriptor.agentID).lock"
        lock_acquired=0
        package=\(package)
        binary=\(binary)
        cleanup_stage() {
            rm -rf "$stage" >/dev/null 2>&1 || :
            if [ "$lock_acquired" -eq 1 ]; then
                rm -f "$lock/pid" >/dev/null 2>&1 || :
                rmdir "$lock" >/dev/null 2>&1 || :
            fi
        }
        acquire_promotion_lock() {
            if mkdir "$lock"; then
                printf '%s\n' "$$" > "$lock/pid" || {
                    rm -f "$lock/pid" >/dev/null 2>&1 || :
                    rmdir "$lock" >/dev/null 2>&1 || :
                    return 1
                }
                return 0
            fi
            owner=$(cat "$lock/pid" 2>/dev/null || :)
            case "$owner" in
                *[!0-9]*|'')
                    printf '%s\n' "Remote ACP adapter install lock is initializing; retry shortly." >&2
                    ;;
                *)
                    if kill -0 "$owner" 2>/dev/null; then
                        printf '%s\n' "Remote ACP adapter install is already in progress." >&2
                    else
                        printf '%s\n' "A previous remote ACP adapter install was interrupted. Remove $lock after confirming no other Alas instance is installing this adapter, then retry." >&2
                    fi
                    ;;
            esac
            return 1
        }
        trap cleanup_stage EXIT
        trap 'exit 1' HUP INT TERM
        mkdir -p "$staging_root" || exit \(stagingExitCode)
        rm -rf "$stage" "$backup" >/dev/null 2>&1 || :
        mkdir "$stage" || exit \(stagingExitCode)
        \(legacyCleanup)
        \(npm) --prefix "$stage" install -g \(package) || exit \(npmInstallExitCode)
        [ -d "$stage/lib/node_modules/$package" ] || exit \(stagedPackageExitCode)
        [ -x "$stage/bin/$binary" ] && [ ! -d "$stage/bin/$binary" ] || exit \(stagedBinaryExitCode)

        mkdir -p "$staging_root/.locks" || exit \(stagingExitCode)
        acquire_promotion_lock || exit \(promotionLockExitCode)
        lock_acquired=1
        had_live=0
        if [ -e "$live" ] || [ -L "$live" ]; then
            mv "$live" "$backup" || exit \(backupExitCode)
            had_live=1
        fi
        if ! mv "$stage" "$live"; then
            rm -rf "$live" >/dev/null 2>&1 || :
            if [ "$had_live" -eq 1 ]; then
                mv "$backup" "$live" || exit \(rollbackExitCode)
            fi
            exit \(promotionExitCode)
        fi
        if [ ! -d "$live/lib/node_modules/$package" ] \
            || [ ! -x "$live/bin/$binary" ] \
            || [ -d "$live/bin/$binary" ]; then
            rm -rf "$live" >/dev/null 2>&1 || :
            if [ "$had_live" -eq 1 ]; then
                mv "$backup" "$live" || exit \(rollbackExitCode)
            fi
            exit \(promotedValidationExitCode)
        fi
        if [ "$had_live" -eq 1 ]; then
            rm -rf "$backup" || exit \(backupCleanupExitCode)
        fi
        trap - EXIT
        cleanup_stage
        """
    }

    static func managedProbeCommand(
        descriptor: ACPManagedAdapterDescriptor,
        nodeBinDirectory: String? = nil
    ) -> String {
        let prefix = managedPrefix(for: descriptor)
        let nodeLookup: String
        if let nodeBinDirectory {
            nodeLookup = """
            node_bin=\(SSHCommand.shellQuote(nodeBinDirectory))
            node="$node_bin/node"
            """
        } else {
            nodeLookup = """
            node=$(command -v node 2>/dev/null || :)
            case "$node" in
                /*/node) ;;
                *) \(emit(status: "prerequisite")); exit \(prerequisiteExitCode) ;;
            esac
            node_bin=${node%/node}
            """
        }
        return """
        prefix=\(prefix)
        adapter="$prefix/bin/\(descriptor.binaryName)"
        if [ ! -e "$prefix" ] && [ ! -L "$prefix" ]; then
            \(emit(status: "absent"))
            exit \(absentExitCode)
        fi
        if [ ! -d "$prefix" ] || [ ! -x "$adapter" ] || [ -d "$adapter" ]; then
            \(emit(status: "corrupt"))
            exit \(corruptExitCode)
        fi
        \(nodeLookup)
        [ -x "$node" ] && [ ! -d "$node" ] || {
            \(emit(status: "prerequisite"))
            exit \(prerequisiteExitCode)
        }
        \(emitReady(adapterExpression: "$adapter", nodeBinExpression: "$node_bin"))
        """
    }

    static func globalProbeCommand(
        descriptor: ACPManagedAdapterDescriptor,
        setupCheck: ACPSetupCheck,
        environment: ACPRemoteNodeEnvironment
    ) -> String {
        let npm = SSHCommand.shellQuote(environment.npmPath)
        let nodeBin = SSHCommand.shellQuote(environment.binDirectory)
        let package = SSHCommand.shellQuote(descriptor.packageName)
        let binary = SSHCommand.shellQuote(descriptor.binaryName)
        let allowsPathFallback = allowsPathFallback(descriptor: descriptor, setupCheck: setupCheck)

        let pathFallback = allowsPathFallback ? """
        path_adapter=$(command -v \(binary) 2>/dev/null || :)
        case "$path_adapter" in
            /*) [ -x "$path_adapter" ] && [ ! -d "$path_adapter" ] && {
                \(emitReady(adapterExpression: "$path_adapter", nodeBinExpression: "$node_bin"))
            } ;;
        esac
        """ : ""

        return """
        PATH=\(nodeBin):"$PATH"
        export PATH
        node_bin=\(nodeBin)
        root=$(\(npm) root -g 2>/dev/null) || {
            \(emit(status: "prerequisite"))
            exit \(prerequisiteExitCode)
        }
        prefix=$(\(npm) prefix -g 2>/dev/null) || {
            \(emit(status: "prerequisite"))
            exit \(prerequisiteExitCode)
        }
        package=\(package)
        binary=\(binary)
        if [ -n "$root" ] && [ -d "$root/$package" ] && [ -n "$prefix" ]; then
            global_adapter="$prefix/bin/$binary"
            if [ -x "$global_adapter" ] && [ ! -d "$global_adapter" ]; then
                \(emitReady(adapterExpression: "$global_adapter", nodeBinExpression: "$node_bin"))
            fi
            \(emit(status: "corrupt"))
            exit \(corruptExitCode)
        fi
        \(pathFallback)
        \(emit(status: "missing"))
        exit \(missingExitCode)
        """
    }

    static func pathProbeCommand(descriptor: ACPManagedAdapterDescriptor) -> String {
        let binary = SSHCommand.shellQuote(descriptor.binaryName)
        return """
        path_adapter=$(command -v \(binary) 2>/dev/null || :)
        node=$(command -v node 2>/dev/null || :)
        case "$path_adapter:$node" in
            /*:/*/node)
                if [ -x "$path_adapter" ] && [ ! -d "$path_adapter" ] &&
                    [ -x "$node" ] && [ ! -d "$node" ]; then
                    node_bin=${node%/node}
                    \(emitReady(adapterExpression: "$path_adapter", nodeBinExpression: "$node_bin"))
                fi
                ;;
        esac
        \(emit(status: "missing"))
        exit \(missingExitCode)
        """
    }

    private static func allowsPathFallback(
        descriptor: ACPManagedAdapterDescriptor,
        setupCheck: ACPSetupCheck
    ) -> Bool {
        guard case .binaryOnPathOrNpmPackage(let candidate, let npmPackage) = setupCheck else {
            return false
        }
        return candidate == descriptor.binaryName && npmPackage == descriptor.packageName
    }

    private func runProbe(
        host: String,
        command: String,
        pathPolicy: SSHCommand.PathPolicy = .inherited
    ) async -> Result<ProcessResult, Error> {
        do {
            return .success(try await runner(
                host,
                nil,
                command,
                pathPolicy,
                Process.defaultTimeout
            ))
        } catch {
            return .failure(error)
        }
    }

    private func classifyManagedProbe(
        _ result: Result<ProcessResult, Error>,
        descriptor: ACPManagedAdapterDescriptor,
        host: String
    ) -> ACPRemoteAdapterResolution? {
        switch result {
        case .failure(let error):
            return .error(message: "Could not inspect \(descriptor.binaryName) on \(host): \(error.localizedDescription)")
        case .success(let result):
            if RemoteExec.isConnectionFailure(exitCode: result.exitCode) {
                return .error(message: connectionMessage(result.stderr, host: host))
            }
            switch result.exitCode {
            case 0:
                return parseReady(result.stdout).map(ACPRemoteAdapterResolution.ready)
                    ?? .error(message: malformedMessage(descriptor, host: host))
            case Self.absentExitCode:
                return hasStatus("absent", output: result.stdout)
                    ? nil
                    : .error(message: malformedMessage(descriptor, host: host))
            case Self.prerequisiteExitCode:
                return hasStatus("prerequisite", output: result.stdout)
                    ? .error(message: "Node.js is required to run \(descriptor.binaryName) on \(host).")
                    : .error(message: malformedMessage(descriptor, host: host))
            case Self.corruptExitCode:
                return hasStatus("corrupt", output: result.stdout)
                    ? .error(message: "The managed \(descriptor.binaryName) installation on \(host) is incomplete.")
                    : .error(message: malformedMessage(descriptor, host: host))
            default:
                return .error(message: executionMessage(result, descriptor: descriptor, host: host))
            }
        }
    }

    private func classifyAdapterProbe(
        _ result: Result<ProcessResult, Error>,
        descriptor: ACPManagedAdapterDescriptor,
        host: String
    ) -> ACPRemoteAdapterResolution {
        switch result {
        case .failure(let error):
            return .error(message: "Could not inspect \(descriptor.binaryName) on \(host): \(error.localizedDescription)")
        case .success(let result):
            if RemoteExec.isConnectionFailure(exitCode: result.exitCode) {
                return .error(message: connectionMessage(result.stderr, host: host))
            }
            switch result.exitCode {
            case 0:
                return parseReady(result.stdout).map(ACPRemoteAdapterResolution.ready)
                    ?? .error(message: malformedMessage(descriptor, host: host))
            case Self.missingExitCode:
                return hasStatus("missing", output: result.stdout)
                    ? .missing(reason: "\(descriptor.binaryName) is not installed on \(host).")
                    : .error(message: malformedMessage(descriptor, host: host))
            case Self.prerequisiteExitCode:
                return hasStatus("prerequisite", output: result.stdout)
                    ? .error(message: "The remote Node.js/npm environment on \(host) is unusable.")
                    : .error(message: malformedMessage(descriptor, host: host))
            case Self.corruptExitCode:
                return hasStatus("corrupt", output: result.stdout)
                    ? .error(message: "The global \(descriptor.packageName) installation on \(host) is incomplete.")
                    : .error(message: malformedMessage(descriptor, host: host))
            default:
                return .error(message: executionMessage(result, descriptor: descriptor, host: host))
            }
        }
    }

    private func parseReady(_ output: String) -> ACPResolvedRemoteAdapter? {
        guard let fields = parseFields(output), fields.count == 3,
              fields["status"] == "ready",
              let adapter = fields["adapter"], isAbsolutePath(adapter),
              let nodeBin = fields["nodeBin"], isAbsolutePath(nodeBin)
        else { return nil }
        return ACPResolvedRemoteAdapter(adapterPath: adapter, nodeBinDirectory: nodeBin)
    }

    private func hasStatus(_ status: String, output: String) -> Bool {
        guard let fields = parseFields(output) else { return false }
        return fields.count == 1 && fields["status"] == status
    }

    private func parseFields(_ output: String) -> [String: String]? {
        guard !output.contains("\r") else { return nil }
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        guard lines.count >= 3, lines.first == Self.protocolBegin, lines.last == Self.protocolEnd else {
            return nil
        }
        var fields: [String: String] = [:]
        for line in lines.dropFirst().dropLast() {
            guard let separator = line.firstIndex(of: "="), separator != line.startIndex else { return nil }
            let key = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
            guard !value.isEmpty, fields[key] == nil else { return nil }
            fields[key] = value
        }
        return fields
    }

    private func isAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/") && path != "/" && !path.contains("\n")
    }

    private func malformedMessage(_ descriptor: ACPManagedAdapterDescriptor, host: String) -> String {
        "Remote \(descriptor.binaryName) discovery returned malformed output from \(host)."
    }

    private func connectionMessage(_ stderr: String, host: String) -> String {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "Could not reach \(host) over SSH." : detail
    }

    private func executionMessage(
        _ result: ProcessResult,
        descriptor: ACPManagedAdapterDescriptor,
        host: String
    ) -> String {
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty
            ? "Remote \(descriptor.binaryName) discovery failed on \(host) (exit \(result.exitCode))."
            : detail
    }

    private static func emit(status: String) -> String {
        "printf '%s\\n' '\(protocolBegin)' 'status=\(status)' '\(protocolEnd)'"
    }

    private static func installPrerequisiteError(
        _ error: ACPRemoteNodeEnvironmentError
    ) -> ACPRemoteAdapterInstallError {
        switch error {
        case .connectionFailure(let detail):
            return .connectionFailure(safeInstallDetail(detail, fallback: "Could not reach the host over SSH."))
        case .missing:
            return .prerequisite("Node.js and npm are required on the remote host.")
        case .executionFailure, .malformedOutput:
            return .prerequisite(safeInstallDetail(error.localizedDescription))
        }
    }

    private static func safeInstallDetail(_ value: String, fallback: String = "") -> String {
        let sanitized = value.unicodeScalars.map { scalar -> Character in
            if scalar == "\n" || scalar == "\t" || scalar.value >= 0x20 {
                return Character(scalar)
            }
            return " "
        }
        let detail = String(sanitized)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = String(detail.prefix(maximumInstallDetailLength))
        return bounded.isEmpty ? fallback : bounded
    }

    private static func emitReady(adapterExpression: String, nodeBinExpression: String) -> String {
        """
        printf '%s\\n' \\
            '\(protocolBegin)' \\
            'status=ready' \\
            "adapter=\(adapterExpression)" \\
            "nodeBin=\(nodeBinExpression)" \\
            '\(protocolEnd)'
        exit 0
        """
    }
}
