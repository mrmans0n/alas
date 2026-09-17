#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: ci-swift-test-inventory.sh [--root PATH] [--quarantine PATH] [--write-dir PATH] (--validate | --batch N --batch-count N) [--lane ordinary|subprocess]

Discovers Swift Testing suites that contain @Test declarations. Every suite must
be scheduled or listed in the quarantine file as: suite<TAB>reason.
EOF
    exit 2
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tests_root="${repo_root}/AlasTests"
quarantine="${repo_root}/scripts/ci-swift-test-quarantine.tsv"
write_dir=""
mode=""
batch=""
batch_count=""
lane="ordinary"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --root) tests_root="$2"; shift 2 ;;
        --quarantine) quarantine="$2"; shift 2 ;;
        --write-dir) write_dir="$2"; shift 2 ;;
        --validate) mode="validate"; shift ;;
        --batch) batch="$2"; shift 2 ;;
        --batch-count) batch_count="$2"; shift 2 ;;
        --lane) lane="$2"; shift 2 ;;
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

case "${lane}" in
    ordinary|subprocess) ;;
    *) usage ;;
esac

suite_file="$(mktemp)"
quarantine_file="$(mktemp)"
trap 'rm -f "${suite_file}" "${quarantine_file}"' EXIT

# Swift Testing suites in Alas use a conventional *Tests nominal type. A suite
# is discoverable only when that type owns an @Test declaration; empty fixture
# types cannot become stale xcodebuild selectors.
while IFS= read -r source; do
    awk '
        function consume_attribute_arguments(line,    i, c) {
            for (i = 1; i <= length(line); i++) {
                c = substr(line, i, 1)
                if (attribute_block_comment) {
                    if (c == "*" && substr(line, i + 1, 1) == "/") {
                        attribute_block_comment = 0
                        i++
                    }
                    continue
                }
                if (attribute_in_string) {
                    if (attribute_escaped) {
                        attribute_escaped = 0
                    } else if (c == "\\") {
                        attribute_escaped = 1
                    } else if (c == "\"") {
                        attribute_in_string = 0
                    }
                    continue
                }
                if (c == "/" && substr(line, i + 1, 1) == "/") {
                    return ""
                }
                if (c == "/" && substr(line, i + 1, 1) == "*") {
                    attribute_block_comment = 1
                    i++
                    continue
                }
                if (c == "\"") {
                    attribute_in_string = 1
                    continue
                }
                if (c == "(") {
                    attribute_depth++
                } else if (c == ")") {
                    attribute_depth--
                    if (attribute_depth == 0) {
                        attribute_in_string = 0
                        attribute_escaped = 0
                        attribute_block_comment = 0
                        return substr(line, i + 1)
                    }
                }
            }
            return ""
        }
        function strip_attributes(line) {
            if (attribute_depth > 0) {
                line = consume_attribute_arguments(line)
                if (attribute_depth > 0) {
                    return ""
                }
                sub(/^[[:space:]]*/, "", line)
            }
            while (line ~ /^[[:space:]]*@[A-Za-z_][A-Za-z0-9_]*/) {
                sub(/^[[:space:]]*@[A-Za-z_][A-Za-z0-9_]*/, "", line)
                sub(/^[[:space:]]*/, "", line)
                if (substr(line, 1, 1) == "(") {
                    attribute_depth = 0
                    attribute_in_string = 0
                    attribute_escaped = 0
                    attribute_block_comment = 0
                    line = consume_attribute_arguments(line)
                    if (attribute_depth > 0) {
                        return ""
                    }
                }
                sub(/^[[:space:]]*/, "", line)
            }
            return line
        }
        {
            candidate = strip_attributes($0)
        }
        candidate ~ /^((public|private|internal|fileprivate|open)[[:space:]]+)?(final[[:space:]]+)?(struct|class|actor|enum)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*Tests([[:space:]:{(]|$)/ {
            name = candidate
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
ordinary_file="$(mktemp)"
subprocess_file="$(mktemp)"
subprocess_candidates_file="$(mktemp)"
trap 'rm -f "${suite_file}" "${quarantine_file}" "${scheduled_file}" "${ordinary_file}" "${subprocess_file}" "${subprocess_candidates_file}"' EXIT
comm -23 "${suite_file}" "${quarantine_file}" > "${scheduled_file}"

# macos-26 has hung when four or more subprocess-heavy suites share one
# xcodebuild invocation. Keep these suites out of the ordinary batches; the
# runner executes this lane in groups of at most three. Source references to
# Process are behavior evidence; shared Git-backed fixture names catch suites
# whose subprocess use is hidden behind helpers. The name pattern is a fallback
# so a newly added process-facing suite joins the protected lane without a
# workflow edit.
{
    grep -E 'Git|Process|RunScript|Terminal|SSH|Shell|CLI|Hook|Zmx|BeautifulMermaid|WorkspaceEditExecutor' "${scheduled_file}" || true
    while IFS= read -r source; do
        grep -Eq '\<Process([.(]|[A-Za-z_]*(Runner|Launcher|Executor))|CheckpointTestRepository|makeCleanupFixture' "${source}" || continue
        awk '
            function consume_attribute_arguments(line,    i, c) {
                for (i = 1; i <= length(line); i++) {
                    c = substr(line, i, 1)
                    if (attribute_block_comment) {
                        if (c == "*" && substr(line, i + 1, 1) == "/") {
                            attribute_block_comment = 0
                            i++
                        }
                        continue
                    }
                    if (attribute_in_string) {
                        if (attribute_escaped) {
                            attribute_escaped = 0
                        } else if (c == "\\") {
                            attribute_escaped = 1
                        } else if (c == "\"") {
                            attribute_in_string = 0
                        }
                        continue
                    }
                    if (c == "/" && substr(line, i + 1, 1) == "/") {
                        return ""
                    }
                    if (c == "/" && substr(line, i + 1, 1) == "*") {
                        attribute_block_comment = 1
                        i++
                        continue
                    }
                    if (c == "\"") {
                        attribute_in_string = 1
                        continue
                    }
                    if (c == "(") {
                        attribute_depth++
                    } else if (c == ")") {
                        attribute_depth--
                        if (attribute_depth == 0) {
                            attribute_in_string = 0
                            attribute_escaped = 0
                            attribute_block_comment = 0
                            return substr(line, i + 1)
                        }
                    }
                }
                return ""
            }
            function strip_attributes(line) {
                if (attribute_depth > 0) {
                    line = consume_attribute_arguments(line)
                    if (attribute_depth > 0) {
                        return ""
                    }
                    sub(/^[[:space:]]*/, "", line)
                }
                while (line ~ /^[[:space:]]*@[A-Za-z_][A-Za-z0-9_]*/) {
                    sub(/^[[:space:]]*@[A-Za-z_][A-Za-z0-9_]*/, "", line)
                    sub(/^[[:space:]]*/, "", line)
                    if (substr(line, 1, 1) == "(") {
                        attribute_depth = 0
                        attribute_in_string = 0
                        attribute_escaped = 0
                        attribute_block_comment = 0
                        line = consume_attribute_arguments(line)
                        if (attribute_depth > 0) {
                            return ""
                        }
                    }
                    sub(/^[[:space:]]*/, "", line)
                }
                return line
            }
            {
                candidate = strip_attributes($0)
            }
            candidate ~ /^((public|private|internal|fileprivate|open)[[:space:]]+)?(final[[:space:]]+)?(struct|class|actor|enum)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*Tests([[:space:]:{(]|$)/ {
                name = candidate
                sub(/.*(struct|class|actor|enum)[[:space:]]+/, "", name)
                sub(/[^A-Za-z0-9_].*/, "", name)
                print name
            }
        ' "${source}"
    done < <(find "${tests_root}" -type f -name '*.swift' -print | sort)
} | sort -u > "${subprocess_candidates_file}"
comm -12 "${scheduled_file}" "${subprocess_candidates_file}" > "${subprocess_file}"
comm -23 "${scheduled_file}" "${subprocess_file}" > "${ordinary_file}"

discovered="$(wc -l < "${suite_file}" | tr -d ' ')"
quarantined="$(wc -l < "${quarantine_file}" | tr -d ' ')"
scheduled="$(wc -l < "${scheduled_file}" | tr -d ' ')"
ordinary="$(wc -l < "${ordinary_file}" | tr -d ' ')"
subprocess="$(wc -l < "${subprocess_file}" | tr -d ' ')"

if [ "${mode}" = "validate" ]; then
    if [ -n "${write_dir}" ]; then
        mkdir -p "${write_dir}"
        cp "${ordinary_file}" "${write_dir}/ordinary.txt"
        cp "${subprocess_file}" "${write_dir}/subprocess.txt"
        cp "${scheduled_file}" "${write_dir}/scheduled.txt"
        cp "${quarantine_file}" "${write_dir}/quarantined.txt"
    fi
    printf 'discovered=%s scheduled=%s ordinary=%s subprocess=%s quarantined=%s\n' \
        "${discovered}" "${scheduled}" "${ordinary}" "${subprocess}" "${quarantined}"
    exit 0
fi

if [ "${lane}" = "subprocess" ]; then
    sed 's|^|-only-testing AlasTests/|' "${subprocess_file}"
    exit 0
fi

awk -v batch="${batch}" -v count="${batch_count}" '
    (NR - 1) % count == batch { print "-only-testing AlasTests/" $0 }
' "${ordinary_file}"
