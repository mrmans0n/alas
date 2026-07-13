import Foundation

struct ACPRemoteNodeEnvironment: Equatable, Sendable {
    let npmPath: String
    let nodePath: String
    let binDirectory: String
}

enum ACPRemoteNodeEnvironmentError: Error, Equatable, Sendable {
    case missing
    case connectionFailure(String)
    case executionFailure(exitCode: Int32?, detail: String)
    case malformedOutput
}

extension ACPRemoteNodeEnvironmentError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missing:
            return "Node.js and npm are not available on the remote host."
        case let .connectionFailure(detail):
            return detail.isEmpty ? "Could not reach the host over SSH." : detail
        case let .executionFailure(_, detail):
            return detail.isEmpty ? "Remote Node.js discovery failed." : detail
        case .malformedOutput:
            return "Remote Node.js discovery returned malformed output."
        }
    }
}

struct ACPRemoteNodeEnvironmentResolver {
    typealias Runner = @Sendable (
        _ host: String,
        _ cwd: String?,
        _ command: String,
        _ pathPolicy: SSHCommand.PathPolicy
    ) async throws -> ProcessResult

    static let missingExitCode: Int32 = 20
    static let protocolBegin = "ALAS_NODE_ENV_V1_BEGIN"
    static let protocolEnd = "ALAS_NODE_ENV_V1_END"

    private let runner: Runner

    init(runner: @escaping Runner = { host, cwd, command, pathPolicy in
        try await RemoteExec.run(
            host: host,
            cwd: cwd,
            command: command,
            pathPolicy: pathPolicy
        )
    }) {
        self.runner = runner
    }

    func resolve(host: String) async throws -> ACPRemoteNodeEnvironment {
        let result: ProcessResult
        do {
            result = try await runner(host, nil, Self.discoveryCommand, .inherited)
        } catch {
            throw ACPRemoteNodeEnvironmentError.executionFailure(
                exitCode: nil,
                detail: error.localizedDescription
            )
        }

        if RemoteExec.isConnectionFailure(exitCode: result.exitCode) {
            throw ACPRemoteNodeEnvironmentError.connectionFailure(Self.trimmed(result.stderr))
        }

        switch result.exitCode {
        case 0:
            return try Self.parseResolved(result.stdout)
        case Self.missingExitCode:
            guard Self.isValidMissingOutput(result.stdout) else {
                throw ACPRemoteNodeEnvironmentError.malformedOutput
            }
            throw ACPRemoteNodeEnvironmentError.missing
        default:
            throw ACPRemoteNodeEnvironmentError.executionFailure(
                exitCode: result.exitCode,
                detail: Self.trimmed(result.stderr)
            )
        }
    }

    static let discoveryCommand: String = {
        let commonDirectories = [
            "$HOME/.local/bin",
            "$HOME/.npm-global/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/home/linuxbrew/.linuxbrew/bin",
            "/usr/bin",
            "/bin",
        ]
        let commonChecks = commonDirectories.map { directory in
            if directory.hasPrefix("$HOME") {
                return "try_dir \"\(directory)\""
            }
            return "try_dir \(SSHCommand.shellQuote(directory))"
        }.joined(separator: "\n")

        return """
        try_dir() {
            d=${1%/}
            case "$d" in
                /*) ;;
                *) return 1 ;;
            esac
            case "$d" in
                *'
        '*) return 1 ;;
            esac
            [ -x "$d/npm" ] && [ ! -d "$d/npm" ] || return 1
            [ -x "$d/node" ] && [ ! -d "$d/node" ] || return 1
            printf '%s\n' \
                '\(protocolBegin)' \
                'status=ok' \
                "npm=$d/npm" \
                "node=$d/node" \
                "bin=$d" \
                '\(protocolEnd)'
            exit 0
        }

        try_env_dir() {
            eval_value=$1
            [ -n "$eval_value" ] || return 1
            try_dir "$eval_value"
        }

        version_is_numeric() {
            LC_ALL=C awk -v version="$1" 'BEGIN {
                exit(version ~ /^[0-9]+([.][0-9]+)*$/ ? 0 : 1)
            }'
        }

        version_is_greater() {
            LC_ALL=C awk -v lhs="$1" -v rhs="$2" 'BEGIN {
                lhsCount = split(lhs, lhsParts, ".")
                rhsCount = split(rhs, rhsParts, ".")
                count = lhsCount > rhsCount ? lhsCount : rhsCount
                for (part = 1; part <= count; part++) {
                    lhsValue = part <= lhsCount ? lhsParts[part] + 0 : 0
                    rhsValue = part <= rhsCount ? rhsParts[part] + 0 : 0
                    if (lhsValue > rhsValue) exit 0
                    if (lhsValue < rhsValue) exit 1
                }
                exit 1
            }'
        }

        try_latest_version() {
            root=$1
            [ -d "$root" ] || return 1
            attempted='|'
            while :; do
                best_path=
                best_version=
                for candidate in "$root"/*; do
                    [ -d "$candidate" ] || continue
                    version=${candidate##*/}
                    version=${version#v}
                    version_is_numeric "$version" || continue
                    case "$attempted" in
                        *"|$version|"*) continue ;;
                    esac
                    if [ -z "$best_version" ] || version_is_greater "$version" "$best_version"; then
                        best_path=$candidate
                        best_version=$version
                    fi
                done
                [ -n "$best_path" ] || return 1
                try_dir "$best_path/bin"
                attempted="${attempted}${best_version}|"
            done
        }

        path_npm=$(command -v npm 2>/dev/null || :)
        case "$path_npm" in
            /*/npm) try_dir "${path_npm%/npm}" ;;
        esac

        try_env_dir "$NVM_BIN"
        if [ -n "$VOLTA_HOME" ]; then try_dir "$VOLTA_HOME/bin"; fi

        mise_root=${MISE_DATA_DIR:-"$HOME/.local/share/mise"}
        asdf_root=${ASDF_DATA_DIR:-"$HOME/.asdf"}
        volta_root=${VOLTA_HOME:-"$HOME/.volta"}
        nvm_root=${NVM_DIR:-"$HOME/.nvm"}

        try_dir "$mise_root/shims"
        try_dir "$asdf_root/shims"
        try_dir "$volta_root/bin"
        try_dir "$nvm_root/current/bin"
        try_latest_version "$mise_root/installs/node"
        try_latest_version "$asdf_root/installs/nodejs"
        try_latest_version "$nvm_root/versions/node"

        \(commonChecks)

        printf '%s\n' \
            '\(protocolBegin)' \
            'status=missing' \
            '\(protocolEnd)'
        exit \(missingExitCode)
        """
    }()

    private static func parseResolved(_ output: String) throws -> ACPRemoteNodeEnvironment {
        let fields = try parseFields(output)
        guard fields["status"] == "ok",
              fields.count == 4,
              let npmPath = fields["npm"],
              let nodePath = fields["node"],
              let binDirectory = fields["bin"],
              isValidAbsolutePath(npmPath),
              isValidAbsolutePath(nodePath),
              isValidAbsolutePath(binDirectory),
              npmPath == binDirectory + "/npm",
              nodePath == binDirectory + "/node"
        else {
            throw ACPRemoteNodeEnvironmentError.malformedOutput
        }
        return ACPRemoteNodeEnvironment(
            npmPath: npmPath,
            nodePath: nodePath,
            binDirectory: binDirectory
        )
    }

    private static func isValidMissingOutput(_ output: String) -> Bool {
        guard let fields = try? parseFields(output) else { return false }
        return fields.count == 1 && fields["status"] == "missing"
    }

    private static func parseFields(_ output: String) throws -> [String: String] {
        guard !output.contains("\r") else {
            throw ACPRemoteNodeEnvironmentError.malformedOutput
        }
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" {
            lines.removeLast()
        }
        guard lines.count >= 3,
              lines.first == protocolBegin,
              lines.last == protocolEnd
        else {
            throw ACPRemoteNodeEnvironmentError.malformedOutput
        }

        var fields: [String: String] = [:]
        for line in lines.dropFirst().dropLast() {
            guard !line.isEmpty, let separator = line.firstIndex(of: "=") else {
                throw ACPRemoteNodeEnvironmentError.malformedOutput
            }
            let key = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
            guard !key.isEmpty, !value.isEmpty, fields[key] == nil else {
                throw ACPRemoteNodeEnvironmentError.malformedOutput
            }
            fields[key] = value
        }
        return fields
    }

    private static func isValidAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\n") && path != "/"
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
