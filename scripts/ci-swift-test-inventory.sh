#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: ci-swift-test-inventory.sh [--root PATH] --quarantine PATH (--validate | --batch N --batch-count N)

Discovers Swift Testing suites that contain @Test declarations. Every suite must
be scheduled or listed in the quarantine file as: suite<TAB>reason.
EOF
    exit 2
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tests_root="${repo_root}/AlasTests"
quarantine="${repo_root}/scripts/ci-swift-test-quarantine.tsv"
mode=""
batch=""
batch_count=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --root) tests_root="$2"; shift 2 ;;
        --quarantine) quarantine="$2"; shift 2 ;;
        --validate) mode="validate"; shift ;;
        --batch) batch="$2"; shift 2 ;;
        --batch-count) batch_count="$2"; shift 2 ;;
        *) usage ;;
    esac
done

[ -d "${tests_root}" ] || { echo "test root does not exist: ${tests_root}" >&2; exit 1; }
[ -f "${quarantine}" ] || { echo "quarantine does not exist: ${quarantine}" >&2; exit 1; }

if [ -n "${mode}" ]; then
    [ -z "${batch}" ] && [ -z "${batch_count}" ] || usage
else
    [ -n "${batch}" ] && [ -n "${batch_count}" ] || usage
    [[ "${batch}" =~ ^[0-9]+$ ]] && [[ "${batch_count}" =~ ^[1-9][0-9]*$ ]] || usage
    [ "${batch}" -lt "${batch_count}" ] || usage
fi

suite_file="$(mktemp)"
quarantine_file="$(mktemp)"
trap 'rm -f "${suite_file}" "${quarantine_file}"' EXIT

# Swift Testing suites in Alas use a conventional *Tests nominal type. A suite
# is discoverable only when that type owns an @Test declaration; empty fixture
# types cannot become stale xcodebuild selectors.
while IFS= read -r source; do
    awk '
        /^[[:space:]]*(@[A-Za-z_][A-Za-z0-9_]*(\([^)]*\))?[[:space:]]+)*((public|private|internal|fileprivate|open)[[:space:]]+)?(final[[:space:]]+)?(struct|class|actor|enum)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*Tests([[:space:]:{(]|$)/ {
            name = $0
            sub(/.*(struct|class|actor|enum)[[:space:]]+/, "", name)
            sub(/[^A-Za-z0-9_].*/, "", name)
            suite = name
        }
        /@Test([[:space:](]|$)/ && suite != "" { print suite }
    ' "${source}"
done < <(find "${tests_root}" -type f -name '*.swift' -print | sort) | sort -u > "${suite_file}"

while IFS=$'\t' read -r suite reason extra; do
    [ -n "${suite}" ] || continue
    [ -n "${reason}" ] && [ -z "${extra}" ] || {
        echo "invalid quarantine entry for ${suite}: expected suite<TAB>reason" >&2
        exit 1
    }
    printf '%s\n' "${suite}"
done < "${quarantine}" | sort -u > "${quarantine_file}"

if [ "$(wc -l < "${quarantine_file}" | tr -d ' ')" != "$(grep -cv '^[[:space:]]*$' "${quarantine}" || true)" ]; then
    echo "quarantine contains duplicate or blank entries" >&2
    exit 1
fi

while IFS= read -r suite; do
    if ! grep -Fxq "${suite}" "${suite_file}"; then
        echo "stale quarantine suite: ${suite}" >&2
        exit 1
    fi
done < "${quarantine_file}"

scheduled_file="$(mktemp)"
trap 'rm -f "${suite_file}" "${quarantine_file}" "${scheduled_file}"' EXIT
comm -23 "${suite_file}" "${quarantine_file}" > "${scheduled_file}"

discovered="$(wc -l < "${suite_file}" | tr -d ' ')"
quarantined="$(wc -l < "${quarantine_file}" | tr -d ' ')"
scheduled="$(wc -l < "${scheduled_file}" | tr -d ' ')"

if [ "${mode}" = "validate" ]; then
    printf 'discovered=%s scheduled=%s quarantined=%s\n' "${discovered}" "${scheduled}" "${quarantined}"
    exit 0
fi

awk -v batch="${batch}" -v count="${batch_count}" '
    (NR - 1) % count == batch { print "-only-testing AlasTests/" $0 }
' "${scheduled_file}"
