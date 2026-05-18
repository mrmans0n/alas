import Foundation

enum TerminalCLIInjection {
    static func script(forShell shell: String) -> String? {
        let basename = (shell as NSString).lastPathComponent
        guard basename == "zsh" || basename == "bash" else { return nil }
        return """
        alas() {
          if [ -z "${ALAS_SOCKET_PATH:-}" ] || [ -z "${ALAS_SESSION_ID:-}" ]; then
            printf '%s\n' 'alas: only available in Alas terminals' >&2
            return 2
          fi
          case "${1:-}" in
            open)
              shift
              if [ "$#" -eq 0 ]; then
                printf '%s\n' 'usage: alas open <path> [path...]' >&2
                return 2
              fi
              response=$(/usr/bin/python3 - "$ALAS_SESSION_ID" "$@" <<'PY' | /usr/bin/nc -U -w1 "$ALAS_SOCKET_PATH"
        import json, os, sys
        session_id = sys.argv[1]
        paths = [os.path.abspath(path) for path in sys.argv[2:]]
        print(json.dumps({"v": 1, "kind": "cli", "command": "open", "session_id": session_id, "paths": paths}))
        PY
        )
              status=$?
              if [ "$status" -ne 0 ]; then
                printf '%s\n' 'alas: could not reach Alas' >&2
                return "$status"
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
              return 2
              ;;
          esac
        }
        """
    }

    static func compose(
        shell: String,
        userStartupScript: String,
        startupScriptSuffix: String?
    ) -> String {
        [script(forShell: shell), userStartupScript, startupScriptSuffix]
            .compactMap { part in
                let trimmed = part?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: "\n")
    }
}
