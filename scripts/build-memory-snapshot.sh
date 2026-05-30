#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/build-memory-snapshot.sh

Print a point-in-time snapshot useful when Xcode builds or Ghostty/Zig build
steps appear to be starving the machine of memory.
EOF
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    "")
        ;;
    *)
        echo "build-memory-snapshot.sh: unknown argument: $1" >&2
        usage >&2
        exit 2
        ;;
esac

section() {
    printf '\n== %s ==\n' "$1"
}

section "Time"
date

section "VM pressure"
vm_stat
sysctl hw.memsize

section "Top resident processes"
top_processes="$(mktemp -t alas-build-memory-processes.XXXXXX)"
trap 'rm -f "${top_processes}"' EXIT
ps -axo rss,pid,ppid,stat,comm,args | sort -nr > "${top_processes}"
sed -n '1,40p' "${top_processes}"

section "Build-related processes"
ps -axo rss,pid,ppid,stat,comm,args \
    | awk 'NR == 1 || /xcodebuild|swift-frontend|SourceKit|XCBBuildService|SWBBuildService|zig|build-ghostty|build-zmx|rsync/ { print }'

section "Alas DerivedData roots"
derived_data="${HOME}/Library/Developer/Xcode/DerivedData"
if [ -d "${derived_data}" ]; then
    find "${derived_data}" -maxdepth 1 -type d \( -name 'Alas-*' -o -name 'Ghostty-*' \) -print0 \
        | while IFS= read -r -d '' dir; do
            du -sh "${dir}" 2>/dev/null || true
        done \
        | sort
    du -sh "${derived_data}/ModuleCache.noindex" 2>/dev/null || true
else
    echo "DerivedData root not found: ${derived_data}"
fi

section "Alas build caches"
du -sh \
    "${HOME}/Library/Caches/Alas" \
    .build \
    build \
    2>/dev/null || true

section "Current worktrees"
git worktree list 2>/dev/null || true
