#!/usr/bin/env bash
set -euo pipefail

this_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${this_dir}/../../.." && pwd)"
script="${repo_root}/scripts/design_literals.py"
tmp="$(mktemp -d -t design-literals-test.XXXXXX)"
trap 'rm -rf "${tmp}"' EXIT

# Prints the total literal count for a single line of Swift.
count() {
    printf '%s\n' "$1" > "${tmp}/Fixture.swift"
    python3 "${script}" "${tmp}/Fixture.swift" | awk '/^total/ { print $2 }'
}

expect() {
    local want="$1" line="$2" got
    got="$(count "${line}")"
    if [ "${got}" != "${want}" ]; then
        echo "FAIL: expected ${want}, got ${got:-<none>} for: ${line}" >&2
        exit 1
    fi
}

expect 1 '.font(.system(size: 11))'
expect 1 '.padding(.horizontal, 8)'
expect 1 'RoundedRectangle(cornerRadius: 6)'
expect 1 'NSFont.systemFont(ofSize: 12)'
expect 0 '.padding(.horizontal, scale.space.m)'
expect 0 '.padding(8) // design-literal: optical inset'
expect 1 '.padding(8) // design-literal:'
expect 1 '.padding(8) // design-literal:   '

# --migrated fails while a listed path has a literal and passes once it has none.
printf '%s\n' '.padding(8)' > "${tmp}/Fixture.swift"
printf '# comment\n\n%s\n' "${tmp}/Fixture.swift" > "${tmp}/paths.txt"
if python3 "${script}" --migrated --paths-file "${tmp}/paths.txt" > /dev/null; then
    echo "FAIL: --migrated should exit 1 with one literal" >&2
    exit 1
fi
printf '%s\n' '.padding(scale.space.m)' > "${tmp}/Fixture.swift"
python3 "${script}" --migrated --paths-file "${tmp}/paths.txt" > /dev/null

echo "design-literals: ok"
