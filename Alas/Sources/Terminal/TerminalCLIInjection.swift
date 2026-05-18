import Foundation

enum TerminalCLIInjection {
    static let executableName = "alas"
    private static let fallbackPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func executableScript() -> String {
        return """
        #!/bin/sh
        if [ -z "${ALAS_SOCKET_PATH:-}" ] || [ -z "${ALAS_SESSION_ID:-}" ]; then
          printf '%s\n' 'alas: only available in Alas terminals' >&2
          exit 2
        fi

        case "${1:-}" in
          open)
            shift
            if [ "$#" -eq 0 ]; then
              printf '%s\n' 'usage: alas open <path> [path...]' >&2
              exit 2
            fi
            response=$(/usr/bin/python3 - "$ALAS_SESSION_ID" "$@" <<'PY' | /usr/bin/nc -U -w1 "$ALAS_SOCKET_PATH" 2>/dev/null
        import json, os, sys
        session_id = sys.argv[1]
        base = os.environ.get("PWD") or os.getcwd()
        def resolve(path):
            if os.path.isabs(path):
                return os.path.abspath(path)
            return os.path.abspath(os.path.join(base, path))
        paths = [resolve(path) for path in sys.argv[2:]]
        print(json.dumps({"v": 1, "kind": "cli", "command": "open", "session_id": session_id, "paths": paths}))
        PY
        )
            alas_status=$?
            if [ "$alas_status" -ne 0 ]; then
              printf '%s\n' 'alas: could not reach Alas' >&2
              exit "$alas_status"
            fi
            /usr/bin/python3 - "$response" <<'PY'
        import json, sys
        try:
            response = json.loads(sys.argv[1] or "{}")
        except Exception:
            print("alas: malformed response from Alas", file=sys.stderr)
            sys.exit(1)
        if response.get("ok") is True:
            sys.exit(0)
        print("alas: " + str(response.get("error") or "request failed"), file=sys.stderr)
        sys.exit(1)
        PY
            ;;
          *)
            printf '%s\n' 'usage: alas open <path> [path...]' >&2
            exit 2
            ;;
        esac
        """
    }

    static func installExecutable() throws -> URL {
        let dir = Paths.appSupportRoot.appendingPathComponent("bin", isDirectory: true)
        try Paths.ensureDirectoryExists(dir)
        let url = dir.appendingPathComponent(executableName, isDirectory: false)
        let script = executableScript()
        if (try? String(contentsOf: url, encoding: .utf8)) != script {
            try script.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    static func pathValue(prepending directory: String, to current: String?) -> String {
        let basePath = current?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? current!
            : fallbackPath
        return "\(directory):\(basePath)"
    }
}
