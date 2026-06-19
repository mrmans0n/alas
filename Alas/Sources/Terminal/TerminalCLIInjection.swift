import Foundation

enum TerminalCLIInjection {
    static let executableName = "alas"
    static let aoExecutableName = "ao"
    private static let fallbackPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func executableScript() -> String {
        return """
        #!/bin/sh
        if [ -z "${ALAS_SOCKET_PATH:-}" ] || [ -z "${ALAS_SESSION_ID:-}" ]; then
          printf '%s\n' 'alas: only available in Alas terminals' >&2
          exit 2
        fi

        usage_all() {
          printf '%s\n' 'usage: alas open <path> [path...]' >&2
          printf '%s\n' 'usage: alas wt list' >&2
          printf '%s\n' 'usage: alas wt switch <name-or-branch>' >&2
          printf '%s\n' 'usage: alas wt new <branch> [--base <ref>]' >&2
          printf '%s\n' 'usage: alas wt delete <name-or-branch> [--force] [--keep-branch]' >&2
          printf '%s\n' 'usage: alas review [pr-number-or-url]' >&2
        }

        usage_open() {
          printf '%s\n' 'usage: alas open <path> [path...]' >&2
        }

        usage_wt_list() {
          printf '%s\n' 'usage: alas wt list' >&2
        }

        usage_wt_switch() {
          printf '%s\n' 'usage: alas wt switch <name-or-branch>' >&2
        }

        usage_wt_new() {
          printf '%s\n' 'usage: alas wt new <branch> [--base <ref>]' >&2
        }

        usage_wt_delete() {
          printf '%s\n' 'usage: alas wt delete <name-or-branch> [--force] [--keep-branch]' >&2
        }

        usage_review() {
          printf '%s\n' 'usage: alas review [pr-number-or-url]' >&2
        }

        build_request() {
          /usr/bin/python3 - "$@" <<'PY'
        import json, os, sys

        session_id = sys.argv[1]
        command = sys.argv[2]
        payload = {"v": 1, "kind": "cli", "command": command, "session_id": session_id}

        if command == "open":
            base = os.environ.get("PWD") or os.getcwd()

            def resolve(path):
                if os.path.isabs(path):
                    return os.path.abspath(path)
                return os.path.abspath(os.path.join(base, path))

            payload["paths"] = [resolve(path) for path in sys.argv[3:]]
        elif command == "wt":
            subcommand = sys.argv[3]
            payload["subcommand"] = subcommand
            if subcommand == "switch":
                payload["target"] = sys.argv[4]
            elif subcommand == "new":
                payload["branch"] = sys.argv[4]
                if len(sys.argv) > 5 and sys.argv[5]:
                    payload["base"] = sys.argv[5]
            elif subcommand == "delete":
                payload["target"] = sys.argv[4]
                payload["force"] = sys.argv[5] == "1"
                payload["keep_branch"] = sys.argv[6] == "1"
        elif command == "review":
            if len(sys.argv) > 3:
                payload["target"] = sys.argv[3]
        else:
            raise SystemExit(1)

        print(json.dumps(payload))
        PY
        }

        send_request() {
          response=$(printf '%s\n' "$1" | /usr/bin/nc -U -w1 "$ALAS_SOCKET_PATH" 2>/dev/null)
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
            lines = response.get("lines") or []
            if isinstance(lines, list):
                for line in lines:
                    print(str(line))
            sys.exit(0)

        print("alas: " + str(response.get("error") or "request failed"), file=sys.stderr)
        sys.exit(1)
        PY
        }

        case "${1:-}" in
          open)
            shift
            if [ "$#" -eq 0 ]; then
              usage_open
              exit 2
            fi
            request=$(build_request "$ALAS_SESSION_ID" "open" "$@") || exit 1
            send_request "$request"
            ;;
          wt)
            shift
            case "${1:-}" in
              list)
                shift
                if [ "$#" -ne 0 ]; then
                  usage_wt_list
                  exit 2
                fi
                request=$(build_request "$ALAS_SESSION_ID" "wt" "list") || exit 1
                send_request "$request"
                ;;
              switch)
                shift
                if [ "$#" -ne 1 ]; then
                  usage_wt_switch
                  exit 2
                fi
                request=$(build_request "$ALAS_SESSION_ID" "wt" "switch" "$1") || exit 1
                send_request "$request"
                ;;
              new)
                shift
                if [ "$#" -lt 1 ]; then
                  usage_wt_new
                  exit 2
                fi
                case "$1" in
                  --*)
                    usage_wt_new
                    exit 2
                    ;;
                esac
                branch=$1
                base=
                shift
                while [ "$#" -gt 0 ]; do
                  case "$1" in
                    --base)
                      shift
                      if [ "$#" -eq 0 ]; then
                        usage_wt_new
                        exit 2
                      fi
                      case "$1" in
                        --*)
                          usage_wt_new
                          exit 2
                          ;;
                      esac
                      base=$1
                      shift
                      ;;
                    --*)
                      usage_wt_new
                      exit 2
                      ;;
                    *)
                      usage_wt_new
                      exit 2
                      ;;
                  esac
                done
                request=$(build_request "$ALAS_SESSION_ID" "wt" "new" "$branch" "$base") || exit 1
                send_request "$request"
                ;;
              delete)
                shift
                if [ "$#" -lt 1 ]; then
                  usage_wt_delete
                  exit 2
                fi
                case "$1" in
                  --*)
                    usage_wt_delete
                    exit 2
                    ;;
                esac
                target=$1
                force=0
                keep_branch=0
                shift
                while [ "$#" -gt 0 ]; do
                  case "$1" in
                    --force)
                      force=1
                      shift
                      ;;
                    --keep-branch)
                      keep_branch=1
                      shift
                      ;;
                    --*)
                      usage_wt_delete
                      exit 2
                      ;;
                    *)
                      usage_wt_delete
                      exit 2
                      ;;
                  esac
                done
                request=$(build_request "$ALAS_SESSION_ID" "wt" "delete" "$target" "$force" "$keep_branch") || exit 1
                send_request "$request"
                ;;
              *)
                usage_all
                exit 2
                ;;
            esac
            ;;
          review)
            shift
            if [ "$#" -gt 1 ]; then
              usage_review
              exit 2
            fi
            if [ "$#" -eq 0 ]; then
              request=$(build_request "$ALAS_SESSION_ID" "review") || exit 1
            else
              request=$(build_request "$ALAS_SESSION_ID" "review" "$1") || exit 1
            fi
            send_request "$request"
            ;;
          *)
            usage_all
            exit 2
            ;;
        esac
        """
    }

    /// One-line wrapper that delegates to `alas open`. Lives next to `alas` in
    /// the same bin dir that's prepended to the session PATH, so the inner
    /// `alas` lookup is guaranteed to hit Alas's own script. `exec` replaces
    /// the wrapper process so exit codes and signals propagate verbatim from
    /// `alas open`.
    static func aoExecutableScript() -> String {
        return """
        #!/bin/sh
        exec alas open "$@"
        """
    }

    /// Writes the `alas` and `ao` scripts into Alas's per-user bin dir and
    /// returns that directory. Callers prepend the returned path to the
    /// session PATH so both commands are visible to the spawned shell.
    /// Both scripts are written atomically, with `0o700` permissions, and
    /// only rewritten when their content differs from the desired script.
    static func installExecutables() throws -> URL {
        let dir = Paths.appSupportRoot.appendingPathComponent("bin", isDirectory: true)
        try Paths.ensureDirectoryExists(dir)
        try writeScript(executableScript(), named: executableName, into: dir)
        try writeScript(aoExecutableScript(), named: aoExecutableName, into: dir)
        return dir
    }

    private static func writeScript(_ script: String, named name: String, into dir: URL) throws {
        let url = dir.appendingPathComponent(name, isDirectory: false)
        if (try? String(contentsOf: url, encoding: .utf8)) != script {
            try script.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func pathValue(prepending directory: String, to current: String?) -> String {
        let basePath = current?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? current!
            : fallbackPath
        return "\(directory):\(basePath)"
    }
}
