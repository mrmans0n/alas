#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/prune-xcode-state.sh [--delete] [--derived-data PATH]

Prune stale Xcode DerivedData directories for Alas and vendored Ghostty
projects. By default this is a dry run; pass --delete to remove entries.

Options:
  --delete             Remove stale entries instead of only printing them.
  --derived-data PATH  DerivedData root to scan.
                       Default: ~/Library/Developer/Xcode/DerivedData
  -h, --help           Show this help.
EOF
}

delete=0
derived_data="${HOME}/Library/Developer/Xcode/DerivedData"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --delete)
            delete=1
            shift
            ;;
        --derived-data)
            [ "$#" -ge 2 ] || { echo "prune-xcode-state.sh: --derived-data requires a path" >&2; exit 2; }
            derived_data="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "prune-xcode-state.sh: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ ! -d "${derived_data}" ]; then
    echo "prune-xcode-state.sh: DerivedData root does not exist: ${derived_data}" >&2
    exit 1
fi

read_workspace_path() {
    local plist="$1"
    /usr/libexec/PlistBuddy -c 'Print :WorkspacePath' "${plist}"
}

format_size() {
    local path="$1"
    du -sh "${path}" 2>/dev/null | awk '{print $1}'
}

scan_entry() {
    local entry="$1"
    local base plist workspace reason size action

    base="$(basename "${entry}")"
    case "${base}" in
        Alas-*|Ghostty-*) ;;
        *) return 0 ;;
    esac

    plist="${entry}/info.plist"
    if [ ! -f "${plist}" ]; then
        reason="missing-info-plist"
        size="$(format_size "${entry}")"
        [ -n "${size}" ] || size="unknown-size"
        printf 'skip\t%s\t%s\t%s\n' "${size}" "${reason}" "${entry}"
        return 0
    else
        if ! workspace="$(read_workspace_path "${plist}" 2>/dev/null)"; then
            reason="unreadable-info-plist"
            size="$(format_size "${entry}")"
            [ -n "${size}" ] || size="unknown-size"
            printf 'skip\t%s\t%s\t%s\n' "${size}" "${reason}" "${entry}"
            return 0
        elif [ -z "${workspace}" ]; then
            reason="empty-workspace-path"
            size="$(format_size "${entry}")"
            [ -n "${size}" ] || size="unknown-size"
            printf 'skip\t%s\t%s\t%s\n' "${size}" "${reason}" "${entry}"
            return 0
        elif [ ! -e "${workspace}" ]; then
            reason="missing-workspace:${workspace}"
        else
            return 0
        fi
    fi

    size="$(format_size "${entry}")"
    [ -n "${size}" ] || size="unknown-size"

    if [ "${delete}" -eq 1 ]; then
        rm -rf "${entry}"
        action="deleted"
    else
        action="delete"
    fi

    printf '%s\t%s\t%s\t%s\n' "${action}" "${size}" "${reason}" "${entry}"
}

delete_candidates=0
skipped=0
while IFS= read -r -d '' entry; do
    if scan_output="$(scan_entry "${entry}")" && [ -n "${scan_output}" ]; then
        printf '%s\n' "${scan_output}"
        case "${scan_output}" in
            delete*|deleted*) delete_candidates=$((delete_candidates + 1)) ;;
            skip*) skipped=$((skipped + 1)) ;;
        esac
    fi
done < <(/usr/bin/find "${derived_data}" -maxdepth 1 -mindepth 1 -type d -print0)

if [ "${delete_candidates}" -eq 0 ] && [ "${skipped}" -eq 0 ]; then
    echo "No stale Alas/Ghostty DerivedData entries found."
elif [ "${delete}" -eq 0 ]; then
    if [ "${delete_candidates}" -gt 0 ]; then
        echo "Dry run only. Re-run with --delete to remove entries marked delete."
    fi
    if [ "${skipped}" -gt 0 ]; then
        echo "Entries marked skip were not readable enough to classify safely."
    fi
fi
