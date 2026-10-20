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

# A call of a higher module's top-level function counts as well.
cat > "${sources}/Core/Fetch.swift" <<'SWIFT'
public func hostFetch() {}
SWIFT
cat > "${sources}/Helpers/Low.swift" <<'SWIFT'
public struct LowThing { func run() { hostFetch() } }
SWIFT
: > "${allowlist}"
if python3 -I "${check}" --sources "${sources}" --allowlist "${allowlist}" > "${tmp}/out" 2>&1; then
    echo "accepted an upward function call" >&2; exit 1
fi
grep -Fq "Helpers/Low.swift: hostFetch (AlasFoundation -> AlasHostCore)" "${tmp}/out"
echo 'public struct LowThing {}' > "${sources}/Helpers/Low.swift"

# So does a member a higher module's extension adds, written with its type.
cat > "${sources}/Core/Process+Host.swift" <<'SWIFT'
extension Process {
    public static func hostRun() {}
}
SWIFT
cat > "${sources}/Helpers/Low.swift" <<'SWIFT'
public struct LowThing { func run() { Process.hostRun() } }
SWIFT
if python3 -I "${check}" --sources "${sources}" --allowlist "${allowlist}" > "${tmp}/out" 2>&1; then
    echo "accepted an upward extension member" >&2; exit 1
fi
grep -Fq "Helpers/Low.swift: hostRun (AlasFoundation -> AlasHostCore)" "${tmp}/out"
echo 'public struct LowThing {}' > "${sources}/Helpers/Low.swift"

# A function used as a value, an extension's initializer and its nested type
# count as well.
cat > "${sources}/Helpers/Base.swift" <<'SWIFT'
public struct Base {}
SWIFT
cat > "${sources}/Core/Base+Host.swift" <<'SWIFT'
extension Base {
    public init(hostValue: Int) { self.init() }
    public struct HostNested {}
}
SWIFT
for use in 'let callback = hostFetch' 'let base = Base(hostValue: 1)' 'let nested = Base.HostNested()'; do
    printf 'func low() { %s }\n' "${use}" > "${sources}/Helpers/Low.swift"
    if python3 -I "${check}" --sources "${sources}" --allowlist "${allowlist}" > "${tmp}/out" 2>&1; then
        echo "accepted an upward use: ${use}" >&2; exit 1
    fi
done
echo 'public struct LowThing {}' > "${sources}/Helpers/Low.swift"
rm "${sources}/Core/Base+Host.swift" "${sources}/Helpers/Base.swift"

# An enum case declared beside others is the lower module's own, not a use
# of a higher extension's member of the same name.
cat > "${sources}/Core/Process+Host.swift" <<'SWIFT'
extension Process {
    public static func hostRun() {}
    public var hostOnly: Int { 0 }
}
SWIFT
cat > "${sources}/Helpers/Low.swift" <<'SWIFT'
public enum LowKind {
    case first, hostOnly(Int), third
}
func low() -> LowKind { .hostOnly(1) }
SWIFT
python3 -I "${check}" --sources "${sources}" --allowlist "${allowlist}" > /dev/null
printf 'public enum LowKind {\n    case first,\n         hostOnly\n}\nfunc low() -> LowKind { .hostOnly }\n' > "${sources}/Helpers/Low.swift"
python3 -I "${check}" --sources "${sources}" --allowlist "${allowlist}" > /dev/null || { echo "rejected a case on a continuation line" >&2; exit 1; }
for cases in 'case first(value: Int), hostOnly(value: Int)' 'case first = 1, hostOnly = 2' 'case first = "https://example", hostOnly = "{host}"'; do
    printf 'public enum LowKind: Int {\n    %s\n}\nfunc low() { _ = LowKind.self; _ = [.hostOnly] as [LowKind] }\n' "${cases}" > "${sources}/Helpers/Low.swift"
    python3 -I "${check}" --sources "${sources}" --allowlist "${allowlist}" > /dev/null || { echo "rejected a local case: ${cases}" >&2; exit 1; }
done
echo 'public struct LowThing {}' > "${sources}/Helpers/Low.swift"

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
