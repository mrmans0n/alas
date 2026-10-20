#!/usr/bin/env bash
set -euo pipefail
this_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${this_dir}/../../.." && pwd)"
check="${repo_root}/scripts/check-alascore-layers.py"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

sources="${tmp}/AlasCore"
mkdir -p "${sources}/Helpers" "${sources}/Core"
cat > "${sources}/Core/Host.swift" <<'SWIFT'
public struct HostThing {}
SWIFT
cat > "${sources}/Helpers/Low.swift" <<'SWIFT'
public struct LowThing { let host: HostThing }
SWIFT
allowlist="${tmp}/allowlist.txt"

# A lower module naming a higher module's type fails, naming both.
: > "${allowlist}"
if python3 -I "${check}" --sources "${sources}" --allowlist "${allowlist}" > "${tmp}/out" 2>&1; then
    echo "accepted an upward reference" >&2; exit 1
fi
grep -Fq "Helpers/Low.swift: HostThing (AlasFoundation -> AlasHostCore)" "${tmp}/out"

# Listed, it passes; the higher module naming the lower one never fails.
echo "Helpers/Low.swift HostThing" > "${allowlist}"
python3 -I "${check}" --sources "${sources}" --allowlist "${allowlist}" > /dev/null

# Once fixed, the stale entry fails until it is removed.
cat > "${sources}/Helpers/Low.swift" <<'SWIFT'
public struct LowThing {}
SWIFT
if python3 -I "${check}" --sources "${sources}" --allowlist "${allowlist}" > "${tmp}/out" 2>&1; then
    echo "kept a stale allowlist entry" >&2; exit 1
fi
grep -Fq "'Helpers/Low.swift HostThing' is no longer a violation" "${tmp}/out"

# A folder without a module fails.
: > "${allowlist}"
mkdir -p "${sources}/Mystery"
echo 'struct M {}' > "${sources}/Mystery/M.swift"
if python3 -I "${check}" --sources "${sources}" --allowlist "${allowlist}" > "${tmp}/out" 2>&1; then
    echo "accepted a folder without a module" >&2; exit 1
fi
grep -Fq "Mystery belongs to no module" "${tmp}/out"

# The repository's own sources match their allowlist.
python3 -I "${check}"
echo "alascore-layers tests: ok"
